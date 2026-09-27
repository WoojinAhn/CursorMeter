import Foundation

enum UsagePercentFormatter {
    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "—" }
        if value > 0 && value < 0.1 { return "<0.1%" }
        let rounded = number(value)
        // Rounding must not imply that a quota was reached or is still within its limit.
        if rounded == "100.0", value != 100 { return value < 100 ? "<100.0%" : ">100.0%" }
        return rounded + "%"
    }

    static func percentagePoints(_ value: Double) -> String {
        if value > 0 && value < 0.1 { return "<0.1 percentage points" }
        return "+\(number(value)) percentage points"
    }

    private static func number(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 1
        formatter.maximumFractionDigits = 1
        formatter.roundingMode = .halfUp
        return formatter.string(from: NSNumber(value: value == 0 ? 0 : value)) ?? "—"
    }
}
