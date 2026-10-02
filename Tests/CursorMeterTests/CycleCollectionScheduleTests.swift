import XCTest
@testable import CursorMeter

final class CycleCollectionScheduleTests: XCTestCase {
    func testTodayDemandUsesCompletionPacingAndSeparateUnchangedIdentity() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var schedule = CycleCollectionSchedule()
        schedule.observe(fingerprint: "raw")
        XCTAssertEqual(schedule.begin(at: start, manual: false, todayDemand: "first"), 100)
        schedule.finish(.complete, pages: 4, at: start.addingTimeInterval(45))
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(59), manual: false, todayDemand: "second"),
                       .waiting(until: start.addingTimeInterval(117)))
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(60), manual: false, todayDemand: "first"), .unchanged)
        XCTAssertEqual(schedule.begin(at: start.addingTimeInterval(117), manual: false, todayDemand: "second"), 100)
        schedule.finish(.complete, pages: 4, at: start.addingTimeInterval(118))
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(177), manual: true),
                       .waiting(until: start.addingTimeInterval(178)))
    }

    func testTodayRevisionCannotBypassFailureGateAndRawSummaryControlsStability() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var schedule = CycleCollectionSchedule()
        schedule.observe(fingerprint: "raw")
        _ = schedule.begin(at: start, manual: false, todayDemand: "one")
        schedule.finish(.unstable, pages: 1, at: start)
        schedule.observe(fingerprint: "raw")
        XCTAssertNil(schedule.begin(at: start.addingTimeInterval(60), manual: false, todayDemand: "two"))
        schedule.observe(fingerprint: "raw")
        XCTAssertNotNil(schedule.begin(at: start.addingTimeInterval(60), manual: false, todayDemand: "three"))
    }
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

    func testHardBudgetLatchSurvivesUnsuccessfulManualRetry() {
        for outcome in [CycleCollectionSchedule.Outcome.cancelled, .transportFailure, .unstable, .endpointFailure] {
            var schedule = CycleCollectionSchedule()
            schedule.observe(fingerprint: "a")
            _ = schedule.begin(at: start, manual: false)
            schedule.finish(.budgetPartial, pages: 100, at: start)
            XCTAssertNotNil(schedule.begin(at: start.addingTimeInterval(60), manual: true))
            schedule.finish(outcome, pages: 2, at: start.addingTimeInterval(60))
            schedule.observe(fingerprint: "b")
            schedule.observe(fingerprint: "b")
            XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(7200), manual: false), .cycleLimit)
            XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(120), manual: true), .ready)
        }
    }

    func testHardBudgetLatchSurvivesManualRetryRetirementAndLateCompletion() throws {
        var schedule = CycleCollectionSchedule()
        _ = schedule.begin(at: start, manual: false)
        schedule.finish(.budgetPartial, pages: 100, at: start)
        _ = schedule.begin(at: start.addingTimeInterval(60), manual: true)
        let retryID = try XCTUnwrap(schedule.currentAttemptID)
        schedule.retireCurrent(at: start.addingTimeInterval(60))
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(120), manual: false), .cycleLimit)
        schedule.finish(.complete, pages: 2, at: start.addingTimeInterval(120), attemptID: retryID)
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(120), manual: false), .cycleLimit)
        XCTAssertEqual(schedule.automaticPagesRemaining(at: start.addingTimeInterval(120)), 200)
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(120), manual: true), .ready)
    }

    func testSuccessfulCurrentManualScanClearsHardBudgetLatch() {
        var schedule = CycleCollectionSchedule()
        schedule.observe(fingerprint: "a")
        _ = schedule.begin(at: start, manual: false)
        schedule.finish(.budgetPartial, pages: 100, at: start)
        _ = schedule.begin(at: start.addingTimeInterval(60), manual: true)
        schedule.finish(.complete, pages: 4, at: start.addingTimeInterval(60))
        schedule.observe(fingerprint: "b")
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(659), manual: false),
                       .waiting(until: start.addingTimeInterval(660)))
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(660), manual: false), .ready)
    }

    func testHardBudgetLatchDoesNotBypassServerDeadlineForManualRetry() {
        var schedule = CycleCollectionSchedule()
        _ = schedule.begin(at: start, manual: false)
        schedule.finish(.budgetPartial, pages: 100, at: start)
        _ = schedule.begin(at: start.addingTimeInterval(60), manual: true)
        schedule.finish(.rateLimited(retryAfter: 300), pages: 1, at: start.addingTimeInterval(60))
        let deadline = start.addingTimeInterval(360)
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(120), manual: true), .waiting(until: deadline))
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(120), manual: false), .waiting(until: deadline))
        XCTAssertEqual(schedule.availability(at: deadline, manual: false), .cycleLimit)
        XCTAssertEqual(schedule.availability(at: deadline, manual: true), .ready)
    }

    func testRetiredAutomaticCostChargesOnceWithoutClearingNewHardBudgetLatch() throws {
        var schedule = CycleCollectionSchedule()
        _ = schedule.begin(at: start, manual: false)
        let retiredID = try XCTUnwrap(schedule.currentAttemptID)
        schedule.retireCurrent(at: start)
        _ = schedule.begin(at: start.addingTimeInterval(60), manual: true)
        schedule.finish(.budgetPartial, pages: 100, at: start.addingTimeInterval(60))
        schedule.finish(.complete, pages: 2, at: start.addingTimeInterval(60), attemptID: retiredID)
        schedule.finish(.complete, pages: 2, at: start.addingTimeInterval(60), attemptID: retiredID)
        XCTAssertEqual(schedule.automaticPagesRemaining(at: start.addingTimeInterval(60)), 298)
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(120), manual: false), .cycleLimit)
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

    func testInvalidatingCompletedTodayDemandPreservesStartManualLegacyAndServerGates() {
        var schedule = CycleCollectionSchedule()
        schedule.observe(fingerprint: "raw")
        _ = schedule.begin(at: start, manual: false, todayDemand: "same")
        schedule.finish(.complete, pages: 4, at: start.addingTimeInterval(45))
        schedule.invalidateCompletedTodayDemand()
        XCTAssertEqual(schedule.automaticPagesRemaining(at: start.addingTimeInterval(50)), 296)
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(59), manual: false, todayDemand: "same"),
                       .waiting(until: start.addingTimeInterval(117)))
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(117), manual: false, todayDemand: "same"), .ready)
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(60), manual: true),
                       .waiting(until: start.addingTimeInterval(105)))
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(60), manual: false), .unchanged)
        schedule.recordSupplementRateLimit(900, at: start.addingTimeInterval(50))
        schedule.invalidateCompletedTodayDemand()
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(60), manual: false, todayDemand: "same"),
                       .waiting(until: start.addingTimeInterval(950)))
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(60), manual: true),
                       .waiting(until: start.addingTimeInterval(950)))
    }

    func testInvalidatingTodayDemandPreservesFailureBackoffsAndRawStability() {
        for (outcome, delay) in [(CycleCollectionSchedule.Outcome.transportFailure, 60.0),
                                 (.endpointFailure, 1800.0), (.rateLimited(retryAfter: 900), 900.0)] {
            var schedule = CycleCollectionSchedule()
            schedule.observe(fingerprint: "raw")
            _ = schedule.begin(at: start, manual: false, todayDemand: "same")
            schedule.finish(outcome, pages: 4, at: start)
            schedule.invalidateCompletedTodayDemand()
            XCTAssertEqual(schedule.automaticPagesRemaining(at: start), 296)
            XCTAssertEqual(schedule.availability(at: start, manual: false, todayDemand: "same"),
                           .waiting(until: start.addingTimeInterval(delay)))
        }
        var unstable = CycleCollectionSchedule()
        unstable.observe(fingerprint: "raw")
        _ = unstable.begin(at: start, manual: false, todayDemand: "same")
        unstable.finish(.unstable, pages: 1, at: start)
        unstable.observe(fingerprint: "raw")
        unstable.invalidateCompletedTodayDemand()
        XCTAssertEqual(unstable.availability(at: start.addingTimeInterval(60), manual: false, todayDemand: "same"),
                       .waiting(until: start.addingTimeInterval(300)))
        unstable.observe(fingerprint: "raw")
        XCTAssertEqual(unstable.availability(at: start.addingTimeInterval(60), manual: false, todayDemand: "same"), .ready)
    }

    func testInvalidatingTodayDemandPreservesHardRollingAndRetiredPageBudgets() {
        var hard = CycleCollectionSchedule()
        _ = hard.begin(at: start, manual: false, todayDemand: "same")
        hard.finish(.budgetPartial, pages: 100, at: start)
        hard.invalidateCompletedTodayDemand()
        XCTAssertEqual(hard.availability(at: start.addingTimeInterval(60), manual: false, todayDemand: "same"), .cycleLimit)
        var rolling = CycleCollectionSchedule()
        for index in 0..<3 {
            let instant = start.addingTimeInterval(Double(index * 60))
            rolling.resetCycle()
            XCTAssertEqual(rolling.begin(at: instant, manual: false, todayDemand: "revision-\(index)"), 100)
            rolling.finish(.complete, pages: 100, at: instant)
        }
        rolling.invalidateCompletedTodayDemand()
        XCTAssertEqual(rolling.automaticPagesRemaining(at: start.addingTimeInterval(180)), 0)
        XCTAssertEqual(rolling.availability(at: start.addingTimeInterval(180), manual: false, todayDemand: "revision-2"),
                       .waiting(until: start.addingTimeInterval(3600)))
        var retired = CycleCollectionSchedule()
        _ = retired.begin(at: start, manual: false, todayDemand: "same")
        retired.retireCurrent(at: start)
        retired.invalidateCompletedTodayDemand()
        XCTAssertEqual(retired.automaticPagesRemaining(at: start), 200)
    }

}
