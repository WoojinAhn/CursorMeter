import Foundation

// MARK: - API Response: /api/usage (dynamic key parsing)

struct UsageResponse: Sendable {
    let models: [String: ModelUsage]
    let startOfMonth: String?

    /// Returns the first model with maxRequestUsage, or the first model available
    var primaryModel: ModelUsage? {
        models.values.first(where: { $0.maxRequestUsage != nil })
            ?? models.values.first
    }
}

extension UsageResponse: Decodable {
    private struct DynamicKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    private enum KnownKey: String {
        case startOfMonth
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)

        var startOfMonth: String?
        var models: [String: ModelUsage] = [:]

        for key in container.allKeys {
            if key.stringValue == KnownKey.startOfMonth.rawValue {
                startOfMonth = try container.decodeIfPresent(String.self, forKey: key)
            } else if let model = try? container.decode(ModelUsage.self, forKey: key) {
                models[key.stringValue] = model
            }
        }

        self.startOfMonth = startOfMonth
        self.models = models
    }
}

struct ModelUsage: Codable, Sendable {
    let numRequests: Int?
    let numRequestsTotal: Int?
    let numTokens: Int?
    let maxRequestUsage: Int?
    let maxTokenUsage: Int?
}

// MARK: - API Response: /api/usage-summary

struct UsageSummaryResponse: Codable, Sendable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let membershipType: String?
    let limitType: String?
    let isUnlimited: Bool?
    /// Sentence like "You've used 0% of your included total usage". On
    /// token-based enterprise contracts the included-usage percentage is
    /// exposed ONLY here — there is no numeric `plan` limit for members
    /// (`adminOnlyUsagePricing`). Parsed into `serverPercentUsed` as a fallback.
    let autoModelSelectedDisplayMessage: String?
    let individualUsage: IndividualUsage?
    let teamUsage: TeamUsage?
}

struct IndividualUsage: Codable, Sendable {
    let plan: PlanUsage?
    let onDemand: OnDemandUsage?
    /// Present on token-based enterprise contracts that have no `plan` object.
    /// `used` is in USD cents; `limit` is null (the member-facing limit comes
    /// from the separate `get-hard-limit` endpoint instead).
    let overall: OverallUsage?
}

struct OverallUsage: Codable, Sendable {
    let enabled: Bool?
    let used: Int?
    let limit: Int?
    let remaining: Int?
}

struct PlanUsage: Codable, Sendable {
    let enabled: Bool?
    let used: Int?
    let limit: Int?
    let remaining: Int?
    let totalPercentUsed: Double?
    /// Cursor Models bucket (Grok / Composer). Present on Ultra and some
    /// personal plans; sourced from usage-summary or get-current-period-usage.
    let autoPercentUsed: Double?
    /// Other Models / API bucket.
    let apiPercentUsed: Double?

    init(
        enabled: Bool?,
        used: Int?,
        limit: Int?,
        remaining: Int?,
        totalPercentUsed: Double?,
        autoPercentUsed: Double? = nil,
        apiPercentUsed: Double? = nil
    ) {
        self.enabled = enabled
        self.used = used
        self.limit = limit
        self.remaining = remaining
        self.totalPercentUsed = totalPercentUsed
        self.autoPercentUsed = autoPercentUsed
        self.apiPercentUsed = apiPercentUsed
    }
}

// MARK: - API Response: /api/dashboard/get-current-period-usage

struct CurrentPeriodUsageResponse: Codable, Sendable {
    let planUsage: CurrentPeriodPlanUsage?
}

struct CurrentPeriodPlanUsage: Codable, Sendable {
    let autoPercentUsed: Double?
    let apiPercentUsed: Double?
    let totalPercentUsed: Double?
}

struct OnDemandUsage: Codable, Sendable {
    let enabled: Bool?
    let used: Int?
    let limit: Int?
    let remaining: Int?
}

struct TeamUsage: Codable, Sendable {
    let onDemand: OnDemandUsage?
}

// MARK: - API Response: /api/dashboard/get-hard-limit

/// Member-facing spend limits for a token-based enterprise contract. Requires
/// `teamId` in the POST body — an empty body returns `{noUsageBasedAllowed:true}`
/// (all fields nil). `perUserMonthlyLimitDollars` is in **whole dollars**; the
/// matching used amount lives in `IndividualUsage.overall.used` (cents).
struct HardLimitResponse: Codable, Sendable {
    let hardLimit: Int?
    let hardLimitPerUser: Int?
    let perUserMonthlyLimitDollars: Int?
}

