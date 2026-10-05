import CryptoKit
import Foundation

enum UsagePoolID: String, Codable, CaseIterable, Sendable {
    case cursor, other
    var displayName: String { self == .cursor ? "Cursor Models" : "Other Models" }
}

struct UsageCycle: Codable, Equatable, Hashable, Sendable {
    let start: Date
    let end: Date
    init?(start: Date, end: Date) {
        guard start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite, start < end else { return nil }
        self.start = start; self.end = end
    }
    init?(start: String?, end: String?) {
        guard let start = Self.parse(start), let end = Self.parse(end) else { return nil }
        self.init(start: start, end: end)
    }
    static func parse(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: raw) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: raw)
    }
}

struct UsageRevisionIdentity: Codable, Equatable, Sendable {
    let localID: UInt64
    let credentialGeneration: UInt64
    let accountDigest: String
    let scopeDigest: String
    let cycle: UsageCycle?
    let planIdentity: String

    func sameScope(as other: Self) -> Bool {
        accountDigest == other.accountDigest && scopeDigest == other.scopeDigest && cycle == other.cycle && planIdentity == other.planIdentity
    }
    static func accountDigest(subject: String?, email: String?) -> String? {
        let subject = subject?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !subject.isEmpty { return digest("subject:" + subject) }
        let email = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return email.isEmpty || email == "unknown" ? nil : digest("email:" + email)
    }
    static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

enum UsagePercentageSource: String, Codable, Sendable { case summary, period }

struct SplitUsageSnapshot: Codable, Equatable, Sendable {
    let identity: UsageRevisionIdentity
    let capturedAt: Date
    var cursorPercent: Double?
    var otherPercent: Double?
    let includedUsedCents: Decimal?
    var cursorObservedPlaces: Int = 0
    var otherObservedPlaces: Int = 0
    var cursorSource: UsagePercentageSource = .summary
    var otherSource: UsagePercentageSource = .summary
    var periodCapturedAt: Date? = nil
    var periodCursorObservedPlaces: Int = 0
    var periodOtherObservedPlaces: Int = 0

    func supplemented(by period: CurrentPeriodUsageResponse?, summary: UsageSummaryResponse, at date: Date) -> Self {
        guard let period, period.isCoherent(with: summary) else { return self }
        let plan = summary.individualUsage?.plan
        let fillsCursor = plan?.autoPercentUsed == nil && period.planUsage?.autoPercentUsed != nil
        let fillsOther = plan?.apiPercentUsed == nil && period.planUsage?.apiPercentUsed != nil
        guard fillsCursor || fillsOther else { return self }
        var result = self
        result.cursorPercent = plan?.autoPercentUsed ?? period.planUsage?.autoPercentUsed
        result.otherPercent = plan?.apiPercentUsed ?? period.planUsage?.apiPercentUsed
        result.cursorSource = fillsCursor ? .period : .summary
        result.otherSource = fillsOther ? .period : .summary
        if fillsCursor {
            result.periodCursorObservedPlaces = min(3, max(0, max(periodCursorObservedPlaces, Self.fractionalPlaces(result.cursorPercent))))
            result.cursorObservedPlaces = result.periodCursorObservedPlaces
        } else {
            result.cursorObservedPlaces = min(3, max(0, max(cursorObservedPlaces, Self.fractionalPlaces(result.cursorPercent))))
        }
        if fillsOther {
            result.periodOtherObservedPlaces = min(3, max(0, max(periodOtherObservedPlaces, Self.fractionalPlaces(result.otherPercent))))
            result.otherObservedPlaces = result.periodOtherObservedPlaces
        } else {
            result.otherObservedPlaces = min(3, max(0, max(otherObservedPlaces, Self.fractionalPlaces(result.otherPercent))))
        }
        result.periodCapturedAt = date
        return result
    }
    subscript(pool: UsagePoolID) -> Double? { pool == .cursor ? cursorPercent : otherPercent }
    func observedPlaces(for pool: UsagePoolID) -> Int { pool == .cursor ? cursorObservedPlaces : otherObservedPlaces }
    static func validPercent(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }; return value
    }
    static func fractionalPlaces(_ value: Double?) -> Int {
        guard let value = validPercent(value) else { return 0 }
        for places in 0...3 {
            let scale = pow(10.0, Double(places))
            if abs(value * scale - (value * scale).rounded()) < 0.00000001 { return places }
        }
        return 3
    }
}

