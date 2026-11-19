import XCTest
@testable import CursorMeter

@MainActor
final class SharedAllowanceControllerTests: XCTestCase {
    private let owner = SharedUsageOwner(generation: 1, credentialDigest: "credential-a", subjectDigest: "subject-a")
    private let start = ISO8601DateFormatter().date(from: "2026-11-12T12:00:00Z")!
    private var now: Date { start.addingTimeInterval(6 * 86400) }
    private var weekly: SharedWeeklyUsage { .init(percentUsed: 12.5, period: UsageCycle(start: start, end: start.addingTimeInterval(604800))) }

    private func refresh(_ controller: SharedActivityController, _ fixture: AllowanceFixture, weekly: SharedWeeklyUsage? = nil) async {
        let value = weekly ?? self.weekly
        _ = await controller.refresh(cookieHeader: "synthetic", owner: owner, weekly: value,
            confirmationProvider: fixture, currentWeekly: { value }, isCurrent: { true })
    }

    func testExactWeekAggregateIsConfirmedBeforePublishingAndPaidTokensAreExcluded() async throws {
        let fixture = AllowanceFixture(weekly: weekly)
        let controller = SharedActivityController(provider: fixture, now: { self.now })
        controller.bind(owner)
        await refresh(controller, fixture)
        XCTAssertEqual(controller.allowance?.includedTokens, 50_000_000)
        XCTAssertEqual(controller.allowance?.estimatedCapacity, 400_000_000)
        XCTAssertEqual(controller.observation?.weekly, weekly)
        XCTAssertNil(controller.observation?.change)
        let calls = await fixture.calls
        XCTAssertLessThan(try XCTUnwrap(calls.firstIndex(of: "aggregate")), try XCTUnwrap(calls.firstIndex(of: "confirm")))
    }

    func testConfirmationMismatchOrFailureSuppressesEstimatesButKeepsActivity() async {
        for failure in [false, true] {
            let fixture = AllowanceFixture(weekly: weekly)
            let controller = SharedActivityController(provider: fixture, now: { self.now })
            controller.bind(owner)
            await refresh(controller, fixture)
            await fixture.setConfirmation(percent: 13, fails: failure)
            await refresh(controller, fixture)
            XCTAssertNil(controller.allowance)
            XCTAssertEqual(controller.observation?.weekly, weekly)
            XCTAssertEqual(controller.recent.availability, .current)
            XCTAssertEqual(controller.daily.availability, .current)
        }
    }

    func testPendingAndLateOwnerOrCycleChangesCannotPublish() async {
        for switchOwner in [false, true] {
            let fixture = AllowanceFixture(weekly: weekly)
            let controller = SharedActivityController(provider: fixture, now: { self.now })
            controller.bind(owner)
            await refresh(controller, fixture)
            await fixture.holdAggregate()
            var current = weekly
            let task = Task { await controller.refresh(cookieHeader: "synthetic", owner: owner, weekly: weekly,
                confirmationProvider: fixture, currentWeekly: { current }, isCurrent: { true }) }
            await fixture.waitForAggregate()
            XCTAssertNil(controller.allowance)
            XCTAssertEqual(controller.observation?.weekly, weekly)
            if switchOwner {
                controller.bind(.init(generation: 2, credentialDigest: "b", subjectDigest: "b"))
            } else {
                current = .init(percentUsed: 12.5, period: UsageCycle(start: start.addingTimeInterval(1), end: weekly.period!.end))
            }
            await fixture.releaseAggregate()
            _ = await task.value
            XCTAssertNil(controller.allowance)
            XCTAssertNil(controller.observation)
        }
    }

    func testErrorResetsObservationIntervalAndEqualOrDecreasedReadingsHaveNoChange() async throws {
        let fixture = AllowanceFixture(weekly: weekly)
        var time = now
        let controller = SharedActivityController(provider: fixture, now: { time })
        controller.bind(owner)
        await refresh(controller, fixture)
        time = time.addingTimeInterval(60)
        let increased = SharedWeeklyUsage(percentUsed: 13, period: weekly.period)
        await fixture.setConfirmation(percent: 13)
        await refresh(controller, fixture, weekly: increased)
        XCTAssertEqual(try XCTUnwrap(controller.observation?.change?.percentagePoints), 0.5, accuracy: 0.000001)
        time = time.addingTimeInterval(60)
        await refresh(controller, fixture, weekly: increased)
        XCTAssertNil(controller.observation?.change)
        controller.recordFailure()
        XCTAssertNil(controller.allowance)
        XCTAssertNil(controller.observation)
        time = time.addingTimeInterval(60)
        await fixture.setConfirmation(percent: 14)
        await refresh(controller, fixture, weekly: .init(percentUsed: 14, period: weekly.period))
        XCTAssertNil(controller.observation?.change)
        time = time.addingTimeInterval(60)
        await fixture.setConfirmation(percent: 12)
        await refresh(controller, fixture, weekly: .init(percentUsed: 12, period: weekly.period))
        XCTAssertNil(controller.observation?.change)
    }

