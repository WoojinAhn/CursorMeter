import Foundation
import CryptoKit

struct SplitAlertOwnership: Sendable, Hashable, Codable {
    var accountDigest: String
    var persistentSubjectDigest: String? = nil
    var requestPlanScope: String
    var cycleStart: Date? = nil
    var cycleEnd: Date? = nil
    var generation: UInt64

    func hasSameSignalScope(as other: Self) -> Bool {
        accountDigest == other.accountDigest && requestPlanScope == other.requestPlanScope
            && cycleStart == other.cycleStart && cycleEnd == other.cycleEnd
    }

    var cycleKey: String? {
        guard let start = cycleStart, let end = cycleEnd, start < end,
              start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite else { return nil }
        return Self.digest("\(Int64((start.timeIntervalSince1970 * 1000).rounded()))/\(Int64((end.timeIntervalSince1970 * 1000).rounded()))")
    }

    var persistenceKey: String? {
        guard let subject = persistentSubjectDigest, !subject.isEmpty, cycleKey != nil else { return nil }
        return Self.digest("split-alert-subject:" + subject)
    }

    func identity(scope: SplitAlertScope, level: String, value: Int, budget: Double?) -> String {
        let fields = [accountDigest, requestPlanScope, cycleKey ?? "session", scope.rawValue,
                      budget.map(String.init(describing:)) ?? "none", level, String(value)]
        return Self.digest(fields.map { "\($0.utf8.count):\($0)" }.joined())
    }

    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum SplitAlertScope: String, Sendable, Codable, CaseIterable {
    case included, cursor, other, onDemand
    var label: String {
        switch self {
        case .included: "Included Usage"
        case .cursor: "Cursor Models"
        case .other: "Other Models"
        case .onDemand: "On-demand"
        }
    }
}

struct SplitUsageObservation: Sendable {
    var ownership: SplitAlertOwnership
    var revision: UInt64
    var timestamp: Date
    var includedCents: Double? = nil
    var cursorPercent: Double? = nil
    var otherPercent: Double? = nil
    var paidCents: Double? = nil
    var paidCapCents: Double? = nil
    var paidEnabled: Bool? = nil
    var continuityReset = false
}

struct SplitAlertPolicy: Sendable, Equatable {
    var thresholdsEnabled = true
    var warning = 80
    var critical = 90
    var targets: Set<SplitAlertScope> = [.cursor, .other, .onDemand]
    var jumpEnabled = true
    var bold = false
    var refreshInterval: TimeInterval = 60

    var continuityCeiling: TimeInterval { max(2 * refreshInterval, 120) }

    static func normalizeThresholds(warning: Int, critical: Int) -> (warning: Int, critical: Int) {
        let warning = min(Int((Double(min(max(warning, 0), 100)) / 5).rounded()) * 5, 95)
        let critical = Int((Double(min(max(critical, 0), 100)) / 5).rounded()) * 5
        return (warning, min(max(critical, warning + 5), 100))
    }

    func hasSameThresholds(as other: Self) -> Bool {
        thresholdsEnabled == other.thresholdsEnabled && warning == other.warning && critical == other.critical && targets == other.targets
    }

    func hasSameBold(as other: Self) -> Bool { jumpEnabled == other.jumpEnabled && bold == other.bold }
}

struct SplitUsageJump: Sendable {
    var tier: Int
    var deltas: [SplitAlertScope: Double]
    var correctedScopes: Set<SplitAlertScope>
    var title: String
    var body: String
}

struct SplitThresholdEvent: Sendable {
    var scope: SplitAlertScope
    var level: ThresholdLevel
    var identity: String
    var coveredIdentities: Set<String>
    var body: String
}

struct SplitUsageEventBatch: Sendable {
    var ownership: SplitAlertOwnership
    var revision: UInt64
    var timestamp: Date
    var thresholds: [SplitThresholdEvent] = []
    var jump: SplitUsageJump? = nil
    var boldJump: SplitUsageJump? = nil
}

struct SplitUsageAlertEngine {
    private struct Signal {
        var previous: Double?
        var highWater: Double?

        mutating func observe(_ value: Double?, comparable: Bool) -> (delta: Double, corrected: Bool) {
            guard let value, value.isFinite, value >= 0 else { previous = nil; return (0, false) }
            let reference = max(previous ?? value, highWater ?? value)
            let corrected = previous.map { $0 < (highWater ?? $0) } ?? false
            let delta = comparable && previous != nil ? max(0, value - reference) : 0
            previous = value
            highWater = max(highWater ?? value, value)
            return (delta, corrected)
        }
    }

    private var ownership: SplitAlertOwnership?
    private var revision: UInt64?
    private var timestamp: Date?
    private var signals: [SplitAlertScope: Signal] = [:]
    private var paidEnabled: Bool?
    private var paidCap: Double?
    private var needsBaseline = false

