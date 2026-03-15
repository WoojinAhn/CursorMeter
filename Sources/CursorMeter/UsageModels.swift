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
    let individualUsage: IndividualUsage?
    let teamUsage: TeamUsage?
}

struct IndividualUsage: Codable, Sendable {
    let plan: PlanUsage?
    let onDemand: OnDemandUsage?
}

struct PlanUsage: Codable, Sendable {
    let enabled: Bool?
    let used: Int?
    let limit: Int?
    let remaining: Int?
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
    let resetDate: Date?
    let daysUntilReset: Int?

    var isCreditBased: Bool {
        planLimitCents != nil && planLimitCents! > 0
    }

    /// True when API provides no usable used/limit values (e.g. free plan)
    var isPercentOnly: Bool {
        !isCreditBased && requestsLimit == 0 && serverPercentUsed != nil
    }

    var percentUsed: Double {
        if isPercentOnly, let server = serverPercentUsed { return server }
        if isCreditBased {
            guard let limit = planLimitCents, limit > 0, let used = planUsedCents else { return 0 }
            return Double(used) / Double(limit) * 100.0
        }
        guard requestsLimit > 0 else { return 0 }
        return Double(requestsUsed) / Double(requestsLimit) * 100.0
    }

    var percentText: String {
        "\(Int(percentUsed))%"
    }

    var usageText: String {
        if isPercentOnly { return percentText }
        if isCreditBased {
            return "\(Self.formatUSD(planUsedCents ?? 0)) / \(Self.formatUSD(planLimitCents ?? 0))"
        }
        return "\(requestsUsed) / \(requestsLimit)"
    }

    /// Compact fraction text for the menu bar icon (no `$`, 1 decimal for credit)
    var menuBarUsedText: String {
        if isPercentOnly { return percentText }
        if isCreditBased {
            return Self.formatCompactUSD(planUsedCents ?? 0)
        }
        return "\(requestsUsed)"
    }

    var menuBarLimitText: String {
        if isPercentOnly { return "" }
        if isCreditBased {
            return Self.formatCompactUSD(planLimitCents ?? 0)
        }
        return "\(requestsLimit)"
    }

    var usageLabel: String {
        if isPercentOnly { return "Plan Usage" }
        return isCreditBased ? "Plan Usage" : "Requests"
    }

    var hasOnDemand: Bool {
        onDemandLimitCents != nil && onDemandLimitCents! > 0
    }

    var onDemandText: String? {
        guard let used = onDemandUsedCents, let limit = onDemandLimitCents, limit > 0 else {
            return nil
        }
        return "\(Self.formatUSD(used)) / \(Self.formatUSD(limit))"
    }

    private static func formatUSD(_ cents: Int) -> String {
        String(format: "$%.2f", Double(cents) / 100.0)
    }

    /// Compact dollar format for menu bar: no `$` sign, 1 decimal place
    static func formatCompactUSD(_ cents: Int) -> String {
        String(format: "%.1f", Double(cents) / 100.0)
    }

    var resetText: String? {
        guard let days = daysUntilReset else { return nil }
        if days <= 0 { return "Resets today" }
        if days == 1 { return "Resets tomorrow" }
        return "Resets in \(days) days"
    }

    private nonisolated(unsafe) static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    // MARK: - Factory: summary (primary) + usage (supplementary)

    static func from(
        summary: UsageSummaryResponse,
        usage: UsageResponse?,
        userInfo: UserInfoResponse
    ) -> UsageDisplayData {
        let model = usage?.primaryModel
        let isRequestBased = model?.maxRequestUsage != nil

        let resetDate: Date? = {
            guard let str = summary.billingCycleEnd else { return nil }
            return iso8601.date(from: str)
        }()

        let daysUntilReset: Int? = {
            guard let end = resetDate else { return nil }
            return Calendar.current.dateComponents([.day], from: Date(), to: end).day
        }()

        let plan = summary.individualUsage?.plan
        let onDemand = summary.individualUsage?.onDemand

        return UsageDisplayData(
            email: userInfo.email ?? "Unknown",
            name: userInfo.name ?? "Unknown",
            membershipType: summary.membershipType,
            planUsedCents: isRequestBased ? nil : plan?.used,
            planLimitCents: isRequestBased ? nil : plan?.limit,
            serverPercentUsed: plan?.totalPercentUsed,
            requestsUsed: isRequestBased ? (model?.numRequestsTotal ?? model?.numRequests ?? 0) : 0,
            requestsLimit: isRequestBased ? (model?.maxRequestUsage ?? 0) : 0,
            onDemandUsedCents: onDemand?.used,
            onDemandLimitCents: onDemand?.limit,
            resetDate: resetDate,
            daysUntilReset: daysUntilReset
        )
    }

    // MARK: - Factory: legacy fallback (usage only)

    static func from(usage: UsageResponse, userInfo: UserInfoResponse) -> UsageDisplayData {
        let model = usage.primaryModel

        let resetDate: Date? = {
            guard let str = usage.startOfMonth else { return nil }
            guard let start = iso8601.date(from: str) else { return nil }
            return Calendar.current.date(byAdding: .month, value: 1, to: start)
        }()

        let daysUntilReset: Int? = {
            guard let end = resetDate else { return nil }
            return Calendar.current.dateComponents([.day], from: Date(), to: end).day
        }()

        return UsageDisplayData(
            email: userInfo.email ?? "Unknown",
            name: userInfo.name ?? "Unknown",
            membershipType: nil,
            planUsedCents: nil,
            planLimitCents: nil,
            serverPercentUsed: nil,
            requestsUsed: model?.numRequestsTotal ?? model?.numRequests ?? 0,
            requestsLimit: model?.maxRequestUsage ?? 0,
            onDemandUsedCents: nil,
            onDemandLimitCents: nil,
            resetDate: resetDate,
            daysUntilReset: daysUntilReset
        )
    }
}
