import Foundation

struct UsageEventCollection: Sendable {
    let recent: RecentUsageCandidate?
    let weekly: Result<[UsageEvent], Error>

    static func collect(
        apiClient: CursorAPIClient,
        cookieHeader: String,
        teamId: Int,
        userId: Int?,
        pageSize: Int,
        maxPages: Int,
        today: Date = Date(),
        calendar: Calendar = .current,
        now: @Sendable () -> Date = { Date() }
    ) async -> Self {
        let cutoff = calendar.date(
            byAdding: .day,
            value: -6,
            to: calendar.startOfDay(for: today)
        )!
        var recent: RecentUsageCandidate?
        var collected: [UsageEvent] = []
        do {
            for page in 1...maxPages {
                try Task.checkCancellation()
                let response = try await apiClient.fetchWeeklyUsage(
                    cookieHeader: cookieHeader,
                    teamId: teamId,
                    userId: userId,
                    page: page,
                    pageSize: pageSize
                )
                try Task.checkCancellation()
                if page == 1 {
                    recent = RecentUsageCandidate(response: response, cachedAt: now())
                }
                let events = response.usageEventsDisplay
                collected.append(contentsOf: events)
                if events.isEmpty { break }
                if let total = response.totalUsageEventsCount, collected.count >= total { break }
                guard let oldest = events.oldestEventDate() else { break }
                if oldest < cutoff { break }
            }
            try Task.checkCancellation()
            return Self(recent: recent, weekly: .success(collected))
        } catch {
            let preservesRecent: Bool
            switch error {
            case APIError.networkError, is URLError:
                preservesRecent = true
            case APIError.httpError(let status):
                preservesRecent = status == 408 || status == 429 || (500...599).contains(status)
            default:
                preservesRecent = false
            }
            return Self(
                recent: preservesRecent && !Task.isCancelled && !isCancellation(error) ? recent : nil,
                weekly: .failure(error)
            )
        }
    }

    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? URLError { return error.code == .cancelled }
        if case APIError.networkError(let underlying) = error {
            return isCancellation(underlying)
        }
        return false
    }
}
