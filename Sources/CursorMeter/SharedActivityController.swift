import Foundation
import Observation

@MainActor @Observable
final class SharedActivityController {
    private(set) var recent: SharedUsageReading<RecentUsageCandidate> = .empty
    private(set) var daily: SharedUsageReading<[DayUsage]> = .empty
    private(set) var paidReset: SharedUsageReading<SharedPaidPeriod> = .empty
    private(set) var allowance: SharedAllowanceCalibration?
    private(set) var observation: SharedAllowanceObservation?
    @ObservationIgnored private var previousObservation: SharedAllowanceObservation?
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
        invalidateAllowance()
    }

    func recordFailure() {
        revision &+= 1
        recent = recent.failed(.invalidResponse)
        daily = daily.failed(.invalidResponse)
        paidReset = paidReset.failed(.invalidResponse)
        invalidateAllowance()
    }

    func suspendAllowance() {
        revision &+= 1
        allowance = nil
        observation = nil
    }

    private func invalidateAllowance() {
        allowance = nil
        observation = nil
        previousObservation = nil
    }

    func currentAllowance(matching weekly: SharedWeeklyUsage?) -> SharedAllowanceCalibration? {
        guard let allowance, allowance.isCurrent(matching: weekly, at: now()),
              recent.availability == .current else { return nil }
        return allowance
    }

    func refresh(cookieHeader: String, owner: SharedUsageOwner, weekly: SharedWeeklyUsage? = nil,
                 weeklyObservedAt: Date? = nil, confirmationProvider: (any CursorSharedUsageFetching)? = nil,
                 currentWeekly: @MainActor () -> SharedWeeklyUsage? = { nil },
                 isCurrent: @MainActor () -> Bool) async -> Bool {
        guard self.owner == owner, isCurrent(), !Task.isCancelled else { return false }
        suspendAllowance()
        let revision = revision
        let end = now()
        let observedAt = weeklyObservedAt ?? end
        if let weekly, weekly == currentWeekly(), observedAt <= end,
           let observed = SharedAllowanceObservation(weekly: weekly, at: observedAt, previous: previousObservation) {
            observation = observed
            previousObservation = observed
        } else { invalidateAllowance() }
        guard let provider else { return false }
        let eligible = weekly.flatMap { SharedAllowanceCalibration(weekly: $0, includedTokens: 1, through: end, confirmedAt: end) } != nil
            && weekly == currentWeekly() && confirmationProvider != nil
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
            if eligible, let weekly, let period = weekly.period, let confirmationProvider {
                group.addTask { .allowance(await Self.capture {
                    let total = try await provider.fetchDaily(cookieHeader: cookieHeader, start: period.start, end: end)
                        .includedTokens(start: period.start, end: end)
                    try Task.checkCancellation()
                    let confirmed = try await confirmationProvider.fetchCurrentPeriod(cookieHeader: cookieHeader)
                    guard confirmed.cycle == period, confirmed.planUsage?.totalPercentUsed == weekly.percentUsed else {
                        throw CursorSharedAPIError.invalidResponse
                    }
                    return total
                }) }
            }
            var calibratedTokens: Int?
            for await response in group {
                guard self.owner == owner, self.revision == revision, isCurrent(), !Task.isCancelled else {
                    group.cancelAll()
                    continue
                }
                switch response {
                case .recent(let result): recent = Self.reading(recent, result, at: now())
                case .daily(let result): daily = Self.reading(daily, result, at: now())
                case .reset(let result): paidReset = Self.reading(paidReset, result, at: now())
                case .allowance(let result): calibratedTokens = try? result.get()
                }
            }
            let current = self.owner == owner && self.revision == revision && isCurrent() && !Task.isCancelled
            if current, recent.availability == .current, weekly == currentWeekly(),
               let weekly, let calibratedTokens,
               let calibration = SharedAllowanceCalibration(weekly: weekly, includedTokens: calibratedTokens, through: end, confirmedAt: now()) {
                allowance = calibration
            }
            if self.owner == owner && self.revision == revision,
               !current || weekly != currentWeekly() || observation?.weekly.hasIncludedUsage(at: now()) == nil {
                invalidateAllowance()
            }
            return current && recent.availability == .current
        }
    }

    private enum Response: Sendable {
        case recent(Result<RecentUsageCandidate, CursorSharedAPIError>)
        case daily(Result<[DayUsage], CursorSharedAPIError>)
        case reset(Result<SharedPaidPeriod, CursorSharedAPIError>)
        case allowance(Result<Int, CursorSharedAPIError>)
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
