import Observation
import XCTest
@testable import CursorMeter

@MainActor
private final class RefreshTestClock {
    var now = ContinuousClock.now
    private(set) var returnedSleeps = 0
    private var sleepers: [(ContinuousClock.Instant, CheckedContinuation<Void, Never>)] = []

    var deadlines: [ContinuousClock.Instant] { sleepers.map(\.0) }

    // Deliberately ignores cancellation so tests can deliver retired timer callbacks.
    func sleep(until deadline: ContinuousClock.Instant) async {
        if deadline > now {
            await withCheckedContinuation { sleepers.append((deadline, $0)) }
        }
        returnedSleeps += 1
    }

    func advance(to instant: ContinuousClock.Instant) {
        now = instant
        let due = sleepers.filter { $0.0 <= now }
        sleepers.removeAll { $0.0 <= now }
        due.forEach { $0.1.resume() }
    }

    func resumeAll() {
        let pending = sleepers
        sleepers.removeAll()
        pending.forEach { $0.1.resume() }
    }
}

@MainActor
final class RefreshFeedbackTests: XCTestCase {
    private func feedback(clock: RefreshTestClock, timing: RefreshTiming = .standard) -> RefreshFeedback {
        RefreshFeedback(timing: timing, now: { clock.now }, sleepUntil: { await clock.sleep(until: $0) })
    }

    private func eventually(
        file: StaticString = #filePath, line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition(), "Expected state was not reached", file: file, line: line)
    }

    func testStandardTimingIsFixed() {
        XCTAssertEqual(RefreshTiming.standard.admissionInterval, .seconds(3))
        XCTAssertEqual(RefreshTiming.standard.minimumRotation, .milliseconds(1_300))
        XCTAssertEqual(RefreshTiming.standard.minimumResult, .milliseconds(650))
    }

    func testFastCompletionKeepsRotationAndAdmissionDeadlines() {
        let start = ContinuousClock.now
        let timeline = RefreshTimeline(start: start, completion: start.advanced(by: .milliseconds(200)))
        XCTAssertEqual(timeline.rotationEnd, start.advanced(by: .milliseconds(1_300)))
        XCTAssertEqual(timeline.readyAt, start.advanced(by: .seconds(3)))
    }

    func testSlowCompletionKeepsResultVisibleForMinimumDuration() {
        let start = ContinuousClock.now
        let timeline = RefreshTimeline(start: start, completion: start.advanced(by: .milliseconds(4_200)))
        XCTAssertEqual(timeline.rotationEnd, start.advanced(by: .milliseconds(4_200)))
        XCTAssertEqual(timeline.readyAt, start.advanced(by: .milliseconds(4_850)))
    }

    func testCompletionNearAdmissionDeadlineExtendsResultVisibility() {
        let start = ContinuousClock.now
        let timeline = RefreshTimeline(start: start, completion: start.advanced(by: .milliseconds(2_600)))
        XCTAssertEqual(timeline.rotationEnd, start.advanced(by: .milliseconds(2_600)))
        XCTAssertEqual(timeline.readyAt, start.advanced(by: .milliseconds(3_250)))
    }

    func testCompletionAtRotationBoundaryDoesNotAddAnotherRotation() {
        let start = ContinuousClock.now
        let timeline = RefreshTimeline(start: start, completion: start.advanced(by: .milliseconds(1_300)))
        XCTAssertEqual(timeline.rotationEnd, start.advanced(by: .milliseconds(1_300)))
        XCTAssertEqual(timeline.readyAt, start.advanced(by: .seconds(3)))
    }

    func testImmediateTimingAddsNoVisualOrAdmissionDelay() {
        let start = ContinuousClock.now
        let completion = start.advanced(by: .milliseconds(200))
        let timeline = RefreshTimeline(start: start, completion: completion, timing: .immediate)
        XCTAssertEqual(RefreshTiming.immediate.admissionInterval, .zero)
        XCTAssertEqual(RefreshTiming.immediate.minimumRotation, .zero)
        XCTAssertEqual(RefreshTiming.immediate.minimumResult, .zero)
        XCTAssertEqual(timeline.rotationEnd, completion)
        XCTAssertEqual(timeline.readyAt, completion)
    }

