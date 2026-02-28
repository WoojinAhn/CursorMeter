import Foundation

// MARK: - API Response: /api/usage

struct UsageResponse: Codable, Sendable {
    let gpt4: ModelUsage?
    let startOfMonth: String?

    enum CodingKeys: String, CodingKey {
        case gpt4 = "gpt-4"
        case startOfMonth
    }
}

struct ModelUsage: Codable, Sendable {
    let numRequests: Int?
    let numRequestsTotal: Int?
    let numTokens: Int?
    let maxRequestUsage: Int?
    let maxTokenUsage: Int?
}

// MARK: - API Response: /api/auth/me

struct UserInfoResponse: Codable, Sendable {
    let email: String?
    let name: String?
    let sub: String?
}

// MARK: - UI Display Model

struct UsageDisplayData: Sendable {
    let email: String
    let name: String
    let requestsUsed: Int
    let requestsLimit: Int
    let resetDate: Date?
    let daysUntilReset: Int?

    var percentUsed: Double {
        guard requestsLimit > 0 else { return 0 }
        return Double(requestsUsed) / Double(requestsLimit) * 100.0
    }

    var percentText: String {
        "\(Int(percentUsed))%"
    }

    var usageText: String {
        "\(requestsUsed) / \(requestsLimit)"
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

    static func from(usage: UsageResponse, userInfo: UserInfoResponse) -> UsageDisplayData {
        let model = usage.gpt4

        let resetDate: Date? = {
            guard let str = usage.startOfMonth else { return nil }
            guard let start = iso8601.date(from: str) else { return nil }
            // Reset date = start of next month
            return Calendar.current.date(byAdding: .month, value: 1, to: start)
        }()

        let daysUntilReset: Int? = {
            guard let end = resetDate else { return nil }
            return Calendar.current.dateComponents([.day], from: Date(), to: end).day
        }()

        return UsageDisplayData(
            email: userInfo.email ?? "Unknown",
            name: userInfo.name ?? "Unknown",
            requestsUsed: model?.numRequests ?? 0,
            requestsLimit: model?.maxRequestUsage ?? 0,
            resetDate: resetDate,
            daysUntilReset: daysUntilReset
        )
    }
}