// MARK: - API Response: /api/auth/me

struct UserInfoResponse: Codable, Sendable {
    let email: String?
    let name: String?
}

// MARK: - UI Display Model

struct UsageDisplayData: Sendable {
    let email: String
    let name: String
    let membershipType: String?

    // Credit-based plan (cents) — nil when request-based
    let planUsedCents: Int?
    let planLimitCents: Int?

    // Server-calculated percentage (from totalPercentUsed)
    let serverPercentUsed: Double?

    // Request-based plan — 0 when credit-based
    let requestsUsed: Int
    let requestsLimit: Int

    let onDemandUsedCents: Int?
    let onDemandLimitCents: Int?
    let onDemandEnabled: Bool?
    /// Injected by UsageViewModel after sticky-latch logic. When true, the
    /// presentation computeds (percentUsed, usageLabel, usageText, menuBar*)
    /// reflect on-demand spend instead of the primary dimension.
    let isOnDemandActive: Bool
    let cycleStartDate: Date?
    let resetDate: Date?

    /// Dashboard "Cursor Models" bar (`autoPercentUsed`).
    let cursorModelsPercent: Double?
    /// Dashboard "Other Models" bar (`apiPercentUsed`).
    let otherModelsPercent: Double?

    init(
        email: String,
        name: String,
        membershipType: String?,
        planUsedCents: Int?,
        planLimitCents: Int?,
        serverPercentUsed: Double?,
        requestsUsed: Int,
        requestsLimit: Int,
        onDemandUsedCents: Int?,
        onDemandLimitCents: Int?,
        onDemandEnabled: Bool?,
        isOnDemandActive: Bool,
        cycleStartDate: Date?,
        resetDate: Date?,
        cursorModelsPercent: Double? = nil,
        otherModelsPercent: Double? = nil
    ) {
        self.email = email
        self.name = name
        self.membershipType = membershipType
        self.planUsedCents = planUsedCents
        self.planLimitCents = planLimitCents
        self.serverPercentUsed = serverPercentUsed
        self.requestsUsed = requestsUsed
        self.requestsLimit = requestsLimit
        self.onDemandUsedCents = onDemandUsedCents
        self.onDemandLimitCents = onDemandLimitCents
        self.onDemandEnabled = onDemandEnabled
        self.isOnDemandActive = isOnDemandActive
        self.cycleStartDate = cycleStartDate
        self.resetDate = resetDate
        self.cursorModelsPercent = cursorModelsPercent
        self.otherModelsPercent = otherModelsPercent
    }

    /// Both dashboard buckets present — popover shows the dual-meter layout.
    var hasBucketMeters: Bool {
        cursorModelsPercent != nil && otherModelsPercent != nil
    }

    /// Returns a copy with `isOnDemandActive` overridden. Used by UsageViewModel
    /// to inject the sticky-latched mode after computing it.
    func withOnDemandActive(_ active: Bool) -> UsageDisplayData {
        UsageDisplayData(
            email: email, name: name, membershipType: membershipType,
            planUsedCents: planUsedCents, planLimitCents: planLimitCents,
            serverPercentUsed: serverPercentUsed,
            requestsUsed: requestsUsed, requestsLimit: requestsLimit,
            onDemandUsedCents: onDemandUsedCents,
            onDemandLimitCents: onDemandLimitCents,
            onDemandEnabled: onDemandEnabled,
            isOnDemandActive: active,
            cycleStartDate: cycleStartDate,
            resetDate: resetDate,
            cursorModelsPercent: cursorModelsPercent,
            otherModelsPercent: otherModelsPercent
        )
    }

    var isCreditBased: Bool {
        planLimitCents != nil && planLimitCents! > 0
    }

    /// True when API provides no usable used/limit values (e.g. free plan)
    var isPercentOnly: Bool {
        !isCreditBased && requestsLimit == 0 && serverPercentUsed != nil
    }

    var percentUsed: Double {
        if isOnDemandActive {
            guard let limit = onDemandLimitCents, limit > 0,
                  let used = onDemandUsedCents else { return 0 }
            return Double(used) / Double(limit) * 100.0
        }
        // Ultra / split-quota plans: the ring and notifications follow
        // `totalPercentUsed`, not cents-used / cents-limit (bonus spend can
        // push that ratio well over 100% while the dashboard still shows ~40%).
        if hasBucketMeters, let server = serverPercentUsed { return server }
        if isPercentOnly, let server = serverPercentUsed { return server }
        if isCreditBased {
            guard let limit = planLimitCents, limit > 0, let used = planUsedCents else { return 0 }
            return Double(used) / Double(limit) * 100.0
        }
        guard requestsLimit > 0 else { return 0 }
        return Double(requestsUsed) / Double(requestsLimit) * 100.0
    }