    func testActualWorkBlocksNewAttemptsEvenAfterAdmissionInterval() throws {
        let clock = RefreshTestClock()
        let feedback = feedback(clock: clock)
        let attempt = try XCTUnwrap(feedback.begin(generation: 7))
        XCTAssertEqual(attempt.generation, 7)
        XCTAssertEqual(feedback.phase, .updating)
        XCTAssertTrue(feedback.isInFlight)
        XCTAssertFalse(feedback.isReady)
        clock.advance(to: clock.now.advanced(by: .seconds(10)))
        XCTAssertNil(feedback.begin(generation: 7))
        XCTAssertEqual(feedback.currentAttempt, attempt)
        XCTAssertTrue(feedback.isInFlight)
        XCTAssertFalse(feedback.isReady)
    }

    func testFastSuccessShowsResultAtRotationEdgeAndBecomesReadyAtThreeSeconds() async throws {
        let clock = RefreshTestClock()
        let start = clock.now
        let feedback = feedback(clock: clock)
        defer { feedback.invalidate(); clock.resumeAll() }
        let attempt = try XCTUnwrap(feedback.begin(generation: 1))
        clock.advance(to: start.advanced(by: .milliseconds(200)))
        feedback.complete(attempt, meter: .success, recent: .success)
        XCTAssertFalse(feedback.isInFlight, "Visual feedback must not extend actual work")
        XCTAssertEqual(feedback.phase, .updating)
        await eventually { clock.deadlines.contains(start.advanced(by: .milliseconds(1_300))) }
        clock.advance(to: start.advanced(by: .milliseconds(1_299)))
        XCTAssertEqual(feedback.phase, .updating)
        XCTAssertNil(feedback.begin(generation: 1))
        clock.advance(to: start.advanced(by: .milliseconds(1_300)))
        await eventually { feedback.phase == .result(meter: .success, recent: .success) }
        await eventually { clock.deadlines.contains(start.advanced(by: .seconds(3))) }
        clock.advance(to: start.advanced(by: .milliseconds(2_999)))
        XCTAssertFalse(feedback.isReady)
        XCTAssertNil(feedback.begin(generation: 1))
        clock.advance(to: start.advanced(by: .seconds(3)))
        await eventually { feedback.phase == .idle }
        XCTAssertTrue(feedback.isReady)
        XCTAssertNotNil(feedback.begin(generation: 1))
    }

    func testSlowFailureShowsResultFor650MillisecondsAfterWorkFinishes() async throws {
        let clock = RefreshTestClock()
        let start = clock.now
        let feedback = feedback(clock: clock)
        defer { feedback.invalidate(); clock.resumeAll() }
        let attempt = try XCTUnwrap(feedback.begin(generation: 1))
        clock.advance(to: start.advanced(by: .milliseconds(4_200)))
        XCTAssertFalse(feedback.isReady)
        feedback.complete(attempt, meter: .failure, recent: .failure)
        await eventually { feedback.phase == .result(meter: .failure, recent: .failure) }
        await eventually { clock.deadlines.contains(start.advanced(by: .milliseconds(4_850))) }
        clock.advance(to: start.advanced(by: .milliseconds(4_849)))
        XCTAssertNil(feedback.begin(generation: 1))
        XCTAssertFalse(feedback.isInFlight)
        clock.advance(to: start.advanced(by: .milliseconds(4_850)))
        XCTAssertTrue(feedback.isReady)
        XCTAssertNotNil(feedback.begin(generation: 1))
    }

    func testMeterAndRecentOutcomesStayIndependent() async throws {
        for (meter, recent): (RefreshOutcome, RefreshOutcome) in [(.success, .failure), (.failure, .success)] {
            let clock = RefreshTestClock()
            let feedback = feedback(clock: clock)
            defer { feedback.invalidate(); clock.resumeAll() }
            let attempt = try XCTUnwrap(feedback.begin(generation: 1))
            clock.advance(to: clock.now.advanced(by: .seconds(2)))
            feedback.complete(attempt, meter: meter, recent: recent)
            await eventually { feedback.phase == .result(meter: meter, recent: recent) }
            XCTAssertFalse(feedback.isReady)
        }
    }

