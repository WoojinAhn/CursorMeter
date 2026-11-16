import Foundation
import Observation

struct SharedUsageOwner: Equatable, Sendable {
    let generation: UInt64
    let credentialDigest: String
    let subjectDigest: String
}

enum SharedUsageMode: Equatable, Sendable {
    case disabled, checking, legacy, sharedWeekly, unsupported, unavailable
}

enum SharedReadingAvailability: Equatable, Sendable {
    case unavailable, current, stale
}

struct SharedUsageReading<Value: Sendable>: Sendable {
    let value: Value?
    let lastSuccessAt: Date?
    let isStale: Bool
    let error: CursorSharedAPIError?

    static var empty: Self { .init(value: nil, lastSuccessAt: nil, isStale: false, error: nil) }

    func failed(_ error: CursorSharedAPIError) -> Self {
        .init(value: value, lastSuccessAt: lastSuccessAt, isStale: value != nil, error: error)
    }

    func received(_ value: Value?, at date: Date) -> Self {
        guard let value else { return failed(.invalidResponse) }
        return .init(value: value, lastSuccessAt: date, isStale: false, error: nil)
    }

    var availability: SharedReadingAvailability {
        value == nil ? .unavailable : (isStale ? .stale : .current)
    }
}

struct SharedUsageSnapshot: Sendable {
    let weekly: SharedUsageReading<SharedWeeklyUsage>
    let credit: SharedUsageReading<PrepaidCreditUsage>
    let monthlyUsed: SharedUsageReading<Decimal>
    let paidCap: SharedUsageReading<SharedPaidCap>
    let autoTopUp: SharedUsageReading<CursorAutoTopUp>

    static var empty: Self {
        .init(weekly: .empty, credit: .empty, monthlyUsed: .empty, paidCap: .empty, autoTopUp: .empty)
    }

    var isStale: Bool {
        weekly.isStale || credit.isStale || monthlyUsed.isStale || paidCap.isStale || autoTopUp.isStale
    }

    var isComplete: Bool {
        weekly.availability == .current && credit.availability == .current
            && monthlyUsed.availability == .current && paidCap.availability == .current
    }

    func failing(_ error: CursorSharedAPIError) -> Self {
        .init(weekly: weekly.failed(error), credit: credit.failed(error), monthlyUsed: monthlyUsed.failed(error),
              paidCap: paidCap.failed(error), autoTopUp: autoTopUp.failed(error))
    }

    var paid: SharedPaidUsage { .init(usedCents: monthlyUsed.value, cap: paidCap.value ?? .unknown) }
    func weeklyAvailability(at date: Date) -> SharedReadingAvailability {
        guard weekly.availability == .current else { return weekly.availability }
        return weekly.value?.hasIncludedUsage(at: date) == nil ? .stale : .current
    }

    func hasIncludedUsage(at date: Date) -> Bool? {
        weeklyAvailability(at: date) == .current ? weekly.value?.hasIncludedUsage(at: date) : nil
    }
}

@MainActor @Observable
final class SharedUsageController {
    private(set) var mode: SharedUsageMode = .checking
    private(set) var snapshot: SharedUsageSnapshot?
    private(set) var detectionError: CursorSharedAPIError?
    private(set) var lastCompleteSuccessAt: Date?
    @ObservationIgnored let provider: (any CursorSharedUsageFetching)?
    @ObservationIgnored private let now: @MainActor () -> Date
    @ObservationIgnored private var owner: SharedUsageOwner?
    @ObservationIgnored private var plan: CursorPlanInfoResponse?

    var suppressesLegacyMeter: Bool { mode != .disabled && mode != .legacy }
    var isStale: Bool {
        snapshot?.isStale == true || snapshot?.weeklyAvailability(at: now()) == .stale
    }

    init(provider: (any CursorSharedUsageFetching)? = nil, now: @escaping @MainActor () -> Date = Date.init) {
        self.provider = provider
        self.now = now
        if provider == nil { mode = .disabled }
    }

    func isBound(to owner: SharedUsageOwner) -> Bool { self.owner == owner }

    func recordFailure(_ error: Error) {
        snapshot = snapshot?.failing(Self.safeError(error))
    }

    func reset() {
        owner = nil
        plan = nil
        snapshot = nil
        detectionError = nil
        lastCompleteSuccessAt = nil
        mode = provider == nil ? .disabled : .checking
    }

