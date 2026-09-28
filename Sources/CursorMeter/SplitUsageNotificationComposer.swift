import Foundation

enum SplitUsageNotificationComposer {
    private static let bodyRowLimit = 3

    static func compose(thresholds: [SplitThresholdEvent], bold: SplitUsageJump?) -> UsageNotificationContent? {
        let ordered = thresholds.sorted {
            if $0.level != $1.level { return $0.level == .critical }
            return scopeRank($0.scope) < scopeRank($1.scope)
        }
        guard let first = ordered.first else {
            return bold.flatMap { jumpContent(signals: $0.signals, minimumTier: 2) }
        }

        var rows = [thresholdBody(first)] + ordered.dropFirst().map(thresholdTitle)
        // A dispatcher can retain an older increase while replacing thresholds
        // during authorization. Never mix captured values from those revisions.
        if let bold, ordered.allSatisfy({ $0.observationRevision == bold.observationRevision }) {
            for signal in orderedSignals(bold.signals, minimumTier: 2) where rows.count < bodyRowLimit {
                rows.append(jumpRow(signal, primary: signal.scope == first.scope && rows.count == 1))
            }
        }
        return UsageNotificationContent(title: thresholdTitle(first), body: rows.joined(separator: "\n"))
    }

    static func thresholdBody(_ event: SplitThresholdEvent) -> String {
        if let used = event.usedCents, let limit = event.limitCents {
            return "\(money(used)) of \(money(limit)) · alert at \(event.configuredPercent)%"
        }
        let level = event.level == .critical ? "critical" : "warning"
        return "Your \(level) level is \(event.configuredPercent)%."
    }

    static func jumpContent(signals: [SplitUsageJumpSignal], minimumTier: Int) -> UsageNotificationContent? {
        let selected = orderedSignals(signals, minimumTier: minimumTier).prefix(bodyRowLimit)
        guard let first = selected.first else { return nil }
        let rows = selected.enumerated().map { jumpRow($0.element, primary: $0.offset == 0) }
        return UsageNotificationContent(title: "\(first.scope.label) increased", body: rows.joined(separator: "\n"))
    }

    private static func thresholdTitle(_ event: SplitThresholdEvent) -> String {
        let label = event.scope == .onDemand ? "Paid budget" : event.scope.label
        let level = event.level == .critical ? "Critical" : "Warning"
        return "\(label) \(UsagePercentFormatter.percent(event.percent)) · \(level)"
    }

    private static func orderedSignals(_ signals: [SplitUsageJumpSignal], minimumTier: Int) -> [SplitUsageJumpSignal] {
        signals.filter { $0.tier >= minimumTier }.sorted { scopeRank($0.scope) < scopeRank($1.scope) }
    }

    private static func jumpRow(_ signal: SplitUsageJumpSignal, primary: Bool) -> String {
        if signal.scope == .cursor || signal.scope == .other {
            let reference = UsagePercentFormatter.percent(signal.referenceValue)
            let current = UsagePercentFormatter.percent(signal.currentValue)
            if primary {
                return "\(signal.corrected ? "Previous peak" : "Last refresh") \(reference) → now \(current)"
            }
            return "\(signal.scope.label): \(signal.corrected ? "peak " : "")\(reference) → \(current)"
        }
        let change = "+\(money(signal.delta)) \(signal.corrected ? "above previous peak" : "since last refresh")"
        return primary ? change : "\(signal.scope.label): \(change)"
    }

    private static func scopeRank(_ scope: SplitAlertScope) -> Int {
        switch scope {
        case .onDemand: 0
        case .other: 1
        case .cursor: 2
        case .included: 3
        }
    }

    private static func money(_ cents: Double) -> String {
        String(format: "$%.2f", cents / 100)
    }
}
