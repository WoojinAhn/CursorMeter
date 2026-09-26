import Foundation

/// Admission for independent amount enrichment; primary polling never waits here.
struct CycleCollectionSchedule: Sendable {
    enum Outcome: Sendable {
        case complete, budgetPartial, unstable, transportFailure, endpointFailure, cancelled
        case rateLimited(retryAfter: TimeInterval)
    }
    enum Availability: Equatable, Sendable {
        case ready, collecting, unchanged, cycleLimit
        case waiting(until: Date)
    }
    private struct Attempt: Sendable {
        let id: UInt64
        let manual: Bool
        let fingerprint: String?
        let pageAllowance: Int
    }
    private struct PageCharge: Sendable {
        let date: Date
        let count: Int
    }

    private var fingerprint: String?
    private var stableObservations = 0
    private var active: Attempt?
    private var retired: [UInt64: Attempt] = [:]
    private var serial: UInt64 = 0
    var currentAttemptID: UInt64? { active?.id }
    private var lastFingerprint: String?
    private var lastFinishedAt: Date?
    private var lastOutcome: Outcome?
    private var reachedCycleBudget = false
    private var nextAutomaticAt: Date?
    private var serverRetryAt: Date?
    private var unstableFailures = 0
    private var transportFailures = 0
    private var pageCharges: [PageCharge] = []

    mutating func observe(fingerprint value: String) {
        stableObservations = value == fingerprint ? min(2, stableObservations + 1) : 1
        fingerprint = value
    }

    func automaticPagesRemaining(at now: Date) -> Int {
        let used = pageCharges.filter { now.timeIntervalSince($0.date) < 3600 }.reduce(0) { $0 + $1.count }
        let reserved = retired.values.filter { !$0.manual }.reduce(0) { $0 + $1.pageAllowance }
        return max(0, 300 - used - reserved)
    }

    func availability(at now: Date, manual: Bool) -> Availability {
        guard active == nil else { return .collecting }
        if let serverRetryAt, now < serverRetryAt { return .waiting(until: serverRetryAt) }
        if manual {
            if let lastFinishedAt, now < lastFinishedAt.addingTimeInterval(60) {
                return .waiting(until: lastFinishedAt.addingTimeInterval(60))
            }
            return .ready
        }
        if reachedCycleBudget { return .cycleLimit }
        if automaticPagesRemaining(at: now) < 100 {
            var available = automaticPagesRemaining(at: now)
            for charge in pageCharges where now.timeIntervalSince(charge.date) < 3600 {
                available += charge.count
                if available >= 100 { return .waiting(until: charge.date.addingTimeInterval(3600)) }
            }
            return .collecting
        }
        if case .complete = lastOutcome, fingerprint == lastFingerprint { return .unchanged }
        if let nextAutomaticAt, now < nextAutomaticAt {
            if case .unstable = lastOutcome, stableObservations >= 2,
               let lastFinishedAt, now >= lastFinishedAt.addingTimeInterval(60) {
                return .ready
            }
            return .waiting(until: nextAutomaticAt)
        }
        return .ready
    }

    /// Returns a page budget for this attempt, or nil when callers should coalesce/wait.
    mutating func begin(at now: Date, manual: Bool) -> Int? {
        guard availability(at: now, manual: manual) == .ready else { return nil }
        pageCharges.removeAll { now.timeIntervalSince($0.date) >= 3600 }
        // A reduced hourly allowance must not become a terminal cycle budget failure.
        let allowance = 100
        serial &+= 1
        active = Attempt(id: serial, manual: manual, fingerprint: fingerprint, pageAllowance: allowance)
        return allowance
    }

    mutating func finish(_ outcome: Outcome, pages: Int, at now: Date, attemptID: UInt64? = nil) {
        let id = attemptID ?? active?.id
        if let id, let attempt = retired.removeValue(forKey: id) {
            charge(attempt, pages: pages, at: now)
            if case let .rateLimited(retryAfter) = outcome { deferForServer(retryAfter, at: now) }
            return
        }
        guard let attempt = active, attempt.id == id else { return }
        active = nil
        charge(attempt, pages: pages, at: now)
        lastFingerprint = attempt.fingerprint
        lastFinishedAt = now
        lastOutcome = outcome
        stableObservations = 0
        switch outcome {
        case .complete:
            reachedCycleBudget = false
            unstableFailures = 0; transportFailures = 0
            nextAutomaticAt = now.addingTimeInterval(600)
        case .budgetPartial:
            reachedCycleBudget = true
            unstableFailures = 0; transportFailures = 0
            nextAutomaticAt = nil
        case .unstable:
            unstableFailures = min(4, unstableFailures + 1)
            transportFailures = 0
            nextAutomaticAt = now.addingTimeInterval([300.0, 600, 1200, 3600][unstableFailures - 1])
        case .transportFailure:
            transportFailures = min(6, transportFailures + 1)
            unstableFailures = 0
            nextAutomaticAt = now.addingTimeInterval(min(1800, 60 * pow(2, Double(transportFailures - 1))))
        case .endpointFailure:
            unstableFailures = 0; transportFailures = 0
            nextAutomaticAt = now.addingTimeInterval(1800)
        case let .rateLimited(retryAfter):
            deferForServer(retryAfter, at: now)
            nextAutomaticAt = serverRetryAt
        case .cancelled:
            nextAutomaticAt = now.addingTimeInterval(60)
        }
    }

    /// Cancelled work retains a reservation until its collector returns actual cost.
    mutating func retireCurrent(at now: Date) {
        guard let attempt = active else { return }
        retired[attempt.id] = attempt
        active = nil
        lastFinishedAt = now
        lastOutcome = .cancelled
        nextAutomaticAt = now.addingTimeInterval(60)
    }

    private mutating func charge(_ attempt: Attempt, pages: Int, at now: Date) {
        if !attempt.manual, pages > 0 {
            // Completion time conservatively retains each attempted page for an hour.
            pageCharges.append(PageCharge(date: now, count: min(attempt.pageAllowance, pages)))
        }
    }

    private mutating func deferForServer(_ retryAfter: TimeInterval, at now: Date) {
        let delay = retryAfter.isFinite && retryAfter >= 0 ? max(60, retryAfter) : 1800
        let deadline = now.addingTimeInterval(delay)
        serverRetryAt = max(serverRetryAt ?? deadline, deadline)
    }

    func canFetchSupplement(at now: Date) -> Bool {
        guard active == nil, serverRetryAt.map({ now >= $0 }) ?? true else { return false }
        switch lastOutcome {
        case .transportFailure, .endpointFailure, .unstable, .cancelled, .rateLimited:
            return nextAutomaticAt.map { now >= $0 } ?? true
        default: return true
        }
    }

    mutating func recordSupplementRateLimit(_ retryAfter: TimeInterval, at now: Date) {
        deferForServer(retryAfter, at: now)
    }

    /// The owner must cancel and retire the old task before resetting its cycle.
    /// Session page charges and a server's Retry-After survive a billing transition.
    mutating func resetCycle() {
        if let attempt = active { retired[attempt.id] = attempt }
        active = nil
        fingerprint = nil; lastFingerprint = nil
        lastFinishedAt = nil; lastOutcome = nil; nextAutomaticAt = nil
        reachedCycleBudget = false
        stableObservations = 0; unstableFailures = 0; transportFailures = 0
    }
}
