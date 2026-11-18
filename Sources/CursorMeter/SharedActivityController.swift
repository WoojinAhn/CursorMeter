import Foundation
import Observation

@MainActor @Observable
final class SharedActivityController {
    private(set) var recent: SharedUsageReading<RecentUsageCandidate> = .empty
    private(set) var daily: SharedUsageReading<[DayUsage]> = .empty
    private(set) var paidReset: SharedUsageReading<SharedPaidPeriod> = .empty
    @ObservationIgnored private let provider: (any CursorSharedActivityFetching)?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var owner: SharedUsageOwner?
    @ObservationIgnored private var revision: UInt64 = 0

    init(provider: (any CursorSharedActivityFetching)? = nil, now: @escaping @MainActor () -> Date = Date.init) {
        self.provider = provider
        self.now = now
    }

    func bind(_ owner: SharedUsageOwner?) {
        guard self.owner != owner else { return }
        reset()
        self.owner = owner
    }

    func reset() {
        revision &+= 1
        owner = nil
        recent = .empty
        daily = .empty
        paidReset = .empty
    }

    func recordFailure() {
        revision &+= 1
        recent = recent.failed(.invalidResponse)
        daily = daily.failed(.invalidResponse)
        paidReset = paidReset.failed(.invalidResponse)
    }

    func refresh(cookieHeader: String, owner: SharedUsageOwner, isCurrent: @MainActor () -> Bool) async -> Bool {
        guard let provider, self.owner == owner, isCurrent(), !Task.isCancelled else { return false }
        revision &+= 1
        let revision = revision
        let end = now()
        let start = SharedActivityValue.utc.date(byAdding: .day, value: -6, to: SharedActivityValue.utc.startOfDay(for: end))!
        return await withTaskGroup(of: Response.self) { group in
            group.addTask { .recent(await Self.capture {
                try await provider.fetchRecent(cookieHeader: cookieHeader, start: end.addingTimeInterval(-30 * 86400), end: end)
                    .candidate(start: end.addingTimeInterval(-30 * 86400), end: end)
            }) }
            group.addTask { .daily(await Self.capture {
                try await provider.fetchDaily(cookieHeader: cookieHeader, start: start, end: end).days(start: start, end: end)
            }) }
            group.addTask { .reset(await Self.capture {
                let status = try await provider.fetchStatus(cookieHeader: cookieHeader)
                if status.identityUnlinked { throw CursorSharedAPIError.identityUnlinked }
                guard let period = status.paidPeriod(at: end) else { throw CursorSharedAPIError.invalidResponse }
                return period
            }) }
            for await response in group {
                guard self.owner == owner, self.revision == revision, isCurrent(), !Task.isCancelled else {
                    group.cancelAll()
                    continue
                }
                switch response {
                case .recent(let result): recent = Self.reading(recent, result, at: now())
                case .daily(let result): daily = Self.reading(daily, result, at: now())
                case .reset(let result): paidReset = Self.reading(paidReset, result, at: now())
                }
            }
            return self.owner == owner && self.revision == revision && isCurrent() && !Task.isCancelled
                && recent.availability == .current
        }
    }

    private enum Response: Sendable {
        case recent(Result<RecentUsageCandidate, CursorSharedAPIError>)
        case daily(Result<[DayUsage], CursorSharedAPIError>)
        case reset(Result<SharedPaidPeriod, CursorSharedAPIError>)
    }

    private static func reading<T>(_ old: SharedUsageReading<T>, _ result: Result<T, CursorSharedAPIError>, at date: Date) -> SharedUsageReading<T> {
        switch result {
        case .success(let value): old.received(value, at: date)
        case .failure(let error): (error == .identityUnlinked ? .empty : old).failed(error)
        }
    }
    nonisolated private static func capture<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, CursorSharedAPIError> {
        do { return .success(try await body()) }
        catch { return .failure(error as? CursorSharedAPIError ?? (error is CancellationError ? .cancelled : .transport)) }
    }
}