    func testObservationUsesFreshWeeklyReadingTimestamp() async {
        let fixture = AllowanceFixture(weekly: weekly)
        let controller = SharedActivityController(provider: fixture, now: { self.now })
        controller.bind(owner)
        let observedAt = now.addingTimeInterval(-5)
        _ = await controller.refresh(cookieHeader: "synthetic", owner: owner, weekly: weekly,
            weeklyObservedAt: observedAt, confirmationProvider: fixture, currentWeekly: { self.weekly }, isCurrent: { true })
        XCTAssertEqual(controller.observation?.at, observedAt)
    }

    func testAggregateFailureAndConfirmationCycleMismatchKeepOnlyReportedFact() async {
        for aggregateFails in [false, true] {
            let fixture = AllowanceFixture(weekly: weekly)
            if aggregateFails { await fixture.setAggregateFailure() }
            else { await fixture.setConfirmationCycle(UsageCycle(start: start.addingTimeInterval(1), end: weekly.period!.end)!) }
            let controller = SharedActivityController(provider: fixture, now: { self.now })
            controller.bind(owner)
            await refresh(controller, fixture)
            XCTAssertNil(controller.allowance)
            XCTAssertEqual(controller.observation?.weekly, weekly)
            XCTAssertEqual(controller.recent.availability, .current)
            XCTAssertEqual(controller.daily.availability, .current)
        }
    }

    func testObservedIncreaseRemainsIndependentOfAggregateOrConfirmationFailure() async throws {
        for aggregateFails in [false, true] {
            let fixture = AllowanceFixture(weekly: weekly)
            var time = now
            let controller = SharedActivityController(provider: fixture, now: { time })
            controller.bind(owner)
            await refresh(controller, fixture)
            let previousTime = time
            time = time.addingTimeInterval(60)
            if aggregateFails { await fixture.setAggregateFailure() }
            else { await fixture.setConfirmation(percent: 13, fails: true) }
            let increased = SharedWeeklyUsage(percentUsed: 13, period: weekly.period)
            await refresh(controller, fixture, weekly: increased)
            XCTAssertNil(controller.allowance)
            let change = try XCTUnwrap(controller.observation?.change)
            XCTAssertEqual(change.percentagePoints, 0.5, accuracy: 0.000001)
            XCTAssertEqual(change.start, previousTime)
            XCTAssertEqual(change.end, time)
        }
    }

    func testStaleWeeklyReadingClearsFactAndBreaksObservationInterval() async {
        let fixture = AllowanceFixture(weekly: weekly)
        var time = now
        let controller = SharedActivityController(provider: fixture, now: { time })
        controller.bind(owner)
        await refresh(controller, fixture)
        _ = await controller.refresh(cookieHeader: "synthetic", owner: owner, weekly: weekly,
            confirmationProvider: fixture, currentWeekly: { nil }, isCurrent: { true })
        XCTAssertNil(controller.allowance)
        XCTAssertNil(controller.observation)
        time = time.addingTimeInterval(60)
        let fresh = SharedWeeklyUsage(percentUsed: 13, period: weekly.period)
        await fixture.setConfirmation(percent: 13)
        await refresh(controller, fixture, weekly: fresh)
        XCTAssertNil(controller.observation?.change)
    }

    func testWeeklyObservationContinuesWhenCalibrationIsIneligible() async throws {
        let fixture = AllowanceFixture(weekly: weekly)
        var time = now
        let controller = SharedActivityController(provider: fixture, now: { time })
        controller.bind(owner)
        await refresh(controller, fixture)
        time = time.addingTimeInterval(60)
        let exhausted = SharedWeeklyUsage(percentUsed: 100, period: weekly.period)
        await refresh(controller, fixture, weekly: exhausted)
        XCTAssertNil(controller.allowance)
        XCTAssertEqual(controller.observation?.weekly, exhausted)
        XCTAssertEqual(controller.observation?.change?.percentagePoints, 87.5)
    }

