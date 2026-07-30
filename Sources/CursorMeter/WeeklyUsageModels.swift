import Foundation

// MARK: - API Response: /api/dashboard/get-filtered-usage-events

/// Per-event usage stream from Cursor's dashboard backend. Used by the weekly
/// bar graph (enterprise team + personal accounts, #103). See
/// `docs/API_REFERENCE.md` for the request shape and the Origin-header requirement.
struct FilteredUsageEventsResponse: Codable, Sendable {
    let totalUsageEventsCount: Int?
    let usageEventsDisplay: [UsageEvent]
}

struct UsageEvent: Codable, Sendable {
    /// UTC epoch milliseconds as a string (e.g. "1780402687672").
    let timestamp: String
    /// Cursor's weighted billing unit — light auto-completes weigh 1, Max-mode
    /// Opus calls can weigh 100+. Same unit as the plan limit (`Requests: 519 / 2000`).
    /// Nullable on errored / non-chargeable events.
    let requestsCosts: Double?
    /// Event classification — drives per-day chart mode (plan vs on-demand).
    /// Observed values: `USAGE_EVENT_KIND_INCLUDED_IN_BUSINESS`, `_FREE_CREDIT`,
    /// `_ERRORED_NOT_CHARGED`, `_USAGE_BASED`. Unknown values are treated as plan.
    let kind: String?
    /// Cents charged for this event. For `_USAGE_BASED` events this is what hits
    /// the user's on-demand cap; for other kinds it's a fair-value reference
    /// not billed to the user. Fractional cents (e.g. 95.69) are normal.
    let chargedCents: Double?

    init(
        timestamp: String,
        requestsCosts: Double? = nil,
        kind: String? = nil,
        chargedCents: Double? = nil
    ) {
        self.timestamp = timestamp
        self.requestsCosts = requestsCosts
        self.kind = kind
        self.chargedCents = chargedCents
    }

    /// `Date` parsed from `timestamp`. Returns nil for malformed input.
    var date: Date? {
        guard let ms = Double(timestamp) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }

    /// Defensive accessor — nil / non-finite values count as 0 so a single
    /// malformed event can't crash or skew the daily sum.
    var requestsCostsSafe: Double {
        guard let v = requestsCosts, v.isFinite else { return 0 }
        return v
    }

    var chargedCentsSafe: Double {
        guard let v = chargedCents, v.isFinite else { return 0 }
        return v
    }

    /// True when this event was billed to the user's on-demand cap (i.e. plan
    /// did not absorb it). Determines whether the containing day renders as an
    /// on-demand day in the weekly chart.
    var isOnDemandBilled: Bool {
        kind == "USAGE_EVENT_KIND_USAGE_BASED"
    }
}

// MARK: - API Response: /api/dashboard/teams (unchanged from previous version)

/// Minimal shape — only the fields needed to pick a `teamId` for the
/// dashboard endpoint. The real Cursor dashboard response carries more fields;
/// everything outside `id`/`name` is ignored.
struct TeamsResponse: Codable, Sendable {
    let teams: [Team]
}

struct Team: Codable, Sendable {
    let id: Int
    let name: String?
}

// MARK: - API Response: /api/dashboard/get-team-spend
// Discovers the numeric userId (for the weekly chart) and, on token-based
// enterprise contracts, the member's per-seat on-demand limit.

struct TeamSpendResponse: Codable, Sendable {
    let teamMemberSpend: [TeamMember]
}

struct TeamMember: Codable, Sendable {
    let userId: Int
    let email: String?
    /// Per-seat on-demand (usage-based) spend cap in whole dollars. An admin
    /// override of the team default (`hardLimitPerUser`); nil when unset.
    let hardLimitOverrideDollars: Int?
}

// MARK: - 7-day rolling display model

struct DayUsage: Sendable, Equatable {
    let date: Date
    /// Sum of `requestsCosts` across every event of the day. Drives bar height
    /// regardless of mode — keeps the y-axis comparable across the 7-day window
    /// even when some bars are plan days and others are on-demand days.
    let requests: Int
    let isToday: Bool
    /// True when any event of the day was billed `_USAGE_BASED` (on-demand).
    /// Drives the tooltip label switch (`$X.XX` instead of the raw integer).
    let isOnDemand: Bool
    /// Sum of `chargedCents` across the day's on-demand-billed events only.
    /// Zero on plan-only days. Displayed as `$X.XX` in the tooltip when
    /// `isOnDemand == true`.
    let onDemandCents: Int
    /// Sum of `chargedCents` across every event of the day (regardless of kind).
    /// Used as the plan-day tooltip value on token-based enterprise plans where
    /// the plan denominator itself is dollars (#72). Request-quota plans ignore
    /// this and keep the raw `requests` integer in the tooltip.
    let totalChargedCents: Int
}

extension Array where Element == UsageEvent {
    /// Builds an ordered 7-day array ending on `today` (rightmost). Sums each
    /// event's `requestsCosts` into its local-calendar day; rounds the final
    /// per-day sum to the nearest Int for the chart's display shape. Events
    /// older than the 7-day window are silently ignored.
    ///
    /// `calendar` controls day boundary interpretation (pass `Calendar.current`
    /// in production for KST handling; inject a UTC calendar in tests for
    /// determinism).
    func sevenDayRolling(today: Date = Date(), calendar: Calendar = .current) -> [DayUsage] {
        let startOfToday = calendar.startOfDay(for: today)
        let cutoff = calendar.date(byAdding: .day, value: -6, to: startOfToday)!

        // Bucket on the local-midnight `Date` itself — `startOfDay` is already
        // computed for the window math, so a `yyyy-MM-dd` string key (and the
        // shared DateFormatter cache behind it) bought nothing and was a data
        // race off the main actor (#53 M-2).
        var buckets: [Date: (requestsSum: Double, onDemandCents: Double, totalCents: Double, hasOnDemand: Bool)] = [:]
        for event in self {
            guard let eventDate = event.date else { continue }
            let key = calendar.startOfDay(for: eventDate)
            guard key >= cutoff, key <= startOfToday else { continue }
            var b = buckets[key] ?? (0, 0, 0, false)
            b.requestsSum += event.requestsCostsSafe
            b.totalCents += event.chargedCentsSafe
            if event.isOnDemandBilled {
                b.hasOnDemand = true
                b.onDemandCents += event.chargedCentsSafe
            }
            buckets[key] = b
        }

        return (0..<7).reversed().map { offset in
            let day = calendar.date(byAdding: .day, value: -offset, to: startOfToday)!
            let b = buckets[day] ?? (0, 0, 0, false)
            return DayUsage(
                date: day,
                requests: Int(b.requestsSum.rounded()),
                isToday: offset == 0,
                isOnDemand: b.hasOnDemand,
                onDemandCents: Int(b.onDemandCents.rounded()),
                totalChargedCents: Int(b.totalCents.rounded())
            )
        }
    }

    /// Returns the oldest event's date in the receiver, or nil if none parses.
    /// Used by the paginator to decide whether to fetch another page.
    func oldestEventDate() -> Date? {
        var oldest: Date?
        for event in self {
            guard let d = event.date else { continue }
            if let curr = oldest {
                if d < curr { oldest = d }
            } else {
                oldest = d
            }
        }
        return oldest
    }

}