    var percentText: String {
        // Round like Cursor's dashboard message ("3%" for 2.5), not truncate (#106).
        "\(Int(percentUsed.rounded()))%"
    }

    var usageText: String {
        if isOnDemandActive {
            return "\(Self.formatUSD(onDemandUsedCents ?? 0)) / \(Self.formatUSD(onDemandLimitCents ?? 0))"
        }
        if hasBucketMeters { return otherModelsHeaderText }
        if isPercentOnly { return percentText }
        if isCreditBased {
            return "\(Self.formatUSD(planUsedCents ?? 0)) / \(Self.formatUSD(planLimitCents ?? 0))"
        }
        return "\(requestsUsed) / \(requestsLimit)"
    }

    /// Compact fraction text for the menu bar icon (no `$`, 1 decimal for credit)
    var menuBarUsedText: String {
        if isOnDemandActive {
            return Self.formatCompactUSD(onDemandUsedCents ?? 0)
        }
        if hasBucketMeters { return menuBarBucketText }
        if isPercentOnly { return percentText }
        if isCreditBased {
            return Self.formatCompactUSD(planUsedCents ?? 0)
        }
        return "\(requestsUsed)"
    }

    var menuBarLimitText: String {
        if isOnDemandActive {
            return Self.formatCompactUSD(onDemandLimitCents ?? 0)
        }
        if hasBucketMeters || isPercentOnly { return "" }
        if isCreditBased {
            return Self.formatCompactUSD(planLimitCents ?? 0)
        }
        return "\(requestsLimit)"
    }

    var usageLabel: String {
        if isOnDemandActive { return "On-demand" }
        if hasBucketMeters { return cursorModelsHeaderText }
        if isPercentOnly { return "Plan Usage" }
        return isCreditBased ? "Plan Usage" : "Requests"
    }

    var cursorModelsHeaderText: String {
        "Cursor \(Self.roundedPercentText(cursorModelsPercent))"
    }

    var otherModelsHeaderText: String {
        "Other \(Self.roundedPercentText(otherModelsPercent))"
    }

    /// Compact dual-percent string for the menu-bar status item.
    var menuBarBucketText: String {
        "\(Self.roundedPercentText(cursorModelsPercent)) · \(Self.roundedPercentText(otherModelsPercent))"
    }

    /// Ring fill when both buckets are shown: the hotter of the two, so an
    /// 86% Other-Models bar is not hidden behind a 40% combined total.
    var menuBarRingPercent: Double {
        if isOnDemandActive { return percentUsed }
        if hasBucketMeters {
            return max(cursorModelsPercent ?? 0, otherModelsPercent ?? 0)
        }
        return percentUsed
    }

    nonisolated static func roundedPercentText(_ percent: Double?) -> String {
        "\(Int((percent ?? 0).rounded()))%"
    }

    var hasOnDemand: Bool {
        guard let limit = onDemandLimitCents, limit > 0 else { return false }
        // `enabled == false` means the team admin disabled on-demand mid-cycle;
        // treat as no on-demand even if a residual `used` value is reported.
        // `nil` (field absent) defaults to true for backward compat.
        return onDemandEnabled ?? true
    }

    /// True when the user's primary quota is exhausted AND on-demand is active.
    /// Pure derived value — does NOT include the sticky latch (that lives in
    /// UsageViewModel and is injected via `isOnDemandActive`).
    var wouldActivateOnDemand: Bool {
        guard hasOnDemand else { return false }
        if requestsLimit > 0 && requestsUsed >= requestsLimit { return true }
        if isCreditBased,
           let limit = planLimitCents, limit > 0,
           let used = planUsedCents, used >= limit { return true }
        return false
    }

    var onDemandText: String? {
        guard let used = onDemandUsedCents, let limit = onDemandLimitCents, limit > 0 else {
            return nil
        }
        return "\(Self.formatUSD(used)) / \(Self.formatUSD(limit))"
    }

    // MARK: - Secondary popover row (inverted display when on-demand active)

    /// In on-demand mode this is the previous primary (Requests or Plan);
    /// in normal mode this is On-demand (when present).
    var secondaryUsageLabel: String? {
        if isOnDemandActive {
            if isCreditBased { return "Plan" }
            return "Requests"
        }
        return hasOnDemand ? "On-demand" : nil
    }