    func testMissingConfirmationProviderDoesNotUseRealAPIAndResetsOldCalibration() async {
        let fixture = AllowanceFixture(weekly: weekly)
        let controller = SharedActivityController(provider: fixture, now: { self.now })
        controller.bind(owner)
        await refresh(controller, fixture)
        _ = await controller.refresh(cookieHeader: "synthetic", owner: owner, weekly: weekly,
            currentWeekly: { self.weekly }, isCurrent: { true })
        XCTAssertNil(controller.allowance)
        XCTAssertEqual(controller.observation?.weekly, weekly)
        XCTAssertEqual(controller.recent.availability, .current)
    }

    func testFailureDuringSuspensionAndRolloverDiscardLateCalibration() async {
        for rollover in [false, true] {
            let fixture = AllowanceFixture(weekly: weekly)
            var time = now
            let controller = SharedActivityController(provider: fixture, now: { time })
            controller.bind(owner)
            await fixture.holdAggregate()
            let task = Task { await self.refresh(controller, fixture) }
            await fixture.waitForAggregate()
            if rollover { time = weekly.period!.end } else { controller.recordFailure() }
            await fixture.releaseAggregate()
            _ = await task.value
            XCTAssertNil(controller.allowance)
            XCTAssertNil(controller.observation)
        }
    }
}

actor AllowanceFixture: CursorSharedUsageFetching, CursorSharedActivityFetching {
    let weekly: SharedWeeklyUsage
    private var percent: Double
    private var confirmationFails = false
    private var aggregateFails = false
    private var confirmationCycle: UsageCycle?
    private var held = false
    private var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var calls: [String] = []
    init(weekly: SharedWeeklyUsage) { self.weekly = weekly; percent = weekly.percentUsed! }
    func setConfirmation(percent: Double, fails: Bool = false) { self.percent = percent; confirmationFails = fails }
    func setAggregateFailure() { aggregateFails = true }
    func setConfirmationCycle(_ cycle: UsageCycle) { confirmationCycle = cycle }
    func holdAggregate() { held = true; waiting = false }
    func waitForAggregate() async { while !waiting { await Task.yield() } }
    func releaseAggregate() { held = false; continuation?.resume(); continuation = nil }
    func fetchCurrentPeriod(cookieHeader: String) async throws -> CurrentPeriodUsageResponse {
        calls.append("confirm")
        if confirmationFails { throw CursorSharedAPIError.transport }
        let cycle = confirmationCycle ?? weekly.period!
        return try decode(["billingCycleStart": stamp(cycle.start), "billingCycleEnd": stamp(cycle.end), "planUsage": ["totalPercentUsed": percent]])
    }
    func fetchDaily(cookieHeader: String, start: Date, end: Date) async throws -> SharedDailyUsageResponse {
        if start == weekly.period!.start {
            calls.append("aggregate")
            if aggregateFails { throw CursorSharedAPIError.transport }
            if held { waiting = true; await withCheckedContinuation { continuation = $0 } }
        }
        return try decode(["startTime": stamp(start), "endTime": stamp(end), "totalContractedCost": "0", "totalTokens": 90_000_000, "totalIncludedTokens": 50_000_000,
            "series": [], "other": ["totalContractedCost": "0", "totalTokens": 90_000_000, "totalIncludedTokens": 50_000_000,
                "points": [["dayStartTime": stamp(SharedActivityValue.utc.startOfDay(for: end)), "contractedCost": "0", "tokens": 90_000_000, "includedTokens": 50_000_000]]]])
    }
    func fetchRecent(cookieHeader: String, start: Date, end: Date) async throws -> SharedBillingItemsResponse {
        try decode(["data": [["eventTime": stamp(end.addingTimeInterval(-1)), "chargeCategory": "usage", "usageType": "included", "totalTokens": "200000"]], "pagination": ["hasMore": false]])
    }
    func fetchStatus(cookieHeader: String) async throws -> SharedUsageStatusResponse {
        try decode(["availability": "available", "monthlyUsage": ["periodStart": "2026-11-01T00:00:00Z", "resetsAt": "2026-12-01T00:00:00Z"]])
    }
    func fetchPlanInfo(cookieHeader: String) async throws -> CursorPlanInfoResponse { throw CursorSharedAPIError.invalidResponse }
    func fetchPrepaid(cookieHeader: String) async throws -> CursorPrepaidBillingResponse { throw CursorSharedAPIError.invalidResponse }
    func fetchPaidCap(cookieHeader: String) async throws -> CursorPaidCapResponse { throw CursorSharedAPIError.invalidResponse }
    private func stamp(_ date: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f.string(from: date) }
    private func decode<T: Decodable>(_ object: [String: Any]) throws -> T { try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object)) }
}