enum SplitUsageEligibility: String, Codable, Sendable {
    case legacy, checking, eligible
    static func evaluate(summary: UsageSummaryResponse, usage: UsageResponse?, enterpriseScope: Bool = false) -> Self {
        let membership = summary.membershipType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !enterpriseScope, summary.limitType?.lowercased() != "team", summary.teamUsage?.hasUsageData != true,
              !["enterprise", "business", "team", "teams", "free"].contains(membership),
              let plan = summary.individualUsage?.plan, let limit = plan.limit, limit > 0,
              plan.autoPercentUsed != nil || plan.apiPercentUsed != nil else { return .legacy }
        guard let usage else { return .checking }
        return usage.models.values.contains { $0.maxRequestUsage != nil } ? .legacy : .eligible
    }
}

struct CurrentPeriodUsageResponse: Decodable, Sendable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let planUsage: CurrentPeriodPlanUsage?
    let autoBucketModels: [String]?
    var cycle: UsageCycle? {
        guard let start = Self.periodDate(billingCycleStart), let end = Self.periodDate(billingCycleEnd) else { return nil }
        return UsageCycle(start: start, end: end)
    }
    private static func periodDate(_ raw: String?) -> Date? {
        if let date = UsageCycle.parse(raw) { return date }
        // This endpoint also returns contemporary cycle dates as whole epoch milliseconds.
        guard let raw, raw.range(of: #"\A[0-9]{13}\z"#, options: .regularExpression) != nil,
              let milliseconds = Double(raw) else { return nil }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
    enum CodingKeys: String, CodingKey { case billingCycleStart, billingCycleEnd, planUsage, autoBucketModels }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard c.contains(.planUsage) || c.contains(.billingCycleStart) || c.contains(.autoBucketModels) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Missing period metadata"))
        }
        billingCycleStart = try? c.decode(String.self, forKey: .billingCycleStart)
        billingCycleEnd = try? c.decode(String.self, forKey: .billingCycleEnd)
        planUsage = try? c.decode(CurrentPeriodPlanUsage.self, forKey: .planUsage)
        autoBucketModels = try? c.decode([String].self, forKey: .autoBucketModels)
    }
    func isCoherent(with summary: UsageSummaryResponse) -> Bool {
        guard let cycle, cycle == UsageCycle(start: summary.billingCycleStart, end: summary.billingCycleEnd),
              let included = planUsage?.includedSpend, let used = summary.individualUsage?.plan?.used, used >= 0 else { return false }
        return abs(included - Decimal(used)) <= 1
    }

    func bonusReconciliation(with summary: UsageSummaryResponse) -> CycleBonusReconciliation? {
        guard isCoherent(with: summary), let plan = summary.individualUsage?.plan,
              let used = plan.used, let limit = plan.limit, limit > 0, used == limit,
              let period = planUsage, period.limit == Decimal(limit),
              let included = period.includedSpend, let bonus = period.bonusSpend, bonus > 0,
              let total = period.totalSpend, total > Decimal(used), total >= included,
              abs(included + bonus - total) <= 1 else { return nil }
        for (primary, supplement) in [(plan.autoPercentUsed, period.autoPercentUsed), (plan.apiPercentUsed, period.apiPercentUsed)] {
            if let primary, let supplement, primary != supplement { return nil }
        }
        return .init(sourceIncludedCents: Decimal(used), totalCents: total)
    }
}

struct CurrentPeriodPlanUsage: Decodable, Sendable {
    let includedSpend: Decimal?
    let totalSpend: Decimal?
    let bonusSpend: Decimal?
    let limit: Decimal?
    let autoPercentUsed: Double?
    let apiPercentUsed: Double?
    enum CodingKeys: String, CodingKey { case includedSpend, totalSpend, bonusSpend, limit, autoPercentUsed, apiPercentUsed }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func cents(_ key: CodingKeys) -> Decimal? {
            (try? c.decode(Decimal.self, forKey: key)).flatMap { !$0.isNaN && $0 >= 0 ? $0 : nil }
        }
        includedSpend = cents(.includedSpend)
        totalSpend = cents(.totalSpend)
        bonusSpend = cents(.bonusSpend)
        limit = cents(.limit)
        autoPercentUsed = SplitUsageSnapshot.validPercent(try? c.decode(Double.self, forKey: .autoPercentUsed))
        apiPercentUsed = SplitUsageSnapshot.validPercent(try? c.decode(Double.self, forKey: .apiPercentUsed))
    }
}
