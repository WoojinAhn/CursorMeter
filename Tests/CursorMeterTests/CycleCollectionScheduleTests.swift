import XCTest
@testable import CursorMeter

final class CycleCollectionScheduleTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testCompleteNeedsTenMinutesAndChangedFingerprint() {
        var schedule = CycleCollectionSchedule()
        schedule.observe(fingerprint: "a")
        XCTAssertNotNil(schedule.begin(at: start, manual: false))
        schedule.finish(.complete, pages: 4, at: start)
        XCTAssertNil(schedule.begin(at: start.addingTimeInterval(600), manual: false))
        schedule.observe(fingerprint: "b")
        XCTAssertNil(schedule.begin(at: start.addingTimeInterval(599), manual: false))
        XCTAssertNotNil(schedule.begin(at: start.addingTimeInterval(600), manual: false))
    }

    func testBudgetPartialRemainsTerminalUntilCycleChangeButManualCanRetry() {
        var schedule = CycleCollectionSchedule()
        schedule.observe(fingerprint: "a")
        XCTAssertNotNil(schedule.begin(at: start, manual: false))
        schedule.finish(.budgetPartial, pages: 100, at: start)
        schedule.observe(fingerprint: "b")
        XCTAssertNil(schedule.begin(at: start.addingTimeInterval(3600), manual: false))
        XCTAssertNotNil(schedule.begin(at: start.addingTimeInterval(3600), manual: true))
        schedule.finish(.budgetPartial, pages: 100, at: start.addingTimeInterval(3600))
        schedule.resetCycle()
        XCTAssertNotNil(schedule.begin(at: start.addingTimeInterval(3601), manual: false))
    }

    func testUnstableEarlyRetryNeedsTwoEqualPrimaryObservationsAndOneMinute() {
        var schedule = CycleCollectionSchedule()
        schedule.observe(fingerprint: "a")
        _ = schedule.begin(at: start, manual: false)
        schedule.finish(.unstable, pages: 6, at: start)
        schedule.observe(fingerprint: "b")
        XCTAssertNil(schedule.begin(at: start.addingTimeInterval(60), manual: false))
        schedule.observe(fingerprint: "b")
        XCTAssertNil(schedule.begin(at: start.addingTimeInterval(59), manual: false))
        XCTAssertNotNil(schedule.begin(at: start.addingTimeInterval(60), manual: false))
    }

    func testUnstableBackoffEscalatesWithoutStableObservations() {
        var schedule = CycleCollectionSchedule()
        var time = start
        for delay in [300.0, 600, 1200, 3600, 3600] {
            schedule.observe(fingerprint: UUID().uuidString)
            XCTAssertNotNil(schedule.begin(at: time, manual: false))
            schedule.finish(.unstable, pages: 1, at: time)
            XCTAssertEqual(schedule.availability(at: time, manual: false), .waiting(until: time.addingTimeInterval(delay)))
            time = time.addingTimeInterval(delay)
        }
    }

    func testTransportBackoffCapsAtThirtyMinutesAndManualCooldownIsSeparate() {
        var schedule = CycleCollectionSchedule()
        schedule.observe(fingerprint: "a")
        var time = start
        for delay in [60.0, 120, 240, 480, 960, 1800, 1800] {
            XCTAssertNotNil(schedule.begin(at: time, manual: false))
            schedule.finish(.transportFailure, pages: 0, at: time)
            XCTAssertEqual(schedule.availability(at: time, manual: false), .waiting(until: time.addingTimeInterval(delay)))
            XCTAssertEqual(schedule.availability(at: time.addingTimeInterval(60), manual: true), .ready)
            time = time.addingTimeInterval(delay)
        }
    }

    func testRateLimitSurvivesCycleChangeAndCannotBeBypassedManually() {
        var schedule = CycleCollectionSchedule()
        schedule.observe(fingerprint: "a")
        _ = schedule.begin(at: start, manual: false)
        schedule.finish(.rateLimited(retryAfter: 900), pages: 1, at: start)
        schedule.resetCycle()
        schedule.observe(fingerprint: "new-cycle")
        XCTAssertNil(schedule.begin(at: start.addingTimeInterval(899), manual: true))
        XCTAssertNil(schedule.begin(at: start.addingTimeInterval(899), manual: false))
        XCTAssertNotNil(schedule.begin(at: start.addingTimeInterval(900), manual: true))
    }

    func testInvalidRetryAfterUsesThirtyMinutesAndShortValueUsesOneMinute() {
        for (value, delay) in [(Double.nan, 1800.0), (-1.0, 1800.0), (0.0, 60.0), (20.0, 60.0)] {
            var schedule = CycleCollectionSchedule()
            schedule.observe(fingerprint: "a")
            _ = schedule.begin(at: start, manual: false)
            schedule.finish(.rateLimited(retryAfter: value), pages: 0, at: start)
            XCTAssertEqual(schedule.availability(at: start, manual: true), .waiting(until: start.addingTimeInterval(delay)))
        }
    }

    func testChangingTwelveThousandEventCycleMakesOneAutomaticAttemptInHour() {
        var schedule = CycleCollectionSchedule()
        var attempts = 0
        for minute in 0..<60 {
            let now = start.addingTimeInterval(Double(minute * 60))
            schedule.observe(fingerprint: "cost-\(minute)")
            if schedule.begin(at: now, manual: false) != nil {
                attempts += 1
                schedule.finish(.budgetPartial, pages: 100, at: now)
            }
        }
        XCTAssertEqual(attempts, 1)
    }

    func testChangingSourceNeverExceedsRollingThreeHundredAutomaticPages() {
        var schedule = CycleCollectionSchedule()
        var pageCount = 0
        for minute in 0..<60 {
            let now = start.addingTimeInterval(Double(minute * 60))
            schedule.observe(fingerprint: "cost-\(minute)")
            if let allowance = schedule.begin(at: now, manual: false) {
                pageCount += allowance
                schedule.finish(.unstable, pages: allowance, at: now)
            }
        }
        XCTAssertEqual(pageCount, 300)
        XCTAssertNotNil(schedule.begin(at: start.addingTimeInterval(3600), manual: false))
    }

    func testInFlightCoalescingAndManualDoesNotSpendAutomaticAllowance() {
        var schedule = CycleCollectionSchedule()
        schedule.observe(fingerprint: "a")
        XCTAssertEqual(schedule.begin(at: start, manual: true), 100)
        XCTAssertEqual(schedule.availability(at: start, manual: false), .collecting)
        XCTAssertNil(schedule.begin(at: start, manual: true))
        schedule.finish(.endpointFailure, pages: 100, at: start)
        XCTAssertEqual(schedule.automaticPagesRemaining(at: start), 300)
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(59), manual: true), .waiting(until: start.addingTimeInterval(60)))
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(60), manual: true), .ready)
    }
    func testRetiredAttemptReservesUntilActualCostArrivesAndDoesNotChargeAllowance() throws {
        var schedule = CycleCollectionSchedule()
        schedule.observe(fingerprint: "a")
        _ = schedule.begin(at: start, manual: false)
        let id = try XCTUnwrap(schedule.currentAttemptID)
        schedule.retireCurrent(at: start)
        XCTAssertEqual(schedule.automaticPagesRemaining(at: start), 200, "Outstanding work reserves its maximum until cancellation finishes")
        schedule.finish(.cancelled, pages: 2, at: start, attemptID: id)
        XCTAssertEqual(schedule.automaticPagesRemaining(at: start), 298, "Only two attempted pages are charged")
        XCTAssertNotNil(schedule.begin(at: start.addingTimeInterval(60), manual: false))
    }

    func testLateRetiredCompletionCannotFinishNewAttemptOrReplaceItsOutcome() throws {
        var schedule = CycleCollectionSchedule()
        schedule.observe(fingerprint: "a")
        _ = schedule.begin(at: start, manual: false)
        let oldID = try XCTUnwrap(schedule.currentAttemptID)
        schedule.retireCurrent(at: start)
        schedule.resetCycle()
        schedule.observe(fingerprint: "b")
        _ = schedule.begin(at: start, manual: false)
        let currentID = try XCTUnwrap(schedule.currentAttemptID)
        schedule.finish(.budgetPartial, pages: 2, at: start, attemptID: oldID)
        XCTAssertEqual(schedule.availability(at: start, manual: false), .collecting)
        schedule.finish(.complete, pages: 4, at: start, attemptID: currentID)
        XCTAssertEqual(schedule.automaticPagesRemaining(at: start), 294)
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(600), manual: false), .unchanged)
    }

    func testThreeZeroPageCancellationsDoNotExhaustHourlyBudget() throws {
        var schedule = CycleCollectionSchedule()
        for index in 0..<3 {
            let now = start.addingTimeInterval(Double(index * 60))
            _ = schedule.begin(at: now, manual: false)
            let id = try XCTUnwrap(schedule.currentAttemptID)
            schedule.retireCurrent(at: now)
            schedule.finish(.cancelled, pages: 0, at: now, attemptID: id)
        }
        XCTAssertEqual(schedule.automaticPagesRemaining(at: start.addingTimeInterval(180)), 300)
        XCTAssertNotNil(schedule.begin(at: start.addingTimeInterval(180), manual: false))
    }

    func testHourlyAllowanceWaitsForFullAttemptInsteadOfCreatingTerminalPartial() {
        var schedule = CycleCollectionSchedule()
        for index in 0..<4 {
            let time = start.addingTimeInterval(Double(index * 600))
            schedule.observe(fingerprint: "revision-\(index)")
            XCTAssertEqual(schedule.begin(at: time, manual: false), 100)
            schedule.finish(.complete, pages: 52, at: time)
        }
        schedule.observe(fingerprint: "revision-5")
        XCTAssertEqual(schedule.automaticPagesRemaining(at: start.addingTimeInterval(3000)), 92)
        XCTAssertNil(schedule.begin(at: start.addingTimeInterval(3000), manual: false))
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(3000), manual: false),
                       .waiting(until: start.addingTimeInterval(3600)))
        XCTAssertEqual(schedule.begin(at: start.addingTimeInterval(3600), manual: false), 100)
    }

    func testMissingFieldFillCanUsePeriodAfterHistoryBudgetButNotDuringBackoff() {
        var schedule = CycleCollectionSchedule()
        _ = schedule.begin(at: start, manual: false)
        XCTAssertFalse(schedule.canFetchSupplement(at: start))
        schedule.finish(.budgetPartial, pages: 100, at: start)
        XCTAssertTrue(schedule.canFetchSupplement(at: start.addingTimeInterval(60)))
        _ = schedule.begin(at: start.addingTimeInterval(60), manual: true)
        schedule.finish(.transportFailure, pages: 0, at: start.addingTimeInterval(60))
        XCTAssertFalse(schedule.canFetchSupplement(at: start.addingTimeInterval(119)))
        XCTAssertTrue(schedule.canFetchSupplement(at: start.addingTimeInterval(120)))
    }

    func testPeriodRateLimitAlsoBlocksMonthlyAndManualWorkAcrossCycleChange() {
        var schedule = CycleCollectionSchedule()
        schedule.recordSupplementRateLimit(900, at: start)
        schedule.resetCycle()
        XCTAssertFalse(schedule.canFetchSupplement(at: start.addingTimeInterval(899)))
        XCTAssertNil(schedule.begin(at: start.addingTimeInterval(899), manual: true))
        XCTAssertNil(schedule.begin(at: start.addingTimeInterval(899), manual: false))
        XCTAssertTrue(schedule.canFetchSupplement(at: start.addingTimeInterval(900)))
        XCTAssertEqual(schedule.begin(at: start.addingTimeInterval(900), manual: false), 100)
    }

}
