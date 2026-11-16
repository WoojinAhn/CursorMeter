import Foundation

struct SharedUsagePresentation {
    struct Reading {
        let title: String
        let percent: Double?
        let detail: String
        let accessibilityDetail: String
        let isStale: Bool
        var percentText: String { UsagePercentFormatter.percent(percent).replacingOccurrences(of: ".0%", with: "%") }
    }

    let weekly: Reading
    let credit: Reading
    let creditHasNoPurchases: Bool
    let detailLines: [String]
    let status: String?
    let statusItemAccessibilityLabel: String

    init(mode: SharedUsageMode, snapshot: SharedUsageSnapshot?, at date: Date = Date()) {
        let sharedWeekly = mode == .sharedWeekly
        let snapshot = sharedWeekly ? (snapshot ?? .empty) : .empty
        statusItemAccessibilityLabel = sharedWeekly
            ? "CursorMeter weekly included and prepaid credit usage" : "CursorMeter usage plan"
        let weeklyAvailability = snapshot.weeklyAvailability(at: date)
        let weeklyReset = snapshot.weekly.value?.period.map { "Resets " + Self.resetDate($0.end) } ?? "Reset unknown"
        let weeklyDetail = (weeklyAvailability == .stale ? "Stale · " : "") + weeklyReset
        weekly = Reading(title: sharedWeekly ? "Weekly included" : "Included usage", percent: snapshot.weekly.value?.percentUsed,
            detail: weeklyDetail, accessibilityDetail: weeklyDetail, isStale: weeklyAvailability == .stale)
        let prepaid = snapshot.credit.value
        creditHasNoPurchases = prepaid?.hasNoPurchases == true
        let balance = Self.money(prepaid?.remainingCents)
        let creditDetail: String
        if prepaid?.hasNoPurchases == true {
            creditDetail = "\(balance) left · No top-ups"
        } else if let total = prepaid?.totalPurchasedCents {
            creditDetail = "\(balance) left / \(Self.money(total))"
        } else {
            creditDetail = "\(balance) left · Total unknown"
        }
        let spokenBalance = prepaid?.remainingCents.map { Self.money($0) } ?? "unknown"
        let spokenPurchased = prepaid?.totalPurchasedCents.map { Self.money($0) } ?? "unknown"
        let creditAccessibility = "Remaining balance: \(spokenBalance); Total purchased credit: \(spokenPurchased)"
            + (prepaid?.hasNoPurchases == true ? "; No top-ups" : "")
        credit = Reading(title: sharedWeekly ? "Prepaid credit" : "Credits", percent: prepaid?.percentUsed,
            detail: (snapshot.credit.isStale ? "Stale · " : "") + creditDetail,
            accessibilityDetail: (snapshot.credit.isStale ? "Stale · " : "") + creditAccessibility,
            isStale: snapshot.credit.isStale)
        let monthly = Self.money(snapshot.monthlyUsed.value) + (snapshot.monthlyUsed.isStale ? " (stale)" : "")
        let cap: String
        switch snapshot.paidCap.value ?? .unknown {
        case .unknown: cap = "Cap unknown"
        case .uncapped: cap = "No cap"
        case .limited(let amount): cap = "\(Self.money(amount)) cap"
        }
        let capText = cap + (snapshot.paidCap.isStale ? " (stale)" : "")
        let auto = snapshot.autoTopUp.value.map { $0.enabled ? "On" : "Off" } ?? "Unknown"
        detailLines = ["Monthly paid: \(monthly) / \(capText)",
            "Auto Top-up: \(auto)\(snapshot.autoTopUp.isStale ? " (stale)" : "") · Paid reset unknown"]
        switch mode {
        case .checking: status = "Checking usage plan…"
        case .unsupported: status = "This usage plan is not supported yet."
        case .unavailable: status = "Usage plan unavailable — try refreshing."
        default:
            if weeklyAvailability == .stale || snapshot.isStale {
                status = "Stale readings — refresh to verify."
            } else if weeklyAvailability == .unavailable {
                status = "Weekly usage unavailable."
            } else if snapshot.paidCap.availability == .current, snapshot.paid.isCapReached == true {
                status = "Monthly paid cap reached."
            } else if snapshot.hasIncludedUsage(at: date) == false {
                status = "Weekly included usage exhausted."
            } else {
                status = nil
            }
        }
    }

    var readout: SplitMenuBarReadout { .init(upper: weekly.percentText, lower: credit.percentText) }
    var accessibilityValue: String {
        ["Outer: \(weekly.title) \(weekly.percentText) · \(weekly.accessibilityDetail)",
         "Center: \(credit.title) consumed \(credit.percentText) · \(credit.accessibilityDetail)"]
            .joined(separator: "\n")
    }
    var tooltip: String { ([accessibilityValue] + detailLines + [status].compactMap { $0 }).joined(separator: "\n") }

    static func dashboardURL(mode: SharedUsageMode) -> URL {
        URL(string: mode == .sharedWeekly ? "https://grok.com/dashboard/usage" : "https://www.cursor.com/dashboard?tab=usage")!
    }
    static let creditsURL = URL(string: "https://grok.com/dashboard/billing")!

    private static func money(_ cents: Decimal?) -> String {
        guard let cents else { return "—" }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.positiveFormat = "$#,##0.00"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: cents / 100)) ?? "—"
    }
    private static func resetDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, HH:mm"
        return formatter.string(from: date)
    }
}
