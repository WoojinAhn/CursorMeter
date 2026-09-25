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

    var line: String {
        var result = "\(id.displayName) (\(position.text)): \(percentText)"
        if let amountText { result += " · \(amountText)" }
        if let limitText { result += " / \(limitText) estimated limit" }
        if amountText != nil { result += " (\(statusText))" }
        if let sourceText { result += "\n\(sourceText)" }
        return result
    }
}

struct SplitUsagePresentation: Sendable {
    let pools: [SplitPoolPresentation]
    let summaryLines: [String]
    var tooltip: String { summaryLines.joined(separator: "\n") }
    var accessibilityValue: String { tooltip }

    static func make(
        snapshot: SplitUsageSnapshot, amounts: CycleAmountSnapshot? = nil,
        outerPool: UsagePoolID = .other,
        amountState: SplitAmountPresentationState = .pending, percentIsStale: Bool = false,
        paid: SplitPaidPresentation? = nil, timeZone: TimeZone = .current
    ) -> Self {
        let coherentAmounts = amounts.flatMap { $0.identity.sameScope(as: snapshot.identity) ? $0 : nil }
        let state: SplitAmountPresentationState = coherentAmounts == nil && amountState == .ready ? .unavailable : amountState
        let amountStatus = coherentAmounts.map { amountStatus($0) } ?? state.text
        let currentPoolsSupportEstimates = UsagePoolID.allCases.allSatisfy { pool in
            guard let value = SplitUsageSnapshot.validPercent(snapshot[pool]) else { return false }
            return value < 100
        }
        let centerPool: UsagePoolID = outerPool == .other ? .cursor : .other
        let pools = [outerPool, centerPool].enumerated().map { index, pool in
            let attributed = coherentAmounts.flatMap { $0.status == .estimatedAttribution ? $0 : nil }
            let candidateLimit = attributed.flatMap { $0.coverage.complete ? $0.estimatedLimitCents(for: pool) : nil }
            let sourcePercent = attributed.flatMap {
                SplitUsageSnapshot.validPercent(pool == .cursor ? $0.sourceCursorPercent : $0.sourceOtherPercent)
            }
            let estimateIsCurrent = currentPoolsSupportEstimates && sourcePercent != nil
                && sourcePercent == SplitUsageSnapshot.validPercent(snapshot[pool])
            let limit = estimateIsCurrent ? candidateLimit : nil
            let status = amountStatus + (candidateLimit != nil && !estimateIsCurrent ? " · Estimate stale — refresh amounts" : "")
            let source = pool == .cursor ? snapshot.cursorSource : snapshot.otherSource
            let sourceText = source == .period
                ? "Percent source: Current period · \(snapshot.periodCapturedAt.map { timestamp($0, timeZone: timeZone) } ?? "Time unavailable")"
                : nil
            return SplitPoolPresentation(
                id: pool, position: index == 0 ? .outer : .center,
                percentText: percent(snapshot[pool]),
                amountText: attributed.map { usd($0.amountCents(for: pool)) },
                limitText: limit.map { "~" + usd($0) }, statusText: status, sourceText: sourceText)
        }
        var lines = pools.map(\.line)
        let refreshLabel = snapshot.cursorSource == .period || snapshot.otherSource == .period
            ? "Primary summary refreshed" : "Percent refreshed"
        lines.append("\(refreshLabel): \(timestamp(snapshot.capturedAt, timeZone: timeZone))\(percentIsStale ? " (stale)" : "")")
        if let cycle = snapshot.identity.cycle {
            lines.append("Cycle: \(timestamp(cycle.start, timeZone: timeZone)) – \(timestamp(cycle.end, timeZone: timeZone))")
        } else {
            lines.append("Cycle: Unavailable")
        }
        lines.append("Amounts: \(state.text)\(coherentAmounts == nil ? "" : " · " + amountStatus)")
        if let amounts = coherentAmounts {
            lines.append("Amount snapshot: \(timestamp(amounts.capturedAt, timeZone: timeZone))")
            if amounts.capturedAt < snapshot.capturedAt {
                lines.append("Older amount snapshot; percentages refreshed separately")
            }
            if amounts.status == .estimatedAttribution {
                lines.append("Estimated from this cycle; model attribution may differ")
            }
            lines.append("Coverage: \(amounts.coverage.complete ? "Complete" : "Partial") · \(amounts.coverage.eventCount) events / \(amounts.coverage.pageCount) pages")
            if amounts.status == .unavailable {
                lines.append("Cursor Models observed family subtotal: \(usd(amounts.cursorCents))")
                lines.append("Other Models observed family subtotal: \(usd(amounts.otherCents))")
                lines.append("Observed subtotals are provisional; pool amounts and limits are unavailable")
            }
            lines.append("Unknown: \(usd(amounts.unknownCents)) · \(amounts.unknownCount) events")
            if let residual = amounts.residualCents {
                lines.append("Reconciliation residual: \(NSDecimalNumber(decimal: residual).stringValue) cents")
            } else {
                lines.append("Reconciliation: Unavailable")
            }
            lines.append("Bot observed cycle activity: \(usd(amounts.botCents))")
            lines.append("Paid observed history: \(usd(amounts.paidCents))")
            lines.append(amounts.coverage.complete
                ? "Bot and paid history are observed activity, not independently verified billing totals"
                : "Observed activity only; coverage is partial")
        }
        if let used = snapshot.includedUsedCents {
            lines.append("Included total: \(usd(used))")
        } else {
            lines.append("Included total: Unavailable")
        }
        if let paid { lines.append(paidLine(paid)) }
        return Self(pools: pools, summaryLines: lines)
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

    private static func timestamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
        return formatter.string(from: date)
    }

    private static func usd(_ cents: Decimal) -> String {
        CycleAmountSnapshot.formattedUSD(cents: cents)
    }

    private static func amountStatus(_ amounts: CycleAmountSnapshot) -> String {
        let attribution = amounts.status == .estimatedAttribution ? "Estimated attribution" : "Unavailable"
        return (amounts.isCached ? "Cached · " : "") + attribution + (amounts.coverage.complete ? "" : " · Partial")
    }

    private static func paidLine(_ paid: SplitPaidPresentation) -> String {
        let actual = paid.usedCents.map(usd) ?? "Unavailable"
        guard let enabled = paid.enabled else {
            return "Paid spending: \(actual) · Availability unknown"
        }
        guard enabled else {
            return "Paid spending: \(actual) · Disabled\((paid.usedCents ?? 0) > 0 ? "; residual spending" : "")"
        }
        if let limit = paid.limitCents, limit > 0 {
            return "Paid spending: \(actual) / \(usd(limit)) budget cap"
        }
        return "Paid spending: \(actual) · No budget cap"
    }
}