    var secondaryUsageValue: String? {
        if isOnDemandActive {
            if isCreditBased {
                return "\(Self.formatUSD(planUsedCents ?? 0)) / \(Self.formatUSD(planLimitCents ?? 0))"
            }
            return "\(requestsUsed) / \(requestsLimit)"
        }
        return onDemandText
    }

    var secondaryUsageIsOverLimit: Bool {
        if isOnDemandActive {
            if isCreditBased,
               let limit = planLimitCents, limit > 0,
               let used = planUsedCents { return used >= limit }
            return requestsLimit > 0 && requestsUsed >= requestsLimit
        }
        return false
    }

    private static func formatUSD(_ cents: Int) -> String {
        String(format: "$%.2f", Double(cents) / 100.0)
    }

    /// Compact dollar format for menu bar: no `$` sign, 1 decimal place
    static func formatCompactUSD(_ cents: Int) -> String {
        String(format: "%.1f", Double(cents) / 100.0)
    }

    /// Daily request budget = `requestsLimit / cycleDays`. Returns nil when
    /// inputs are missing or the cycle window is non-positive. Used by the
    /// weekly chart's adaptive y-ceiling and dashed reference line.
    var dailyRequestBudget: Int? {
        guard requestsLimit > 0 else { return nil }
        guard let start = cycleStartDate, let end = resetDate else { return nil }
        let days = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
        guard days > 0 else { return nil }
        return requestsLimit / days
    }

    /// Render-time countdown label (#85). Pure so zone boundaries are
    /// unit-testable with an injected `now`. Floor in every zone: no unit
    /// overflow ("60m"/"48h" never render) and each zone hands off smoothly
    /// to the next. Days use elapsed seconds, not calendar days — DST/zone
    /// independent, and indistinguishable at ≥ 48h remaining.
    nonisolated static func resetCountdownText(until reset: Date, now: Date) -> String {
        let delta = reset.timeIntervalSince(now)
        if delta <= 0 { return "Resets today" }
        if delta < 60 { return "Resets in <1m" }
        if delta < 3600 { return "Resets in \(Int(delta / 60))m" }
        if delta < 48 * 3600 { return "Resets in \(Int(delta / 3600))h" }
        return "Resets in \(Int(delta / 86400)) days"
    }

    var resetText: String? {
        guard let resetDate else { return nil }
        return Self.resetCountdownText(until: resetDate, now: Date())
    }

