import XCTest
@testable import CursorMeter

@MainActor
final class SharedUsageControllerTests: XCTestCase {
    private let owner = SharedUsageOwner(generation: 1, credentialDigest: "credential", subjectDigest: "subject")
    private let now = Date(timeIntervalSince1970: 1_794_873_500)

    func testSharedRefreshKeepsWeeklyWalletAndPaidValuesSeparate() async throws {
        let provider = SharedUsageFixtureProvider()
        let controller = SharedUsageController(provider: provider, now: { self.now })
        controller.acceptPlan(.success(try SharedUsageFixtureProvider.plan()), owner: owner, personalScope: true)
        let success = await controller.refresh(cookieHeader: "fixture", owner: owner, isCurrent: { true })
        XCTAssertTrue(success)
        XCTAssertEqual(controller.mode, .sharedWeekly)
        XCTAssertEqual(controller.snapshot?.weekly.value?.percentUsed, 25)
        XCTAssertEqual(controller.snapshot?.credit.value?.remainingCents, 6200)
        XCTAssertEqual(controller.snapshot?.paid.usedCents, 700)
        XCTAssertEqual(controller.snapshot?.paid.cap, .limited(2500))
        XCTAssertEqual(controller.lastCompleteSuccessAt, now)
    }

    func testColdDetectorFailureNeverEstablishesLegacyMode() {
        let controller = SharedUsageController(provider: SharedUsageFixtureProvider())
        controller.acceptPlan(.failure(CursorSharedAPIError.invalidResponse), owner: owner, personalScope: true)
        XCTAssertEqual(controller.mode, .unavailable)
        XCTAssertNil(controller.snapshot)
        XCTAssertNotNil(controller.detectionError)
    }

    func testKnownSharedDetectorFailurePreservesStaleSnapshot() async throws {
        let controller = SharedUsageController(provider: SharedUsageFixtureProvider(), now: { self.now })
        controller.acceptPlan(.success(try SharedUsageFixtureProvider.plan()), owner: owner, personalScope: true)
        _ = await controller.refresh(cookieHeader: "fixture", owner: owner, isCurrent: { true })
        controller.acceptPlan(.failure(CursorSharedAPIError.unauthorized), owner: owner, personalScope: true)
        XCTAssertEqual(controller.mode, .sharedWeekly)
        XCTAssertEqual(controller.snapshot?.weekly.value?.percentUsed, 25)
        XCTAssertTrue(controller.snapshot?.weekly.isStale == true)
        XCTAssertNil(controller.snapshot?.hasIncludedUsage(at: now))
    }

    func testWalletAndCapFailurePreserveEarlierValuesIndependently() async throws {
        let provider = SharedUsageFixtureProvider()
        let controller = SharedUsageController(provider: provider, now: { self.now })
        controller.acceptPlan(.success(try SharedUsageFixtureProvider.plan()), owner: owner, personalScope: true)
        _ = await controller.refresh(cookieHeader: "fixture", owner: owner, isCurrent: { true })
        await provider.setFailures(prepaid: .unauthorized, cap: .forbidden)
        let success = await controller.refresh(cookieHeader: "fixture", owner: owner, isCurrent: { true })
        XCTAssertFalse(success)
        XCTAssertEqual(controller.snapshot?.weekly.availability, .current)
        XCTAssertEqual(controller.snapshot?.credit.value?.remainingCents, 6200)
        XCTAssertEqual(controller.snapshot?.credit.availability, .stale)
        XCTAssertEqual(controller.snapshot?.paidCap.availability, .stale)
        XCTAssertEqual(controller.snapshot?.monthlyUsed.availability, .stale)
    }

    func testWeeklyFailureDoesNotHideFreshWallet() async throws {
        let provider = SharedUsageFixtureProvider()
        await provider.setFailures(period: .transport)
        let controller = SharedUsageController(provider: provider, now: { self.now })
        controller.acceptPlan(.success(try SharedUsageFixtureProvider.plan()), owner: owner, personalScope: true)
        let success = await controller.refresh(cookieHeader: "fixture", owner: owner, isCurrent: { true })
        XCTAssertFalse(success)
        XCTAssertEqual(controller.snapshot?.weekly.availability, .unavailable)
        XCTAssertEqual(controller.snapshot?.credit.availability, .current)
        XCTAssertEqual(controller.snapshot?.paid.usedCents, 700)
    }

    func testExpiredAndMismatchedPeriodsCannotBeAvailable() async throws {
        for reset in [1_794_873_600_000, 1_794_873_600_001] as [Int64] {
            let controller = SharedUsageController(provider: SharedUsageFixtureProvider(), now: { .init(timeIntervalSince1970: 1_794_873_601) })
            controller.acceptPlan(.success(try SharedUsageFixtureProvider.plan(reset: reset)), owner: owner, personalScope: true)
            let success = await controller.refresh(cookieHeader: "fixture", owner: owner, isCurrent: { true })
            XCTAssertFalse(success)
            XCTAssertNil(controller.snapshot?.hasIncludedUsage(at: Date(timeIntervalSince1970: 1_794_873_601)))
            XCTAssertNotEqual(controller.snapshot?.weekly.availability, .current)
        }
    }

