import Foundation

enum SplitAmountPresentationState: Sendable {
    case pending, refreshing, failed, unavailable, ready

    var text: String {
        switch self {
        case .pending: "Pending"
        case .refreshing: "Refreshing"
        case .failed: "Refresh failed"
        case .unavailable: "Unavailable"
        case .ready: "Ready"
        }
    }
}

struct SplitPaidPresentation: Sendable {
    let enabled: Bool?
    let usedCents: Decimal?
    let limitCents: Decimal?
}

struct SplitPoolPresentation: Sendable {
    enum Position: Sendable {
        case outer, center
        var text: String { self == .outer ? "outer ring" : "center pie" }
    }
    let id: UsagePoolID
    let position: Position
    let percentText: String
    let amountText: String?
    let limitText: String?
    let statusText: String
    let sourceText: String?
    let readoutText: String
    let detailText: String?
    let showsMoney: Bool

    var moneyText: String? {
        amountText.map { amount in limitText.map { amount + " / " + $0 } ?? amount }
    }

    var line: String {
        var result = "\(id.displayName) (\(position.text)): \(percentText)"
        if showsMoney, let moneyText { result += " · " + moneyText }
        return result
    }
}

struct SplitUsagePresentation: Sendable {
    let pools: [SplitPoolPresentation]
    let detailLines: [String]
    var summaryLines: [String] { pools.map(\.line) + detailLines }
    var tooltip: String { summaryLines.joined(separator: "\n") }
    var accessibilityValue: String { tooltip }

    static func make(
        snapshot: SplitUsageSnapshot, amounts: CycleAmountSnapshot? = nil,
        outerPool: UsagePoolID = .other,
        amountState: SplitAmountPresentationState = .pending, percentIsStale: Bool = false,
        paid: SplitPaidPresentation? = nil, timeZone: TimeZone = .current,
        valueMode: PopoverValueMode = .both, showEstimatedLimits: Bool = false
    ) -> Self {
        let coherentAmounts = amounts.flatMap { $0.identity.sameScope(as: snapshot.identity) ? $0 : nil }
        let attributed = coherentAmounts.flatMap { $0.status == .estimatedAttribution ? $0 : nil }
        let currentPoolsSupportEstimates = UsagePoolID.allCases.allSatisfy { pool in
            guard let value = SplitUsageSnapshot.validPercent(snapshot[pool]) else { return false }
            return value < 100
        }
        let centerPool: UsagePoolID = outerPool == .other ? .cursor : .other
        let pools = [outerPool, centerPool].enumerated().map { index, pool in
            let candidateLimit = attributed.flatMap { $0.coverage.complete ? $0.estimatedLimitCents(for: pool) : nil }
            let sourcePercent = attributed.flatMap {
                SplitUsageSnapshot.validPercent(pool == .cursor ? $0.sourceCursorPercent : $0.sourceOtherPercent)
            }
            let estimateIsCurrent = currentPoolsSupportEstimates && sourcePercent != nil
                && sourcePercent == SplitUsageSnapshot.validPercent(snapshot[pool])
            let limit = showEstimatedLimits && estimateIsCurrent ? candidateLimit : nil
            let amountText = attributed.map { usd($0.amountCents(for: pool)) }
            let limitText = limit.map { "~" + wholeUSD($0) }
            let moneyText = amountText.map { amount in limitText.map { amount + " / " + $0 } ?? amount }
            let percentText = percent(snapshot[pool])
            return SplitPoolPresentation(
                id: pool, position: index == 0 ? .outer : .center,
                percentText: percentText, amountText: amountText, limitText: limitText,
                statusText: "", sourceText: nil,
                readoutText: valueMode == .dollars ? amountText ?? "Unavailable" : percentText,
                detailText: valueMode == .both ? moneyText : (valueMode == .dollars ? limitText.map { "of " + $0 } : nil),
                showsMoney: valueMode != .percent)
        }
        var details: [String] = []
        if percentIsStale { details.append("Percentages are old") }
        if valueMode != .percent {
            if let used = snapshot.includedUsedCents { details.append("Included total: \(usd(used))") }
            if let amounts = attributed, amounts.botCents > 0 {
                details.append("Bot activity: \(usd(amounts.botCents))")
            }
            let costsAreOld = attributed.map { amounts in
                amounts.isCached || UsagePoolID.allCases.contains { pool in
                    let source = pool == .cursor ? amounts.sourceCursorPercent : amounts.sourceOtherPercent
                    guard let source = SplitUsageSnapshot.validPercent(source),
                          let current = SplitUsageSnapshot.validPercent(snapshot[pool]) else { return true }
                    return source != current
                }
            } ?? false
            var costStatus: String?
            switch amountState {
            case .failed: costStatus = costsAreOld ? "Costs are old · update failed" : "Cost refresh failed"
            case .pending where attributed == nil: costStatus = "Costs pending"
            case .refreshing where attributed == nil: costStatus = "Loading costs…"
            case .ready where attributed == nil, .unavailable where attributed == nil: costStatus = "Costs unavailable"
            default: costStatus = costsAreOld ? "Costs are old" : nil
            }
            if costStatus == nil, attributed != nil, showEstimatedLimits, pools.contains(where: { $0.limitText == nil }) {
                costStatus = "Estimate not ready"
            }
            if let costStatus { details.append(costStatus) }
        }
        if let paid, let line = paidLine(paid) { details.append(line) }
        return Self(pools: pools, detailLines: details)
    }

    private static func percent(_ value: Double?) -> String {
        guard let value = SplitUsageSnapshot.validPercent(value) else { return "Unavailable" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 6
        return (formatter.string(from: NSNumber(value: value)) ?? String(value)) + "%"
    }

    private static func usd(_ cents: Decimal) -> String {
        CycleAmountSnapshot.formattedUSD(cents: cents)
    }

    private static func wholeUSD(_ cents: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        formatter.roundingMode = .halfUp
        formatter.positiveFormat = "$#,##0"
        formatter.negativeFormat = "-$#,##0"
        return formatter.string(from: NSDecimalNumber(decimal: cents / 100)) ?? "$—"
    }

    private static func paidLine(_ paid: SplitPaidPresentation) -> String? {
        guard paid.enabled == true || (paid.usedCents ?? 0) > 0 else { return nil }
        let actual = paid.usedCents.map(usd) ?? "Unavailable"
        if paid.enabled == false { return "Paid spending: \(actual) · Disabled" }
        if paid.enabled == true, let limit = paid.limitCents, limit > 0 {
            return "Paid spending: \(actual) / \(usd(limit))"
        }
        return "Paid spending: \(actual)"
    }
}
