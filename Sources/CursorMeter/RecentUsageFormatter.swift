import Foundation

enum RecentUsageFormatter {
    private static let locale = Locale(identifier: "en_US_POSIX")

    static func amount(cents: Double?) -> String {
        guard let cents, cents.isFinite, cents >= 0 else { return "—" }
        if cents > 0, cents < 0.01 { return "<$0.0001" }
        let digits = cents > 0 && cents < 1 ? 4 : 2
        let formatter = numberFormatter(minimumDigits: digits, maximumDigits: digits)
        formatter.positivePrefix = "$"
        if let decimal = Decimal(string: String(cents), locale: locale) {
            return formatter.string(from: NSDecimalNumber(decimal: decimal / 100)) ?? "—"
        }
        return formatter.string(from: NSNumber(value: cents / 100)) ?? "—"
    }

    static func tokens(_ count: Int?) -> String {
        guard let count, count >= 0 else { return "—" }
        guard count >= 1000 else { return String(count) }
        // Promote the value that would round to 1000K before formatting.
        let useMillions = count >= 999_950
        let divisor = Decimal(useMillions ? 1_000_000 : 1000)
        let formatter = numberFormatter(minimumDigits: 0, maximumDigits: useMillions ? 2 : 1)
        let value = NSDecimalNumber(decimal: Decimal(count) / divisor)
        return (formatter.string(from: value) ?? "—") + (useMillions ? "M" : "K")
    }

    static func eventTime(
        _ date: Date,
        mode: RecentUsageTimeZone,
        now: Date = Date(),
        localTimeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let formatter = dateFormatter(mode: mode, localTimeZone: localTimeZone)
        let sameYear = formatter.calendar.component(.year, from: date) == formatter.calendar.component(.year, from: now)
        formatter.dateFormat = sameYear ? "MMM d, HH:mm" : "MMM d, yyyy, HH:mm"
        return formatter.string(from: date)
    }

    static func cachedTime(
        _ date: Date,
        mode: RecentUsageTimeZone,
        localTimeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        let formatter = dateFormatter(mode: mode, localTimeZone: localTimeZone)
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    static func zoneLabel(mode: RecentUsageTimeZone, at date: Date = Date(), localTimeZone: TimeZone = .autoupdatingCurrent) -> String {
        guard mode == .local else { return "UTC" }
        if let abbreviation = localTimeZone.abbreviation(for: date), !abbreviation.isEmpty { return abbreviation }
        let offset = localTimeZone.secondsFromGMT(for: date)
        guard offset != 0 else { return "UTC" }
        return String(format: "UTC%@%02d:%02d", offset < 0 ? "−" : "+", abs(offset) / 3600, abs(offset) % 3600 / 60)
    }

    static func zoneIdentifier(mode: RecentUsageTimeZone, localTimeZone: TimeZone = .autoupdatingCurrent) -> String {
        mode == .local ? localTimeZone.identifier : "UTC"
    }

    private static func numberFormatter(minimumDigits: Int, maximumDigits: Int) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = minimumDigits
        formatter.maximumFractionDigits = maximumDigits
        formatter.roundingMode = .halfUp
        return formatter
    }

    private static func dateFormatter(mode: RecentUsageTimeZone, localTimeZone: TimeZone) -> DateFormatter {
        let timeZone = mode == .local ? localTimeZone : TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        return formatter
    }
}