    /// Local wall-clock cycle end for the tooltip, e.g. "7/10 07:24" (#85).
    /// Formatter is created per call: once per updateUI() makes caching
    /// pointless, and a shared mutable DateFormatter global is a concurrency
    /// footgun. Locale/calendar pinned so digits don't drift by user locale.
    var resetAbsoluteText: String? {
        guard let resetDate else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: resetDate)
    }

    // MARK: - Shared factory helpers

    /// ISO8601DateFormatter is a non-Sendable mutable reference type, so a
    /// shared static needed `nonisolated(unsafe)` — an opt-out of Swift 6
    /// checking that silently covered any future off-actor caller (#53 M-2).
    /// A per-call formatter costs microseconds and this runs a handful of
    /// times per refresh.
    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)
    }

    private static func requestCount(_ model: ModelUsage?) -> Int {
        model?.numRequestsTotal ?? model?.numRequests ?? 0
    }

    /// Extracts a leading integer percentage from Cursor's display message
    /// ("You've used 0% of your included total usage" → 0). Returns nil when
    /// no `N%` token is present. Lets token-based enterprise plans — which
    /// expose included usage only as this sentence — render via percent-only
    /// mode instead of a meaningless `0 / 0`.
    private static func percent(from message: String?) -> Double? {
        guard let message,
              let match = message.range(of: #"\d+%"#, options: .regularExpression)
        else { return nil }
        return Double(message[match].dropLast())
    }

    // MARK: - Factory: summary (primary) + usage (supplementary)

    static func from(
        summary: UsageSummaryResponse,
        usage: UsageResponse?,
        userInfo: UserInfoResponse,
        perUserMonthlyLimitDollars: Int? = nil,
        perUserOnDemandLimitDollars: Int? = nil,
        period: CurrentPeriodUsageResponse? = nil
    ) -> UsageDisplayData {
        let model = usage?.primaryModel
        let isRequestBased = model?.maxRequestUsage != nil
        let resetDate = parseDate(summary.billingCycleEnd)
        let plan = summary.individualUsage?.plan

        // Token-based enterprise contracts ship no `plan` object: spend lives in
        // `individualUsage.overall.used` (cents) and the per-seat limit in either
        // `overall.limit` (eventually populated) or the hard-limit endpoint
        // (whole dollars). Synthesize a credit-style plan from them so the popover
        // mirrors Cursor's dashboard ($used / $limit). `??` keeps every existing
        // path intact — a real `plan` always wins.
        let overall = summary.individualUsage?.overall
        let isTokenBased = plan == nil && overall != nil
        let planUsedCents = plan?.used ?? overall?.used
        let planLimitCents = plan?.limit
            ?? overall?.limit
            ?? perUserMonthlyLimitDollars.map { $0 * 100 }

        // On-demand. Non-token plans use the API's on-demand block (team-wide on
        // enterprise). Token-based members instead get a PERSONAL view: spend
        // beyond the included limit (overflow, $0 until included is exhausted)
        // against their per-seat cap. NOTE: overflow saturates if the API caps
        // `overall.used` at its limit — acceptable while included is far from
        // exhausted; revisit via on-demand event summing if it ever matters.
        let onDemandUsedCents: Int?
        let onDemandLimitCents: Int?
        let onDemandEnabled: Bool?
        if isTokenBased {
            onDemandLimitCents = perUserOnDemandLimitDollars.map { $0 * 100 }
            if let limit = planLimitCents, onDemandLimitCents != nil {
                onDemandUsedCents = max(0, (planUsedCents ?? 0) - limit)
                onDemandEnabled = true
            } else {
                // No included limit or no per-seat cap resolved → hide the row
                // rather than show the misleading team-wide figure.
                onDemandUsedCents = nil
                onDemandEnabled = nil
            }
        } else {
            let onDemand = summary.individualUsage?.onDemand
                ?? summary.teamUsage?.onDemand
            onDemandUsedCents = onDemand?.used
            onDemandLimitCents = onDemand?.limit
            onDemandEnabled = onDemand?.enabled
        }

        let periodPlan = period?.planUsage
        let cursorPercent = periodPlan?.autoPercentUsed ?? plan?.autoPercentUsed
        let otherPercent = periodPlan?.apiPercentUsed ?? plan?.apiPercentUsed
        let totalPercent = periodPlan?.totalPercentUsed
            ?? plan?.totalPercentUsed
            ?? Self.percent(from: summary.autoModelSelectedDisplayMessage)
        let buckets = cursorPercent != nil && otherPercent != nil

        return UsageDisplayData(
            email: userInfo.email ?? "Unknown",
            name: userInfo.name ?? "Unknown",
            membershipType: summary.membershipType,
            planUsedCents: isRequestBased ? nil : planUsedCents,
            planLimitCents: isRequestBased ? nil : planLimitCents,
            serverPercentUsed: totalPercent,
            requestsUsed: isRequestBased ? requestCount(model) : 0,
            requestsLimit: isRequestBased ? (model?.maxRequestUsage ?? 0) : 0,
            onDemandUsedCents: onDemandUsedCents,
            onDemandLimitCents: onDemandLimitCents,
            onDemandEnabled: onDemandEnabled,
            isOnDemandActive: false,
            cycleStartDate: parseDate(summary.billingCycleStart),
            resetDate: resetDate,
            cursorModelsPercent: buckets ? cursorPercent : nil,
            otherModelsPercent: buckets ? otherPercent : nil
        )
    }

    // MARK: - Factory: legacy fallback (usage only)

    static func from(usage: UsageResponse, userInfo: UserInfoResponse) -> UsageDisplayData {
        let model = usage.primaryModel
        let resetDate: Date? = parseDate(usage.startOfMonth).flatMap {
            Calendar.current.date(byAdding: .month, value: 1, to: $0)
        }

        return UsageDisplayData(
            email: userInfo.email ?? "Unknown",
            name: userInfo.name ?? "Unknown",
            membershipType: nil,
            planUsedCents: nil,
            planLimitCents: nil,
            serverPercentUsed: nil,
            requestsUsed: requestCount(model),
            requestsLimit: model?.maxRequestUsage ?? 0,
            onDemandUsedCents: nil,
            onDemandLimitCents: nil,
            onDemandEnabled: nil,
            isOnDemandActive: false,
            cycleStartDate: nil,
            resetDate: resetDate
        )
    }
}