    func testFastFailureAndSlowSuccessUseTheSameTimingPolicy() async throws {
        let cases: [(completion: Duration, outcome: RefreshOutcome, rotation: Duration, ready: Duration)] = [
            (.milliseconds(200), .failure, .milliseconds(1_300), .seconds(3)),
            (.milliseconds(4_200), .success, .milliseconds(4_200), .milliseconds(4_850)),
        ]
        for test in cases {
            let clock = RefreshTestClock()
            let start = clock.now
            let feedback = feedback(clock: clock)
            defer { feedback.invalidate(); clock.resumeAll() }
            let attempt = try XCTUnwrap(feedback.begin(generation: 1))
            clock.advance(to: start.advanced(by: test.completion))
            feedback.complete(attempt, meter: test.outcome, recent: test.outcome)
            XCTAssertFalse(feedback.isInFlight)
            clock.advance(to: start.advanced(by: test.rotation))
            await eventually { feedback.phase == .result(meter: test.outcome, recent: test.outcome) }
            XCTAssertFalse(feedback.isReady)
            await eventually { clock.deadlines.contains(start.advanced(by: test.ready)) }
            clock.advance(to: start.advanced(by: test.ready))
            await eventually { feedback.phase == .idle }
            XCTAssertTrue(feedback.isReady)
        }
    }

    func testManualAndAutomaticOverlapDoesNotQueueAnotherAttempt() async throws {
        let clock = RefreshTestClock()
        let start = clock.now
        let feedback = feedback(clock: clock)
        defer { feedback.invalidate(); clock.resumeAll() }
        let automatic = try XCTUnwrap(feedback.begin(generation: 1))
        XCTAssertNil(feedback.begin(generation: 1), "Manual entry shares the active-work guard")
        feedback.complete(automatic, meter: .success, recent: .success)
        XCTAssertNil(feedback.begin(generation: 1), "Automatic entry shares the visual guard")
        clock.advance(to: start.advanced(by: .seconds(10)))
        await eventually { feedback.phase == .idle }
        XCTAssertFalse(feedback.isInFlight)
        XCTAssertEqual(feedback.currentAttempt, automatic, "Rejected calls must not schedule future work")
        let manual = try XCTUnwrap(feedback.begin(generation: 1))
        XCTAssertGreaterThan(manual.id, automatic.id)
    }

    func testExactReadyDeadlineAdmitsWithoutWaitingForSleeperScheduling() async throws {
        let clock = RefreshTestClock()
        let start = clock.now
        let feedback = feedback(clock: clock)
        defer { feedback.invalidate(); clock.resumeAll() }
        let first = try XCTUnwrap(feedback.begin(generation: 1))
        feedback.complete(first, meter: .success, recent: .success)
        await eventually { !clock.deadlines.isEmpty }
        clock.now = start.advanced(by: .seconds(3))
        XCTAssertTrue(feedback.isReady)
        let second = try XCTUnwrap(feedback.begin(generation: 1))
        XCTAssertNotEqual(second, first)
        XCTAssertEqual(feedback.phase, .updating)
        clock.resumeAll()
        await eventually { clock.returnedSleeps == 1 }
        XCTAssertEqual(feedback.currentAttempt, second)
        XCTAssertTrue(feedback.isInFlight)
    }

    func testInvalidateAllowsNewSessionAndRejectsOldCompletion() throws {
        let clock = RefreshTestClock()
        let feedback = feedback(clock: clock)
        let old = try XCTUnwrap(feedback.begin(generation: 1))
        feedback.invalidate()
        XCTAssertEqual(feedback.phase, .idle)
        XCTAssertTrue(feedback.isReady)
        XCTAssertFalse(feedback.isInFlight)
        XCTAssertNil(feedback.currentAttempt)
        XCTAssertNil(feedback.timeline)
        let current = try XCTUnwrap(feedback.begin(generation: 2))
        XCTAssertGreaterThan(current.id, old.id)
        feedback.complete(old, meter: .failure, recent: .failure)
        XCTAssertEqual(feedback.currentAttempt, current)
        XCTAssertEqual(feedback.phase, .updating)
        XCTAssertTrue(feedback.isInFlight)
        XCTAssertNil(feedback.timeline)
    }

    func testRetiredRotationSleeperCannotPublishIntoNewSession() async throws {
        let clock = RefreshTestClock()
        let start = clock.now
        let feedback = feedback(clock: clock)
        defer { feedback.invalidate(); clock.resumeAll() }
        let old = try XCTUnwrap(feedback.begin(generation: 1))
        feedback.complete(old, meter: .failure, recent: .failure)
        await eventually { clock.deadlines.contains(start.advanced(by: .milliseconds(1_300))) }
        feedback.invalidate()
        let current = try XCTUnwrap(feedback.begin(generation: 2))
        clock.advance(to: start.advanced(by: .seconds(3)))
        await eventually { clock.returnedSleeps == 1 }
        XCTAssertEqual(feedback.phase, .updating)
        XCTAssertEqual(feedback.currentAttempt, current)
        XCTAssertTrue(feedback.isInFlight)
        XCTAssertNil(feedback.timeline)
    }

