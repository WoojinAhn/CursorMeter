import Foundation

enum RecentUsageKind: String, Codable, Sendable {
    case included
    case onDemand
    case free
    case other

    var title: String {
        switch self {
        case .included: "Included"
        case .onDemand: "On-demand"
        case .free: "Free"
        case .other: "Other"
        }
    }

    init(event: UsageEvent) {
        if event.kind?.hasPrefix("USAGE_EVENT_KIND_INCLUDED_IN_") == true {
            self = .included
        } else if event.kind == "USAGE_EVENT_KIND_USAGE_BASED" {
            self = .onDemand
        } else if event.kind == "USAGE_EVENT_KIND_FREE_CREDIT"
                    || (event.kind == "USAGE_EVENT_KIND_CUSTOM_SUBSCRIPTION" && event.customSubscriptionName == "free") {
            self = .free
        } else {
            self = .other
        }
    }
}

struct RecentUsageEntry: Codable, Equatable, Sendable {
    let date: Date
    let model: String?
    let kind: RecentUsageKind
    let tokens: Int?
    let chargedCents: Double?

    init(date: Date, model: String?, kind: RecentUsageKind, tokens: Int?, chargedCents: Double?) {
        self.date = date
        self.model = model
        self.kind = kind
        self.tokens = tokens
        self.chargedCents = chargedCents
    }

    init?(event: UsageEvent) {
        guard let milliseconds = Double(event.timestamp), milliseconds.isFinite,
              let date = event.date else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // Foundation clamps calendar operations outside its representable range.
        guard let second = calendar.dateInterval(of: .second, for: date), second.contains(date) else { return nil }
        self.init(
            date: date,
            model: event.model,
            kind: RecentUsageKind(event: event),
            tokens: event.tokenUsage?.total,
            chargedCents: event.chargedCents.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        )
    }
}

struct RecentUsageCandidate: Codable, Equatable, Sendable {
    static let limit = 30
    let entries: [RecentUsageEntry]
    let cachedAt: Date

    /// Applies the same bound to assembled snapshots; decoded caches are validated by the store.
    init(entries: [RecentUsageEntry], cachedAt: Date) {
        self.entries = Array(entries.prefix(Self.limit))
        self.cachedAt = cachedAt
    }

    init?(response: FilteredUsageEventsResponse, cachedAt: Date) {
        guard response.hasUsageEventsDisplay || response.totalUsageEventsCount == 0 else { return nil }
        let indexed: [(Int, RecentUsageEntry)] = response.usageEventsDisplay.enumerated().compactMap { index, event in
            RecentUsageEntry(event: event).map { (index, $0) }
        }
        let sorted = indexed.sorted { lhs, rhs in
            lhs.1.date == rhs.1.date ? lhs.0 < rhs.0 : lhs.1.date > rhs.1.date
        }
        guard response.usageEventsDisplay.isEmpty || !sorted.isEmpty else { return nil }
        self.init(entries: sorted.prefix(Self.limit).map { $0.1 }, cachedAt: cachedAt)
    }
}

enum RecentUsageTimeZone: String, Codable, CaseIterable, Sendable {
    case local
    case utc

    init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .local
    }
}
