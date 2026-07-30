import XCTest
@testable import CursorMeter

final class UsageViewModelTests: XCTestCase {
    // MARK: - fallbackErrorMessage(for:)

    func testFallbackMessageForURLErrorTimedOut() {
        let error = URLError(.timedOut)
        XCTAssertEqual(UsageViewModel.fallbackErrorMessage(for: error), "Request timed out")
    }

    func testFallbackMessageForOtherURLError() {
        let error = URLError(.cannotFindHost)
        XCTAssertEqual(UsageViewModel.fallbackErrorMessage(for: error), "Network error")
    }

    func testFallbackMessageForDecodingError() {
        let error = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))
        XCTAssertEqual(UsageViewModel.fallbackErrorMessage(for: error), "Failed to read usage data")
    }

    func testFallbackMessageForAPIHttpError() {
        XCTAssertEqual(UsageViewModel.fallbackErrorMessage(for: APIError.httpError(statusCode: 500)), "Server error (500)")
        XCTAssertEqual(UsageViewModel.fallbackErrorMessage(for: APIError.httpError(statusCode: 502)), "Server error (502)")
    }

    func testFallbackMessageForAPINetworkErrorWithTimeout() {
        let error = APIError.networkError(URLError(.timedOut))
        XCTAssertEqual(UsageViewModel.fallbackErrorMessage(for: error), "Request timed out")
    }

    func testFallbackMessageForAPINetworkErrorWithOtherURLError() {
        let error = APIError.networkError(URLError(.cannotConnectToHost))
        XCTAssertEqual(UsageViewModel.fallbackErrorMessage(for: error), "Network error")
    }

    func testFallbackMessageForUnknownError() {
        struct CustomError: Error {}
        XCTAssertEqual(UsageViewModel.fallbackErrorMessage(for: CustomError()), "Unexpected error")
    }

    /// Ensures the message never leaks raw error detail (URLs, debug strings).
    func testFallbackMessageDoesNotLeakRawDetail() {
        let url = URL(string: "https://cursor.com/api/usage-summary")!
        let urlError = URLError(.timedOut, userInfo: [NSURLErrorFailingURLErrorKey: url])
        let message = UsageViewModel.fallbackErrorMessage(for: urlError)
        XCTAssertFalse(message.contains("cursor.com"))
        XCTAssertFalse(message.contains("api/usage"))
    }

    // MARK: - hasUnauthorized (#76)

    func testHasUnauthorizedTrueWhenAnyErrorIsUnauthorized() {
        let decodeError = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))
        XCTAssertTrue(UsageViewModel.hasUnauthorized([decodeError, APIError.unauthorized, nil]))
    }

    func testHasUnauthorizedFalseForOtherFailures() {
        let decodeError = DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad"))
        XCTAssertFalse(UsageViewModel.hasUnauthorized([decodeError, APIError.forbidden, nil]))
    }

    func testHasUnauthorizedFalseWhenAllNil() {
        XCTAssertFalse(UsageViewModel.hasUnauthorized([nil, nil, nil]))
    }

    func testHasUnauthorizedTrueWithMixedNonAPIErrors() {
        XCTAssertTrue(UsageViewModel.hasUnauthorized([URLError(.timedOut), APIError.unauthorized]))
    }

    // MARK: - shouldRecheckUpdate (#80)

    func testShouldRecheckUpdateWhenNeverChecked() {
        XCTAssertTrue(UsageViewModel.shouldRecheckUpdate(lastCheck: nil, now: Date()))
    }

    func testShouldRecheckUpdateAfterInterval() {
        let now = Date(timeIntervalSince1970: 200_000)
        let old = now.addingTimeInterval(-(UsageViewModel.updateRecheckInterval + 1))
        XCTAssertTrue(UsageViewModel.shouldRecheckUpdate(lastCheck: old, now: now))
    }

    func testShouldNotRecheckUpdateWithinInterval() {
        let now = Date(timeIntervalSince1970: 200_000)
        let recent = now.addingTimeInterval(-3_600)
        XCTAssertFalse(UsageViewModel.shouldRecheckUpdate(lastCheck: recent, now: now))
    }

    func testShouldRecheckUpdateWhenClockRolledBack() {
        let now = Date(timeIntervalSince1970: 200_000)
        let future = now.addingTimeInterval(3_600)
        XCTAssertTrue(UsageViewModel.shouldRecheckUpdate(lastCheck: future, now: now))
    }

    // MARK: - On-demand latch

    @MainActor
    func test_latch_activatesWhenQuotaExhausted() async {
        let vm = UsageViewModel()
        let base = makeFixture(
            requestsUsed: 600, requestsLimit: 500,
            onDemandUsedCents: 100, onDemandLimitCents: 4000, onDemandEnabled: true,
            isOnDemandActive: false)
        vm.testHook_applyLatch(base: base)
        XCTAssertEqual(vm.usageData?.isOnDemandActive, true)
    }

    @MainActor
    func test_latch_doesNotActivate_belowQuota() async {
        let vm = UsageViewModel()
        let base = makeFixture(
            requestsUsed: 400, requestsLimit: 500,
            onDemandUsedCents: 0, onDemandLimitCents: 4000, onDemandEnabled: true,
            isOnDemandActive: false)
        vm.testHook_applyLatch(base: base)
        XCTAssertEqual(vm.usageData?.isOnDemandActive, false)
    }

    @MainActor
    func test_latch_oscillationGuard_doesNotResetNotifications() async {
        let vm = UsageViewModel()
        // First: cross the threshold → latched + reset
        let over = makeFixture(
            requestsUsed: 600, requestsLimit: 500,
            onDemandUsedCents: 100, onDemandLimitCents: 4000, onDemandEnabled: true)
        vm.testHook_applyLatch(base: over)
        // Seed notification dedup as if 80/90 had fired
        vm.testHook_setNotifiedThresholds([80, 90])
        // Second refresh: API jitter shows below quota
        let jitter = makeFixture(
            requestsUsed: 480, requestsLimit: 500,
            onDemandUsedCents: 100, onDemandLimitCents: 4000, onDemandEnabled: true)
        vm.testHook_applyLatch(base: jitter)
        // Latch stays true (no re-fire); notifiedThresholds unchanged
        XCTAssertEqual(vm.usageData?.isOnDemandActive, true)
        XCTAssertEqual(vm.testHook_notifiedThresholds(), [80, 90])
    }

    @MainActor
    func test_latch_resetsOnLogout() async {
        let vm = UsageViewModel()
        vm.keychainDeleteHandler = {}  // #82: logout() must not touch the real Keychain
        let base = makeFixture(
            requestsUsed: 600, requestsLimit: 500,
            onDemandUsedCents: 100, onDemandLimitCents: 4000, onDemandEnabled: true)
        vm.testHook_applyLatch(base: base)
        XCTAssertEqual(vm.usageData?.isOnDemandActive, true)

        vm.logout()

        // Re-apply a below-quota fixture; latch must NOT carry over
        let fresh = makeFixture(
            requestsUsed: 50, requestsLimit: 500,
            onDemandUsedCents: 0, onDemandLimitCents: 4000, onDemandEnabled: true)
        vm.testHook_applyLatch(base: fresh)
        XCTAssertEqual(vm.usageData?.isOnDemandActive, false)
    }

    @MainActor
    func test_latch_rolloverIntoFreshCycle_immediatelyUnlatches() async {
        let vm = UsageViewModel()
        let cycle1 = Date(timeIntervalSince1970: 1_700_000_000)
        let cycle2 = Date(timeIntervalSince1970: 1_702_678_400)

        // Cycle 1: latched
        let over1 = makeFixture(
            requestsUsed: 600, requestsLimit: 500,
            onDemandUsedCents: 100, onDemandLimitCents: 4000, onDemandEnabled: true,
            cycleStartDate: cycle1)
        vm.testHook_applyLatchAndRollover(base: over1)
        XCTAssertEqual(vm.usageData?.isOnDemandActive, true, "should latch in cycle 1")

        // Cycle 2: new cycle, FRESH data (under quota). Must unlatch on THIS refresh.
        let fresh = makeFixture(
            requestsUsed: 50, requestsLimit: 500,
            onDemandUsedCents: 0, onDemandLimitCents: 4000, onDemandEnabled: true,
            cycleStartDate: cycle2)
        vm.testHook_applyLatchAndRollover(base: fresh)
        XCTAssertEqual(vm.usageData?.isOnDemandActive, false, "must unlatch immediately, not after 1 refresh")
    }
}

// MARK: - Test fixture

private func makeFixture(
    email: String = "test@test.com",
    name: String = "Test",
    membershipType: String? = nil,
    planUsedCents: Int? = nil,
    planLimitCents: Int? = nil,
    serverPercentUsed: Double? = nil,
    requestsUsed: Int = 0,
    requestsLimit: Int = 0,
    onDemandUsedCents: Int? = nil,
    onDemandLimitCents: Int? = nil,
    onDemandEnabled: Bool? = nil,
    isOnDemandActive: Bool = false,
    cycleStartDate: Date? = nil,
    resetDate: Date? = nil,
) -> UsageDisplayData {
    UsageDisplayData(
        email: email,
        name: name,
        membershipType: membershipType,
        planUsedCents: planUsedCents,
        planLimitCents: planLimitCents,
        serverPercentUsed: serverPercentUsed,
        requestsUsed: requestsUsed,
        requestsLimit: requestsLimit,
        onDemandUsedCents: onDemandUsedCents,
        onDemandLimitCents: onDemandLimitCents,
        onDemandEnabled: onDemandEnabled,
        isOnDemandActive: isOnDemandActive,
        cycleStartDate: cycleStartDate,
        resetDate: resetDate
    )
}