    mutating func accept(_ observation: SplitUsageObservation, policy: SplitAlertPolicy) -> SplitUsageEventBatch {
        var batch = SplitUsageEventBatch(ownership: observation.ownership, revision: observation.revision, timestamp: observation.timestamp)
        if ownership != observation.ownership {
            if let ownership, ownership.hasSameSignalScope(as: observation.ownership) {
                resetContinuity()
                revision = nil
            } else { reset() }
            ownership = observation.ownership
        }
        guard revision.map({ observation.revision > $0 }) ?? true else { return batch }
        let comparable = timestamp.map {
            let gap = observation.timestamp.timeIntervalSince($0)
            return gap >= 0 && gap <= policy.continuityCeiling
        } ?? false
        let continuity = comparable && !needsBaseline && !observation.continuityReset
        let cap = Self.valid(observation.paidCapCents).flatMap { $0 > 0 ? $0 : nil }
        let paidComparable = continuity && paidEnabled == observation.paidEnabled && paidCap == cap
        let values: [SplitAlertScope: Double?] = [
            .included: observation.includedCents, .cursor: observation.cursorPercent,
            .other: observation.otherPercent, .onDemand: observation.paidEnabled == true ? observation.paidCents : nil
        ]
        var deltas: [SplitAlertScope: Double] = [:]
        var corrected: Set<SplitAlertScope> = []
        var tier = 0
        for scope in SplitAlertScope.allCases {
            var signal = signals[scope] ?? Signal()
            let change = signal.observe(values[scope] ?? nil, comparable: scope == .onDemand ? paidComparable : continuity)
            signals[scope] = signal
            let percentSignal = scope == .cursor || scope == .other
            // Percent sources carry at most three decimal places; discard binary
            // subtraction noise without promoting a genuine 4.999 pp delta.
            let delta = percentSignal ? (change.delta * 1000).rounded() / 1000 : change.delta
            guard delta > 0 else { continue }
            deltas[scope] = delta
            if change.corrected { corrected.insert(scope) }
            let one = 5.0
            let two = percentSignal ? 15.0 : 30.0
            var signalTier = delta >= two ? 2 : delta >= one ? 1 : 0
            if scope == .onDemand, let cap {
                let relative = delta / cap * 100
                signalTier = max(signalTier, relative >= 15 ? 2 : relative >= 5 ? 1 : 0)
            }
            tier = max(tier, signalTier)
        }
        revision = observation.revision
        timestamp = observation.timestamp
        paidEnabled = observation.paidEnabled
        paidCap = cap
        needsBaseline = false

        if tier > 0, policy.jumpEnabled {
            let jump = makeJump(tier: tier, deltas: deltas, corrected: corrected, observation: observation)
            batch.jump = jump
            if policy.bold && tier == 2 { batch.boldJump = jump }
        }
        if policy.thresholdsEnabled {
            let thresholds = SplitAlertPolicy.normalizeThresholds(warning: policy.warning, critical: policy.critical)
            for scope in [SplitAlertScope.cursor, .other, .onDemand] where policy.targets.contains(scope) {
                let percent: Double?
                if scope == .onDemand {
                    percent = observation.paidEnabled == true ? cap.flatMap { cap in Self.valid(observation.paidCents).map { $0 / cap * 100 } } : nil
                } else { percent = Self.valid(scope == .cursor ? observation.cursorPercent : observation.otherPercent) }
                guard let percent, percent >= Double(thresholds.warning) else { continue }
                let critical = percent >= Double(thresholds.critical)
                let budget = scope == .onDemand ? cap : nil
                let warningID = observation.ownership.identity(scope: scope, level: "warning", value: thresholds.warning, budget: budget)
                let criticalID = observation.ownership.identity(scope: scope, level: "critical", value: thresholds.critical, budget: budget)
                batch.thresholds.append(SplitThresholdEvent(scope: scope, level: critical ? .critical : .warning,
                    identity: critical ? criticalID : warningID,
                    coveredIdentities: critical ? [warningID, criticalID] : [warningID],
                    body: "\(scope.label): 현재 \(Self.number(percent))%, 알림 기준 \(critical ? thresholds.critical : thresholds.warning)%"))
            }
        }
        return batch
    }

    mutating func resetContinuity() { needsBaseline = true }
    mutating func reset() { self = Self() }

    private static func valid(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func number(_ value: Double) -> String { String(format: "%.2f", value) }

    private func makeJump(tier: Int, deltas: [SplitAlertScope: Double], corrected: Set<SplitAlertScope>, observation: SplitUsageObservation) -> SplitUsageJump {
        let lines = SplitAlertScope.allCases.compactMap { scope -> String? in
            guard let delta = deltas[scope] else { return nil }
            let amount = scope == .cursor || scope == .other ? "+\(Self.number(delta)) pp" : String(format: "+$%.2f", delta / 100)
            let reference = corrected.contains(scope) ? "이전 최고치 대비" : "이전 유효 업데이트 이후"
            return "\(scope.label): \(reference) \(amount)"
        }
        var body = lines.joined(separator: "\n")
        if deltas[.included] != nil {
            let cursor = Self.valid(observation.cursorPercent).map { Self.number($0) + "%" } ?? "확인 불가"
            let other = Self.valid(observation.otherPercent).map { Self.number($0) + "%" } ?? "확인 불가"
            body += "\n현재 Cursor Models \(cursor), Other Models \(other). 풀별 금액 배분을 확인할 수 없습니다."
        }
        return SplitUsageJump(tier: tier, deltas: deltas, correctedScopes: corrected,
            title: deltas[.included] != nil ? "Included Usage Jump" : "Usage Jump", body: body)
    }
}
