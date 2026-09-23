import Foundation
import Observation

struct RefreshTiming: Sendable {
    let admissionInterval: Duration
    let minimumRotation: Duration
    let minimumResult: Duration

    static let standard = Self(admissionInterval: .seconds(3), minimumRotation: .milliseconds(1_300), minimumResult: .milliseconds(650))
    static let immediate = Self(admissionInterval: .zero, minimumRotation: .zero, minimumResult: .zero)

    private init(admissionInterval: Duration, minimumRotation: Duration, minimumResult: Duration) {
        self.admissionInterval = admissionInterval
        self.minimumRotation = minimumRotation
        self.minimumResult = minimumResult
    }
}

struct RefreshTimeline: Equatable, Sendable {
    let rotationEnd: ContinuousClock.Instant
    let readyAt: ContinuousClock.Instant

    init(start: ContinuousClock.Instant, completion: ContinuousClock.Instant, timing: RefreshTiming = .standard) {
        rotationEnd = max(start.advanced(by: timing.minimumRotation), completion)
        readyAt = max(start.advanced(by: timing.admissionInterval), rotationEnd.advanced(by: timing.minimumResult))
    }
}

enum RefreshOutcome: Equatable, Sendable {
    case success
    case failure
}

enum RefreshPhase: Equatable, Sendable {
    case idle
    case updating
    case result(meter: RefreshOutcome, recent: RefreshOutcome)
}

struct RefreshAttempt: Equatable, Sendable {
    let generation: UInt64
    let id: UInt64
    fileprivate let start: ContinuousClock.Instant
}

@MainActor @Observable
final class RefreshFeedback {
    private(set) var phase: RefreshPhase = .idle
    private(set) var isInFlight = false
    private(set) var currentAttempt: RefreshAttempt?
    private(set) var timeline: RefreshTimeline?

    @ObservationIgnored private let timing: RefreshTiming
    @ObservationIgnored private let now: @MainActor () -> ContinuousClock.Instant
    @ObservationIgnored private let sleepUntil: @MainActor (ContinuousClock.Instant) async throws -> Void
    @ObservationIgnored private var nextAttemptID: UInt64 = 0
    @ObservationIgnored private var feedbackTask: Task<Void, Never>?

    var isReady: Bool {
        guard !isInFlight else { return false }
        switch phase {
        case .idle:
            return true
        case .updating, .result:
            return timeline.map { now() >= $0.readyAt } ?? false
        }
    }

    init(
        timing: RefreshTiming = .standard,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleepUntil: @escaping @MainActor (ContinuousClock.Instant) async throws -> Void = {
            try await ContinuousClock().sleep(until: $0)
        }
    ) {
        self.timing = timing
        self.now = now
        self.sleepUntil = sleepUntil
    }

    deinit {
        feedbackTask?.cancel()
    }

    func begin(generation: UInt64) -> RefreshAttempt? {
        guard isReady else { return nil }
        feedbackTask?.cancel()
        feedbackTask = nil
        nextAttemptID += 1
        let attempt = RefreshAttempt(generation: generation, id: nextAttemptID, start: now())
        currentAttempt = attempt
        timeline = nil
        isInFlight = true
        phase = .updating
        return attempt
    }

    func complete(_ attempt: RefreshAttempt, meter: RefreshOutcome, recent: RefreshOutcome) {
        guard currentAttempt == attempt, isInFlight else { return }
        let completion = now()
        let timeline = RefreshTimeline(start: attempt.start, completion: completion, timing: timing)
        self.timeline = timeline
        isInFlight = false

        if completion >= timeline.readyAt {
            phase = .idle
            return
        }

        feedbackTask = Task { [weak self, sleepUntil] in
            do {
                try Task.checkCancellation()
                try await sleepUntil(timeline.rotationEnd)
                guard !Task.isCancelled, self?.currentAttempt == attempt else { return }
                self?.phase = .result(meter: meter, recent: recent)
                try await sleepUntil(timeline.readyAt)
                guard !Task.isCancelled, self?.currentAttempt == attempt else { return }
                self?.phase = .idle
                self?.feedbackTask = nil
            } catch {
                // Invalidating a session or replacing an elapsed attempt cancels its sleeper.
            }
        }
    }

    func invalidate() {
        feedbackTask?.cancel()
        feedbackTask = nil
        currentAttempt = nil
        timeline = nil
        isInFlight = false
        phase = .idle
    }
}
