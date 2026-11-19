import Foundation

struct SharedAllowanceCalibration: Equatable, Sendable {
    let weekly: SharedWeeklyUsage
    let includedTokens: Int
    let through: Date
    let confirmedAt: Date

    init?(weekly: SharedWeeklyUsage, includedTokens: Int, through: Date, confirmedAt: Date) {
        guard let percent = weekly.percentUsed, percent.isFinite, percent >= 0.1, percent < 100,
              let period = weekly.period, period.start <= through, through <= confirmedAt,
              confirmedAt < period.end, through.timeIntervalSince1970.isFinite,
              confirmedAt.timeIntervalSince1970.isFinite,
              includedTokens > 0, includedTokens <= SharedActivityValue.maximumTokens else { return nil }
        self.weekly = weekly
        self.includedTokens = includedTokens
        self.through = through
        self.confirmedAt = confirmedAt
    }

    var estimatedCapacity: Double { Double(includedTokens) * 100 / weekly.percentUsed! }

    func isCurrent(matching weekly: SharedWeeklyUsage?, at date: Date) -> Bool {
        self.weekly == weekly && date >= confirmedAt && date < self.weekly.period!.end
    }

    func percentagePoints(for entry: RecentUsageEntry) -> Double? {
        guard entry.kind == .included, entry.date >= weekly.period!.start, entry.date <= through,
              let tokens = entry.tokens, tokens >= 0, tokens <= includedTokens else { return nil }
        return weekly.percentUsed! * Double(tokens) / Double(includedTokens)
    }

    func detail(for entry: RecentUsageEntry) -> String? {
        percentagePoints(for: entry).map { "≈\(SharedAllowanceFormatter.points($0)) pp" }
    }
}

struct SharedAllowanceObservation: Equatable, Sendable {
    struct Change: Equatable, Sendable {
        let percentagePoints: Double
        let start: Date
        let end: Date
    }
    let weekly: SharedWeeklyUsage
    let at: Date
    let change: Change?

    init?(weekly: SharedWeeklyUsage, at: Date, previous: Self? = nil) {
        guard let percent = weekly.percentUsed, let period = weekly.period,
              at.timeIntervalSince1970.isFinite, at >= period.start, at < period.end else { return nil }
        self.weekly = weekly
        self.at = at
        if let previous, previous.weekly.period == period, previous.at < at,
           let previousPercent = previous.weekly.percentUsed, percent > previousPercent {
            change = Change(percentagePoints: percent - previousPercent, start: previous.at, end: at)
        } else { change = nil }
    }
}

enum SharedAllowanceFormatter {
    static let explanation = "Estimated percentage points of your weekly allowance, proportional to included tokens. Product, model, and input/output/cache weights vary; this is not a reported per-request charge."

    static func points(_ value: Double) -> String {
        value > 0 && value < 0.001 ? "<0.001" : String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func caption(weekly: SharedWeeklyUsage, calibration: SharedAllowanceCalibration?,
                        observation: SharedAllowanceObservation?, mode: RecentUsageTimeZone) -> String? {
        guard let percentUsed = weekly.percentUsed else { return nil }
        let percent = NumberFormatter.localizedString(from: NSNumber(value: percentUsed), number: .decimal)
        var report = "Reported week: \(percent)%"
        if let observation, observation.weekly == weekly, let change = observation.change {
            let start = RecentUsageFormatter.eventTime(change.start, mode: mode)
            let end = RecentUsageFormatter.eventTime(change.end, mode: mode)
            let zone = RecentUsageFormatter.zoneLabel(mode: mode, at: change.end)
            report += " · +\(points(change.percentagePoints)) pp observed \(start)–\(end) \(zone)"
        }
        report += "."
        if let calibration {
            let capacity = RecentUsageFormatter.tokens(Int(calibration.estimatedCapacity))
            report += "\nEst. capacity ≈\(capacity) tokens at current mix.\n≈pp = estimated weekly allowance use."
        }
        return report
    }
}
