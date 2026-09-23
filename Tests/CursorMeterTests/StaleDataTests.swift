import XCTest
@testable import CursorMeter

/// Tests for the #77 stale-data indicator: after `staleThreshold` consecutive
/// refresh failures (any reason except session expiry), `isDataStale` should
/// flag the cached data as stale so the popover can surface a warning line.
///
/// NOTE: `MockURLProtocol.requestHandler` is a single global — keep handlers
/// STATELESS (pure routing on url.path). Swapping the handler BETWEEN
/// `refresh()` calls (not from inside a handler) is fine.
@MainActor
final class StaleDataTests: XCTestCase {

    @MainActor final class StaleSpy {
        var notifyCount = 0
        var keychainDeleteCount = 0
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeViewModel(spy: StaleSpy) -> UsageViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let vm = UsageViewModel(
            apiClient: CursorAPIClient(configuration: config),
            refreshFeedback: RefreshFeedback(timing: .immediate)
        )
        vm.keychainDeleteHandler = { spy.keychainDeleteCount += 1 }
        vm.sessionExpiredNotifier = { spy.notifyCount += 1 }  // UNUserNotificationCenter crashes in SPM tests
        vm.testHook_setCookieHeader("WorkosCursorSessionToken=test")
        vm.authState = .loggedIn
        return vm
    }

    /// Low percent-used summary fixture (borrowed from
    /// `CursorAPIClientTests.testFetchUsageSummarySuccess`) — keeps percent
    /// used LOW so no threshold notification fires (UNUserNotificationCenter
    /// crashes in the SPM test host).
    private static let successHandler: (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
        let url = request.url!
        let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        switch url.path {
        case "/api/usage-summary":
            let json = """
            {
                "billingCycleStart": "2026-03-01T07:29:44.000Z",
                "billingCycleEnd": "2026-04-01T07:29:44.000Z",
                "membershipType": "enterprise",
                "limitType": "team",
                "isUnlimited": false,
                "individualUsage": {
                    "plan": { "enabled": true, "used": 8, "limit": 2000, "remaining": 1992, "totalPercentUsed": 0.1 },
                    "onDemand": { "enabled": true, "used": 0, "limit": 2000, "remaining": 2000 }
                },
                "teamUsage": {
                    "onDemand": { "enabled": true, "used": 0, "limit": 120000, "remaining": 120000 }
                }
            }
            """
            return (ok, Data(json.utf8))
        case "/api/auth/me":
            return (ok, Data("{\"email\":\"t@t.com\",\"name\":\"T\"}".utf8))
        case "/api/usage":
            return (ok, Data("{\"startOfMonth\":\"2026-07-01T00:00:00.000Z\"}".utf8))
        default:
            let serverError = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (serverError, Data("oops".utf8))
        }
    }

    private static let serverErrorHandler: (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
        let serverError = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
        return (serverError, Data("oops".utf8))
    }

    private static let unauthorizedHandler: (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
        let unauthorized = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        return (unauthorized, Data())
    }

    /// 1. Success then `staleThreshold` consecutive 500-failures → stale.
    func test_refresh_successThenThresholdFailures_marksStale() async {
        let spy = StaleSpy()
        let vm = makeViewModel(spy: spy)

        MockURLProtocol.requestHandler = Self.successHandler
        await vm.refresh()
        XCTAssertNotNil(vm.usageData)
        XCTAssertFalse(vm.isDataStale)

        MockURLProtocol.requestHandler = Self.serverErrorHandler
        for _ in 0..<UsageViewModel.staleThreshold {
            await vm.refresh()
        }

        XCTAssertTrue(vm.isDataStale)
        XCTAssertNotNil(vm.usageData)
        XCTAssertEqual(vm.consecutiveFailureCount, UsageViewModel.staleThreshold)
    }

    /// 2. One fewer failure than the threshold → not yet stale.
    func test_refresh_oneFewerThanThreshold_notYetStale() async {
        let spy = StaleSpy()
        let vm = makeViewModel(spy: spy)

        MockURLProtocol.requestHandler = Self.successHandler
        await vm.refresh()

        MockURLProtocol.requestHandler = Self.serverErrorHandler
        for _ in 0..<(UsageViewModel.staleThreshold - 1) {
            await vm.refresh()
        }

        XCTAssertFalse(vm.isDataStale)
        XCTAssertEqual(vm.consecutiveFailureCount, UsageViewModel.staleThreshold - 1)
    }

    /// 3. Stale, then one successful refresh → no longer stale, counter reset,
    /// `lastSuccessAt` updated.
    func test_refresh_recoveryAfterStale_clearsStaleState() async {
        let spy = StaleSpy()
        let vm = makeViewModel(spy: spy)

        MockURLProtocol.requestHandler = Self.successHandler
        await vm.refresh()

        MockURLProtocol.requestHandler = Self.serverErrorHandler
        for _ in 0..<UsageViewModel.staleThreshold {
            await vm.refresh()
        }
        XCTAssertTrue(vm.isDataStale)
        let beforeRecovery = vm.lastSuccessAt

        MockURLProtocol.requestHandler = Self.successHandler
        await vm.refresh()

        XCTAssertFalse(vm.isDataStale)
        XCTAssertEqual(vm.consecutiveFailureCount, 0)
        XCTAssertNotNil(vm.lastSuccessAt)
        if let before = beforeRecovery, let after = vm.lastSuccessAt {
            XCTAssertGreaterThanOrEqual(after, before)
        }
    }

    /// 4. Failures without any prior success → never stale (no cached data to flag).
    func test_refresh_failuresWithoutPriorSuccess_neverStale() async {
        let spy = StaleSpy()
        let vm = makeViewModel(spy: spy)

        MockURLProtocol.requestHandler = Self.serverErrorHandler
        for _ in 0..<(UsageViewModel.staleThreshold + 3) {
            await vm.refresh()
        }

        XCTAssertNil(vm.usageData)
        XCTAssertFalse(vm.isDataStale)
    }

    /// 5. Unauthorized logout path resets the counter — an expired session
    /// must not leak stale state into the next login.
    func test_refresh_unauthorizedLogout_resetsFailureCounter() async {
        let spy = StaleSpy()
        let vm = makeViewModel(spy: spy)

        MockURLProtocol.requestHandler = Self.successHandler
        await vm.refresh()

        MockURLProtocol.requestHandler = Self.unauthorizedHandler
        await vm.refresh()

        XCTAssertEqual(vm.authState, .loginRequired)
        XCTAssertEqual(vm.consecutiveFailureCount, 0)
        XCTAssertFalse(vm.isDataStale)
    }
}