    func testRetiredResultSleeperCannotMakeNewSessionReady() async throws {
        let clock = RefreshTestClock()
        let start = clock.now
        let feedback = feedback(clock: clock)
        defer { feedback.invalidate(); clock.resumeAll() }
        let old = try XCTUnwrap(feedback.begin(generation: 1))
        clock.advance(to: start.advanced(by: .seconds(2)))
        feedback.complete(old, meter: .success, recent: .success)
        await eventually { clock.deadlines.contains(start.advanced(by: .seconds(3))) }
        feedback.invalidate()
        let current = try XCTUnwrap(feedback.begin(generation: 2))
        clock.advance(to: start.advanced(by: .seconds(3)))
        await eventually { clock.returnedSleeps == 2 }
        XCTAssertEqual(feedback.phase, .updating)
        XCTAssertEqual(feedback.currentAttempt, current)
        XCTAssertFalse(feedback.isReady)
    }

    func testRepeatedCompletionCannotRewriteResultOrDeadline() async throws {
        let clock = RefreshTestClock()
        let start = clock.now
        let feedback = feedback(clock: clock)
        defer { feedback.invalidate(); clock.resumeAll() }
        let attempt = try XCTUnwrap(feedback.begin(generation: 1))
        clock.advance(to: start.advanced(by: .milliseconds(200)))
        feedback.complete(attempt, meter: .success, recent: .failure)
        let timeline = feedback.timeline
        clock.advance(to: start.advanced(by: .seconds(2)))
        feedback.complete(attempt, meter: .failure, recent: .success)
        await eventually { feedback.phase == .result(meter: .success, recent: .failure) }
        XCTAssertEqual(feedback.timeline, timeline)
        feedback.complete(attempt, meter: .failure, recent: .failure)
        XCTAssertEqual(feedback.phase, .result(meter: .success, recent: .failure))
        XCTAssertEqual(feedback.timeline, timeline)
    }

    func testNewViewReadsSharedStateDuringResultPhase() async throws {
        let clock = RefreshTestClock()
        let start = clock.now
        let feedback = feedback(clock: clock)
        defer { feedback.invalidate(); clock.resumeAll() }
        let attempt = try XCTUnwrap(feedback.begin(generation: 1))
        feedback.complete(attempt, meter: .success, recent: .failure)
        clock.advance(to: start.advanced(by: .seconds(2)))
        await eventually { feedback.phase == .result(meter: .success, recent: .failure) }
        let lateViewState = feedback
        XCTAssertEqual(lateViewState.phase, .result(meter: .success, recent: .failure))
        XCTAssertFalse(lateViewState.isReady)
        XCTAssertFalse(lateViewState.isInFlight)
        XCTAssertEqual(lateViewState.timeline?.readyAt, start.advanced(by: .seconds(3)))
        let changed = expectation(description: "Readiness invalidates a late observer")
        withObservationTracking {
            _ = lateViewState.isReady
        } onChange: {
            changed.fulfill()
        }
        await eventually { clock.deadlines.contains(start.advanced(by: .seconds(3))) }
        clock.advance(to: start.advanced(by: .seconds(3)))
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertTrue(lateViewState.isReady)
    }

    func testImmediateFeedbackCompletesSynchronouslyWithoutStartingSleeper() throws {
        let clock = RefreshTestClock()
        let feedback = feedback(clock: clock, timing: .immediate)
        let first = try XCTUnwrap(feedback.begin(generation: 4))
        XCTAssertFalse(feedback.isReady)
        feedback.complete(first, meter: .success, recent: .failure)
        XCTAssertEqual(feedback.phase, .idle)
        XCTAssertFalse(feedback.isInFlight)
        XCTAssertTrue(feedback.isReady)
        XCTAssertTrue(clock.deadlines.isEmpty)
        let second = try XCTUnwrap(feedback.begin(generation: 4))
        XCTAssertEqual(second.generation, first.generation)
        XCTAssertGreaterThan(second.id, first.id)
        feedback.complete(first, meter: .failure, recent: .failure)
        XCTAssertTrue(feedback.isInFlight)
        XCTAssertEqual(feedback.currentAttempt, second)
        feedback.complete(second, meter: .failure, recent: .success)
        XCTAssertEqual(feedback.phase, .idle)
        XCTAssertTrue(feedback.isReady)
    }
}