    func acceptPlan(_ result: Result<CursorPlanInfoResponse, Error>, owner: SharedUsageOwner?,
                    personalScope: Bool?, previouslyShared: Bool = false) {
        guard provider != nil else { return }
        if self.owner != owner {
            reset()
            self.owner = owner
        }
        detectionError = nil
        if personalScope == false, (try? result.get().classification) != .legacy,
           mode == .sharedWeekly || previouslyShared {
            mode = .unsupported
            snapshot = nil
            lastCompleteSuccessAt = nil
            if case .failure(let error) = result { detectionError = Self.safeError(error) }
            return
        }
        switch result {
        case .failure(let error):
            detectionError = Self.safeError(error)
            snapshot = snapshot?.failing(Self.safeError(error))
            if mode != .sharedWeekly && mode != .unsupported && mode != .legacy { mode = .unavailable }
        case .success(let plan):
            self.plan = plan
            switch plan.classification {
            case .legacy:
                mode = .legacy
                snapshot = nil
                lastCompleteSuccessAt = nil
            case .unsupported:
                mode = .unsupported
                snapshot = nil
                lastCompleteSuccessAt = nil
            case .sharedWeekly:
                guard owner != nil else {
                    mode = .unavailable
                    snapshot = nil
                    return
                }
                guard let personalScope else {
                    mode = .unavailable
                    snapshot = nil
                    lastCompleteSuccessAt = nil
                    return
                }
                guard personalScope else {
                    mode = .unsupported
                    snapshot = nil
                    lastCompleteSuccessAt = nil
                    return
                }
                mode = .sharedWeekly
                if let old = snapshot, let period = old.weekly.value?.period,
                   plan.planInfo?.includedUsageResetsAt.map({ Date(timeIntervalSince1970: Double($0) / 1000) }) != period.end {
                    snapshot = .init(weekly: old.weekly.failed(.invalidResponse), credit: old.credit,
                        monthlyUsed: old.monthlyUsed, paidCap: old.paidCap, autoTopUp: old.autoTopUp)
                }
            }
        }
    }

    func refresh(cookieHeader: String, owner: SharedUsageOwner, isCurrent: @MainActor () -> Bool) async -> Bool {
        guard let provider, let plan, self.owner == owner, mode == .sharedWeekly,
              detectionError == nil, isCurrent(), !Task.isCancelled else { return false }
        return await withTaskGroup(of: Response.self) { group in
            group.addTask { .weekly(await Self.capture { try await provider.fetchCurrentPeriod(cookieHeader: cookieHeader) }) }
            group.addTask { .prepaid(await Self.capture { try await provider.fetchPrepaid(cookieHeader: cookieHeader) }) }
            group.addTask { .cap(await Self.capture { try await provider.fetchPaidCap(cookieHeader: cookieHeader) }) }
            for await response in group {
                guard self.owner == owner, isCurrent(), !Task.isCancelled else {
                    group.cancelAll()
                    continue
                }
                let old = snapshot ?? .empty
                let date = now()
                switch response {
                case .weekly(let result):
                    let weekly: SharedUsageReading<SharedWeeklyUsage>
                    switch result {
                    case .success(let response):
                        let value = plan.weeklyUsage(from: response)
                        weekly = old.weekly.received(value?.hasIncludedUsage(at: date) == nil ? nil : value, at: date)
                    case .failure(let error): weekly = old.weekly.failed(error)
                    }
                    snapshot = .init(weekly: weekly, credit: old.credit, monthlyUsed: old.monthlyUsed,
                                     paidCap: old.paidCap, autoTopUp: old.autoTopUp)
                case .prepaid(let result):
                    let credit: SharedUsageReading<PrepaidCreditUsage>
                    let monthly: SharedUsageReading<Decimal>
                    let autoTopUp: SharedUsageReading<CursorAutoTopUp>
                    switch result {
                    case .success(let response):
                        credit = old.credit.received(response.creditUsage.remainingCents == nil ? nil : response.creditUsage, at: date)
                        monthly = old.monthlyUsed.received(response.monthlyUsedCents, at: date)
                        autoTopUp = old.autoTopUp.received(response.autoTopUp, at: date)
                    case .failure(let error):
                        credit = old.credit.failed(error)
                        monthly = old.monthlyUsed.failed(error)
                        autoTopUp = old.autoTopUp.failed(error)
                    }
                    snapshot = .init(weekly: old.weekly, credit: credit, monthlyUsed: monthly,
                                     paidCap: old.paidCap, autoTopUp: autoTopUp)
                case .cap(let result):
                    let cap: SharedUsageReading<SharedPaidCap>
                    switch result {
                    case .success(let response): cap = old.paidCap.received(response.cap == .unknown ? nil : response.cap, at: date)
                    case .failure(let error): cap = old.paidCap.failed(error)
                    }
                    snapshot = .init(weekly: old.weekly, credit: old.credit, monthlyUsed: old.monthlyUsed,
                                     paidCap: cap, autoTopUp: old.autoTopUp)
                }
            }
            guard self.owner == owner, isCurrent(), !Task.isCancelled else { return false }
            let complete = snapshot?.isComplete == true
            if complete { lastCompleteSuccessAt = now() }
            return complete
        }
    }

    private enum Response: Sendable {
        case weekly(Result<CurrentPeriodUsageResponse, CursorSharedAPIError>)
        case prepaid(Result<CursorPrepaidBillingResponse, CursorSharedAPIError>)
        case cap(Result<CursorPaidCapResponse, CursorSharedAPIError>)
    }

    nonisolated private static func safeError(_ error: Error) -> CursorSharedAPIError {
        error as? CursorSharedAPIError ?? (error is CancellationError ? .cancelled : .transport)
    }

    nonisolated private static func capture<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, CursorSharedAPIError> {
        do { return .success(try await body()) }
        catch { return .failure(safeError(error)) }
    }
}