    func testMalformedAutoTopUpPreservesVerifiedSettingWhileWalletUpdates() async throws {
        for replacement in [#","autoTopUp":{"enabled":"invalid"}"#] {
            let provider = SharedUsageFixtureProvider()
            await provider.setPrepaid(#"{"billingMode":"PREPAID_BILLING_MODE_PREPAID","eligible":true,"availableCents":6200,"spentThisMonthCents":700,"autoTopUp":{"enabled":true,"thresholdCents":200,"topUpAmountCents":500}}"#)
            let controller = SharedUsageController(provider: provider, now: { self.now })
            controller.acceptPlan(.success(try SharedUsageFixtureProvider.plan()), owner: owner, personalScope: true)
            _ = await controller.refresh(cookieHeader: "fixture", owner: owner, isCurrent: { true })
            XCTAssertEqual(controller.snapshot?.autoTopUp.value?.enabled, true)
            let lastSuccess = controller.snapshot?.autoTopUp.lastSuccessAt
            await provider.setPrepaid("{\"billingMode\":\"PREPAID_BILLING_MODE_PREPAID\",\"eligible\":true,\"availableCents\":5100,\"spentThisMonthCents\":1800\(replacement)}")
            _ = await controller.refresh(cookieHeader: "fixture", owner: owner, isCurrent: { true })
            XCTAssertEqual(controller.snapshot?.autoTopUp.value?.enabled, true)
            XCTAssertEqual(controller.snapshot?.autoTopUp.value?.thresholdCents, 200)
            XCTAssertEqual(controller.snapshot?.autoTopUp.availability, .stale)
            XCTAssertEqual(controller.snapshot?.autoTopUp.error, .invalidResponse)
            XCTAssertEqual(controller.snapshot?.autoTopUp.lastSuccessAt, lastSuccess)
            XCTAssertEqual(controller.snapshot?.credit.value?.remainingCents, 5100)
            XCTAssertEqual(controller.snapshot?.credit.availability, .current)
            XCTAssertEqual(controller.snapshot?.monthlyUsed.value, 1800)
            XCTAssertEqual(controller.snapshot?.monthlyUsed.availability, .current)
        }
    }

    func testEligibleMissingAutoTopUpIsCurrentOff() async throws {
        let controller = SharedUsageController(provider: SharedUsageFixtureProvider(), now: { self.now })
        controller.acceptPlan(.success(try SharedUsageFixtureProvider.plan()), owner: owner, personalScope: true)
        _ = await controller.refresh(cookieHeader: "fixture", owner: owner, isCurrent: { true })
        XCTAssertEqual(controller.snapshot?.autoTopUp.value?.enabled, false)
        XCTAssertEqual(controller.snapshot?.autoTopUp.availability, .current)
        XCTAssertEqual(controller.snapshot?.credit.availability, .current)
    }

    func testNewResetImmediatelyMakesPreviousPeriodStale() async throws {
        let controller = SharedUsageController(provider: SharedUsageFixtureProvider(), now: { self.now })
        controller.acceptPlan(.success(try SharedUsageFixtureProvider.plan()), owner: owner, personalScope: true)
        _ = await controller.refresh(cookieHeader: "fixture", owner: owner, isCurrent: { true })
        controller.acceptPlan(.success(try SharedUsageFixtureProvider.plan(reset: 1_794_873_600_001)), owner: owner, personalScope: true)
        XCTAssertEqual(controller.snapshot?.weekly.value?.percentUsed, 25)
        XCTAssertEqual(controller.snapshot?.weekly.availability, .stale)
        XCTAssertNil(controller.snapshot?.hasIncludedUsage(at: now))
        XCTAssertEqual(controller.snapshot?.credit.availability, .current)
    }

    func testWeeklyAvailabilityExpiresWithoutAnotherRequest() async throws {
        let controller = SharedUsageController(provider: SharedUsageFixtureProvider(), now: { self.now })
        controller.acceptPlan(.success(try SharedUsageFixtureProvider.plan()), owner: owner, personalScope: true)
        _ = await controller.refresh(cookieHeader: "fixture", owner: owner, isCurrent: { true })
        XCTAssertEqual(controller.snapshot?.weeklyAvailability(at: now), .current)
        XCTAssertEqual(controller.snapshot?.weeklyAvailability(at: .init(timeIntervalSince1970: 1_794_873_600)), .stale)
    }

    func testExplicitLegacyClearsSharedSnapshot() async throws {
        let controller = SharedUsageController(provider: SharedUsageFixtureProvider(), now: { self.now })
        controller.acceptPlan(.success(try SharedUsageFixtureProvider.plan()), owner: owner, personalScope: true)
        _ = await controller.refresh(cookieHeader: "fixture", owner: owner, isCurrent: { true })
        controller.acceptPlan(.success(try SharedUsageFixtureProvider.decode(#"{"isMerged":false}"#)), owner: owner, personalScope: true)
        XCTAssertEqual(controller.mode, .legacy)
        XCTAssertNil(controller.snapshot)
    }

    func testKnownLegacyTeamScopeRemainsLegacyWhenDetectorFails() throws {
        let controller = SharedUsageController(provider: SharedUsageFixtureProvider())
        controller.acceptPlan(.success(try SharedUsageFixtureProvider.decode(#"{"isMerged":false}"#)), owner: owner, personalScope: false)
        controller.acceptPlan(.failure(CursorSharedAPIError.transport), owner: owner, personalScope: false)
        XCTAssertEqual(controller.mode, .legacy)
        XCTAssertNil(controller.snapshot)
    }

    func testSharedTeamAndUnverifiedIdentityCannotFetchPersonalWallet() async throws {
        for personal in [true, false] {
            let provider = SharedUsageFixtureProvider()
            let controller = SharedUsageController(provider: provider)
            controller.acceptPlan(.success(try SharedUsageFixtureProvider.plan()), owner: personal ? nil : owner, personalScope: personal)
            XCTAssertEqual(controller.mode, personal ? .unavailable : .unsupported)
            let success = await controller.refresh(cookieHeader: "fixture", owner: owner, isCurrent: { true })
            XCTAssertFalse(success)
            let calls = await provider.calls
            XCTAssertTrue(calls.isEmpty)
        }
    }
}

actor SharedUsageFixtureProvider: CursorSharedUsageFetching {
    var calls: [String] = []
    var planFailure: CursorSharedAPIError?
    var periodFailure: CursorSharedAPIError?
    var prepaidFailure: CursorSharedAPIError?
    var capFailure: CursorSharedAPIError?
    var planJSON: String?
    var prepaidJSON: String?
    var periodJSON: String?
    private var periodStarted: (@Sendable () -> Void)?
    private var heldPeriod: CheckedContinuation<CurrentPeriodUsageResponse, Error>?

    func holdNextPeriod(_ started: @escaping @Sendable () -> Void) { periodStarted = started }
    func finishHeldPeriod(error: CursorSharedAPIError?) {
        if let error { heldPeriod?.resume(throwing: error) }
        else { heldPeriod?.resume(returning: try! Self.period()) }
        heldPeriod = nil
    }
    nonisolated static func period() throws -> CurrentPeriodUsageResponse {
        try Self.decode(#"{"billingCycleStart":"2026-11-10T00:00:00Z","billingCycleEnd":"2026-11-17T00:00:00Z","planUsage":{"totalPercentUsed":25}}"#)
    }

    func setFailures(plan: CursorSharedAPIError? = nil, period: CursorSharedAPIError? = nil,
                     prepaid: CursorSharedAPIError? = nil, cap: CursorSharedAPIError? = nil) {
        planFailure = plan; periodFailure = period; prepaidFailure = prepaid; capFailure = cap
    }
    func setPlan(_ json: String) { planJSON = json }
    func setPrepaid(_ json: String) { prepaidJSON = json }
    func setPeriod(_ json: String) { periodJSON = json }
    func fetchPlanInfo(cookieHeader: String) async throws -> CursorPlanInfoResponse {
        calls.append("plan")
        if let planFailure { throw planFailure }
        return try planJSON.map { try Self.decode($0) } ?? Self.plan()
    }
    func fetchCurrentPeriod(cookieHeader: String) async throws -> CurrentPeriodUsageResponse {
        calls.append("period")
        if let periodFailure { throw periodFailure }
        if let started = periodStarted {
            periodStarted = nil
            return try await withCheckedThrowingContinuation { continuation in
                heldPeriod = continuation
                started()
            }
        }
        return try periodJSON.map { try Self.decode($0) } ?? Self.period()
    }
    func fetchPrepaid(cookieHeader: String) async throws -> CursorPrepaidBillingResponse {
        calls.append("prepaid")
        if let prepaidFailure { throw prepaidFailure }
        if let prepaidJSON { return try Self.decode(prepaidJSON) }
        return try Self.decode(#"{"billingMode":"PREPAID_BILLING_MODE_PREPAID","eligible":true,"availableCents":6200,"spentThisMonthCents":700}"#)
    }
    func fetchPaidCap(cookieHeader: String) async throws -> CursorPaidCapResponse {
        calls.append("cap")
        if let capFailure { throw capFailure }
        return try Self.decode(#"{"hardLimit":25}"#)
    }
    nonisolated static func plan(reset: Int64 = 1_794_873_600_000) throws -> CursorPlanInfoResponse {
        try decode("{\"isMerged\":true,\"planInfo\":{\"includedUsagePeriod\":\"INCLUDED_USAGE_PERIOD_WEEKLY\",\"includedUsageResetsAt\":\"\(reset)\"}}")
    }
    nonisolated static func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}
