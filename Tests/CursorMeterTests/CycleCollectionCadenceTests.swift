import XCTest
@testable import CursorMeter

final class CycleCollectionCadenceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    func testSuccessfulFiftyOnePageCollectionWaitsPastLegacyCooldown() {
        var schedule = CycleCollectionSchedule()
        XCTAssertEqual(schedule.begin(at: start, manual: false, todayDemand: "first"), 100)
        schedule.finish(.complete, pages: 51, at: start)

        let deadline = start.addingTimeInterval(918)
        for elapsed in [60.0, 600, 917] {
            XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(elapsed), manual: false,
                                                  todayDemand: "second"), .waiting(until: deadline))
        }
        XCTAssertEqual(schedule.begin(at: deadline, manual: false, todayDemand: "second"), 100)
    }

    func testSteadySuccessfulCollectionsKeepFullAllowanceForThreeHours() {
        for (pages, delay) in [(5, 90.0), (11, 198), (21, 378), (51, 918), (100, 1800)] {
            for duration in [0.0, 60] {
                var schedule = CycleCollectionSchedule()
                var charges: [(date: Date, pages: Int)] = []
                var instant = start
                var attempts = 0
                let scenario = "pages=\(pages), duration=\(duration)"
                while instant <= start.addingTimeInterval(10_800) {
                    let usedBefore = charges.filter { instant.timeIntervalSince($0.date) < 3600 }
                        .reduce(0) { $0 + $1.pages }
                    XCTAssertLessThanOrEqual(usedBefore, 200, scenario)
                    XCTAssertEqual(schedule.automaticPagesRemaining(at: instant), 300 - usedBefore, scenario)
                    XCTAssertEqual(schedule.begin(at: instant, manual: false, todayDemand: "revision-\(attempts)"),
                                   100, scenario)
                    let finished = instant.addingTimeInterval(duration)
                    schedule.finish(.complete, pages: pages, at: finished)
                    charges.append((finished, pages))
                    let usedAfter = charges.filter { finished.timeIntervalSince($0.date) < 3600 }
                        .reduce(0) { $0 + $1.pages }
                    XCTAssertLessThanOrEqual(usedAfter, 300, scenario)
                    XCTAssertEqual(schedule.automaticPagesRemaining(at: finished), 300 - usedAfter, scenario)
                    attempts += 1
                    let next = finished.addingTimeInterval(delay)
                    XCTAssertEqual(schedule.availability(at: next.addingTimeInterval(-1), manual: false,
                                                          todayDemand: "revision-\(attempts)"),
                                   .waiting(until: next), scenario)
                    XCTAssertEqual(schedule.availability(at: next, manual: false,
                                                          todayDemand: "revision-\(attempts)"), .ready, scenario)
                    instant = next
                }
                XCTAssertEqual(attempts, Int(10_800 / (duration + delay)) + 1, scenario)
            }
        }
    }

    func testLowerSuccessfulCostReplacesPreviousPacingDeadline() {
        var schedule = CycleCollectionSchedule()
        XCTAssertEqual(schedule.begin(at: start, manual: false, todayDemand: "expensive"), 100)
        schedule.finish(.complete, pages: 51, at: start)
        XCTAssertEqual(schedule.begin(at: start.addingTimeInterval(918), manual: false, todayDemand: "cheap"), 100)
        schedule.finish(.complete, pages: 5, at: start.addingTimeInterval(948))
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(1037), manual: false, todayDemand: "next"),
                       .waiting(until: start.addingTimeInterval(1038)))
        XCTAssertEqual(schedule.begin(at: start.addingTimeInterval(1038), manual: false, todayDemand: "next"), 100)
        XCTAssertEqual(schedule.automaticPagesRemaining(at: start.addingTimeInterval(1038)), 244)
    }

    func testVariableSuccessfulCostsAndDurationsKeepFullAllowanceForThreeHours() {
        let scenarios = [[(34, 612.0), (100, 1800), (100, 1800)],
                         [(5, 90), (100, 1800), (5, 90)],
                         [(3, 60), (100, 1800)], [(67, 1206)]]
        for costs in scenarios {
            for firstDuration in [0.0, 60] {
                var schedule = CycleCollectionSchedule()
                var charges: [(date: Date, pages: Int)] = []
                var instant = start
                var attempts = 0
                let scenario = "costs=\(costs), firstDuration=\(firstDuration)"
                while instant <= start.addingTimeInterval(10_800) {
                    let (pages, delay) = costs[attempts % costs.count]
                    let duration = attempts.isMultiple(of: 2) ? firstDuration : 60 - firstDuration
                    let usedBefore = charges.filter { instant.timeIntervalSince($0.date) < 3600 }
                        .reduce(0) { $0 + $1.pages }
                    XCTAssertLessThanOrEqual(usedBefore, 200, scenario)
                    XCTAssertEqual(schedule.automaticPagesRemaining(at: instant), 300 - usedBefore, scenario)
                    XCTAssertEqual(schedule.begin(at: instant, manual: false, todayDemand: "revision-\(attempts)"),
                                   100, scenario)
                    let finished = instant.addingTimeInterval(duration)
                    schedule.finish(.complete, pages: pages, at: finished)
                    charges.append((finished, pages))
                    let usedAfter = charges.filter { finished.timeIntervalSince($0.date) < 3600 }
                        .reduce(0) { $0 + $1.pages }
                    XCTAssertLessThanOrEqual(usedAfter, 300, scenario)
                    XCTAssertEqual(schedule.automaticPagesRemaining(at: finished), 300 - usedAfter, scenario)
                    attempts += 1
                    let next = finished.addingTimeInterval(delay)
                    XCTAssertEqual(schedule.availability(at: next.addingTimeInterval(-1), manual: false,
                                                          todayDemand: "revision-\(attempts)"),
                                   .waiting(until: next), scenario)
                    XCTAssertEqual(schedule.availability(at: next, manual: false,
                                                          todayDemand: "revision-\(attempts)"), .ready, scenario)
                    instant = next
                }
                XCTAssertGreaterThan(attempts, costs.count, scenario)
            }
        }
    }

    func testSuccessfulRetryPacesAllChargedPagesFromCompletion() {
        var schedule = CycleCollectionSchedule()
        schedule.observe(fingerprint: "raw")
        XCTAssertEqual(schedule.begin(at: start, manual: false, todayDemand: "first"), 100)
        schedule.finish(.unstable, pages: 1, at: start)
        schedule.observe(fingerprint: "raw")
        schedule.observe(fingerprint: "raw")
        XCTAssertEqual(schedule.begin(at: start.addingTimeInterval(60), manual: false, todayDemand: "retry"), 100)
        schedule.finish(.complete, pages: 22, at: start.addingTimeInterval(90))
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(485), manual: false, todayDemand: "next"),
                       .waiting(until: start.addingTimeInterval(486)))
        XCTAssertEqual(schedule.begin(at: start.addingTimeInterval(486), manual: false, todayDemand: "next"), 100)
        XCTAssertEqual(schedule.automaticPagesRemaining(at: start.addingTimeInterval(486)), 277)
    }

    func testLegacyAutomaticSuccessSeedsTodayPacingButKeepsLegacyCooldown() {
        var schedule = CycleCollectionSchedule()
        schedule.observe(fingerprint: "first")
        XCTAssertEqual(schedule.begin(at: start, manual: false), 100)
        schedule.finish(.complete, pages: 51, at: start)
        schedule.observe(fingerprint: "second")
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(599), manual: false),
                       .waiting(until: start.addingTimeInterval(600)))
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(600), manual: false), .ready)
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(600), manual: false, todayDemand: "today"),
                       .waiting(until: start.addingTimeInterval(918)))
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(918), manual: false, todayDemand: "today"), .ready)
    }

    func testManualSuccessPreservesUnexpiredAutomaticPacing() {
        var schedule = CycleCollectionSchedule()
        XCTAssertEqual(schedule.begin(at: start, manual: false, todayDemand: "first"), 100)
        schedule.finish(.complete, pages: 51, at: start)
        XCTAssertEqual(schedule.begin(at: start.addingTimeInterval(60), manual: true), 100)
        schedule.finish(.complete, pages: 100, at: start.addingTimeInterval(75))
        XCTAssertEqual(schedule.automaticPagesRemaining(at: start.addingTimeInterval(75)), 249)
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(134), manual: true),
                       .waiting(until: start.addingTimeInterval(135)))
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(135), manual: true), .ready)
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(917), manual: false, todayDemand: "next"),
                       .waiting(until: start.addingTimeInterval(918)))
        XCTAssertEqual(schedule.begin(at: start.addingTimeInterval(918), manual: false, todayDemand: "next"), 100)
    }

    func testManualSuccessDoesNotCreateAutomaticPacing() {
        var schedule = CycleCollectionSchedule()
        XCTAssertEqual(schedule.begin(at: start, manual: true), 100)
        schedule.finish(.complete, pages: 100, at: start.addingTimeInterval(45))
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(59), manual: false, todayDemand: "today"),
                       .waiting(until: start.addingTimeInterval(60)))
        XCTAssertEqual(schedule.begin(at: start.addingTimeInterval(60), manual: false, todayDemand: "today"), 100)
        XCTAssertEqual(schedule.automaticPagesRemaining(at: start.addingTimeInterval(60)), 300)
    }

    func testPresentationInvalidationRetainsPacingAndResetClearsOnlyPacing() {
        var schedule = CycleCollectionSchedule()
        XCTAssertEqual(schedule.begin(at: start, manual: false, todayDemand: "same"), 100)
        schedule.finish(.complete, pages: 51, at: start)
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(10), manual: false, todayDemand: "same"), .unchanged)
        schedule.invalidateCompletedTodayDemand()
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(10), manual: false, todayDemand: "same"),
                       .waiting(until: start.addingTimeInterval(918)))
        schedule.resetCycle()
        XCTAssertEqual(schedule.automaticPagesRemaining(at: start.addingTimeInterval(10)), 249)
        XCTAssertEqual(schedule.begin(at: start.addingTimeInterval(10), manual: false, todayDemand: "same"), 100)
    }

    func testRetiredSuccessCannotShortenOrExtendCurrentPacing() throws {
        for pages in [1, 100] {
            var schedule = CycleCollectionSchedule()
            XCTAssertEqual(schedule.begin(at: start, manual: false, todayDemand: "retired"), 100)
            let retiredID = try XCTUnwrap(schedule.currentAttemptID)
            schedule.retireCurrent(at: start)
            schedule.resetCycle()
            XCTAssertEqual(schedule.automaticPagesRemaining(at: start), 200)
            XCTAssertEqual(schedule.begin(at: start, manual: false, todayDemand: "current"), 100)
            schedule.finish(.complete, pages: 51, at: start)
            schedule.finish(.complete, pages: pages, at: start.addingTimeInterval(10), attemptID: retiredID)
            XCTAssertEqual(schedule.automaticPagesRemaining(at: start.addingTimeInterval(10)), 249 - pages)
            XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(917), manual: false, todayDemand: "next"),
                           .waiting(until: start.addingTimeInterval(918)))
            XCTAssertEqual(schedule.begin(at: start.addingTimeInterval(918), manual: false, todayDemand: "next"), 100)
        }
    }

    func testFailureOutcomesUseExistingBackoffInsteadOfPriorSuccessPacing() {
        for (outcome, delay) in [(CycleCollectionSchedule.Outcome.transportFailure, 60.0),
                                 (.endpointFailure, 1800), (.cancelled, 60), (.rateLimited(retryAfter: 300), 300)] {
            var schedule = CycleCollectionSchedule()
            XCTAssertEqual(schedule.begin(at: start, manual: false, todayDemand: "first"), 100)
            schedule.finish(.complete, pages: 51, at: start)
            XCTAssertEqual(schedule.begin(at: start.addingTimeInterval(60), manual: true), 100)
            schedule.finish(outcome, pages: 1, at: start.addingTimeInterval(60))
            let deadline = start.addingTimeInterval(60 + delay)
            XCTAssertEqual(schedule.availability(at: deadline.addingTimeInterval(-1), manual: false, todayDemand: "next"),
                           .waiting(until: deadline))
            XCTAssertEqual(schedule.begin(at: deadline, manual: false, todayDemand: "next"), 100)
        }
    }

    func testUnstableEarlyRetryStillIgnoresPriorSuccessPacing() {
        var schedule = CycleCollectionSchedule()
        schedule.observe(fingerprint: "raw")
        XCTAssertEqual(schedule.begin(at: start, manual: false, todayDemand: "first"), 100)
        schedule.finish(.complete, pages: 51, at: start)
        schedule.observe(fingerprint: "changed")
        XCTAssertEqual(schedule.begin(at: start.addingTimeInterval(600), manual: false), 100)
        schedule.finish(.unstable, pages: 60, at: start.addingTimeInterval(600))
        XCTAssertEqual(schedule.automaticPagesRemaining(at: start.addingTimeInterval(600)), 189)
        schedule.observe(fingerprint: "changed")
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(660), manual: false, todayDemand: "retry"),
                       .waiting(until: start.addingTimeInterval(900)))
        schedule.observe(fingerprint: "changed")
        XCTAssertEqual(schedule.availability(at: start.addingTimeInterval(659), manual: false, todayDemand: "retry"),
                       .waiting(until: start.addingTimeInterval(900)))
        XCTAssertEqual(schedule.begin(at: start.addingTimeInterval(660), manual: false, todayDemand: "retry"), 100)
    }

    func testSuccessfulChargeClampsToAllowanceAndMinimumWait() {
        for (pages, delay, charged) in [(-1, 60.0, 0), (0, 60, 0), (1, 60, 1), (3, 60, 3),
                                       (101, 1800, 100), (Int.max, 1800, 100)] {
            var schedule = CycleCollectionSchedule()
            XCTAssertEqual(schedule.begin(at: start, manual: false, todayDemand: "first"), 100)
            schedule.finish(.complete, pages: pages, at: start.addingTimeInterval(45))
            let deadline = start.addingTimeInterval(45 + delay)
            XCTAssertEqual(schedule.availability(at: deadline.addingTimeInterval(-1), manual: false, todayDemand: "next"),
                           .waiting(until: deadline))
            XCTAssertEqual(schedule.begin(at: deadline, manual: false, todayDemand: "next"), 100)
            XCTAssertEqual(schedule.automaticPagesRemaining(at: deadline), 300 - charged)
        }
    }
}
