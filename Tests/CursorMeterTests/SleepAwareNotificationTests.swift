import XCTest
@testable import CursorMeter

/// Tests for #112 sleep-aware refresh-failing notifications: failures that
/// occur while the display is asleep (system sleep / dark wake) must not
/// advance the notification counter — only awake failures count toward the
/// notify-at-5 edge. The stale indicator (`consecutiveFailureCount`) keeps
/// counting every failure regardless. A successful refresh resets both
/// counters and withdraws any delivered banner.
///
/// NOTE: `MockURLProtocol.requestHandler` is a single global — keep handlers
/// STATELESS (pure routing on url.path). Swapping the handler BETWEEN
/// `refresh()` calls (not from inside a handler) is fine.
@MainActor
final class SleepAwareNotificationTests: XCTestCase {

    @MainActor final class Spy {
        var refreshFailingCount = 0
        var withdrawCount = 0
        var displayAsleep = false
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeViewModel(spy: Spy) -> UsageViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let vm = UsageViewModel(apiClient: CursorAPIClient(configuration: config))
        vm.updateCheckRunner = { .upToDate }
        vm.keychainDeleteHandler = {}
        vm.sessionExpiredNotifier = {}  // UNUserNotificationCenter crashes in SPM tests
        vm.refreshFailingNotifier = { spy.refreshFailingCount += 1 }
        vm.refreshFailingWithdrawer = { spy.withdrawCount += 1 }
        vm.displayAsleepChecker = { spy.displayAsleep }
        vm.testHook_setCookieHeader("WorkosCursorSessionToken=test")
        vm.authState = .loggedIn
        return vm
    }

    private static let serverErrorHandler: (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
        let serverError = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
        return (serverError, Data("oops".utf8))
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

    /// 1. The #112 incident: every failure lands while asleep → no banner,
    /// no matter how far past the threshold the failures run.
    func test_asleepFailures_neverFireNotification() async {
        let spy = Spy()
        let vm = makeViewModel(spy: spy)
        spy.displayAsleep = true
        MockURLProtocol.requestHandler = Self.serverErrorHandler

        for _ in 0..<(UsageViewModel.staleThreshold + 2) {
            await vm.refresh()
        }

        XCTAssertEqual(spy.refreshFailingCount, 0)
    }

    /// 2. Asleep failures still drive the stale indicator — the truthful
    /// staleness counter is untouched by sleep gating.
    func test_asleepFailures_stillDriveStaleIndicator() async {
        let spy = Spy()
        let vm = makeViewModel(spy: spy)

        MockURLProtocol.requestHandler = Self.successHandler
        await vm.refresh()
        XCTAssertNotNil(vm.usageData)

        spy.displayAsleep = true
        MockURLProtocol.requestHandler = Self.serverErrorHandler
        for _ in 0..<UsageViewModel.staleThreshold {
            await vm.refresh()
        }

        XCTAssertTrue(vm.isDataStale)
        XCTAssertEqual(vm.consecutiveFailureCount, UsageViewModel.staleThreshold)
        XCTAssertEqual(spy.refreshFailingCount, 0)
    }

    /// 3. Outage spanning sleep: 2 awake + 3 asleep + 3 awake failures →
    /// fires exactly once, on the 5th *awake* failure (notify-once preserved).
    func test_sleepSpanningOutage_firesOnFifthAwakeFailure() async {
        let spy = Spy()
        let vm = makeViewModel(spy: spy)
        MockURLProtocol.requestHandler = Self.serverErrorHandler

        for _ in 0..<2 { await vm.refresh() }          // awake: 1, 2
        spy.displayAsleep = true
        for _ in 0..<3 { await vm.refresh() }          // asleep: ignored
        spy.displayAsleep = false
        for _ in 0..<2 { await vm.refresh() }          // awake: 3, 4
        XCTAssertEqual(spy.refreshFailingCount, 0)

        await vm.refresh()                             // awake: 5 — the edge
        XCTAssertEqual(spy.refreshFailingCount, 1)

        await vm.refresh()                             // awake: 6 — no re-fire
        XCTAssertEqual(spy.refreshFailingCount, 1)
    }

    /// 4. A single transient failure right after wake (Wi-Fi not yet
    /// re-associated) stays silent even though the stale counter is far past
    /// the threshold from the sleep stretch.
    func test_singleAwakeFailureAfterSleep_staysSilent() async {
        let spy = Spy()
        let vm = makeViewModel(spy: spy)
        spy.displayAsleep = true
        MockURLProtocol.requestHandler = Self.serverErrorHandler
        for _ in 0..<UsageViewModel.staleThreshold { await vm.refresh() }

        spy.displayAsleep = false
        await vm.refresh()

        XCTAssertEqual(spy.refreshFailingCount, 0)
        XCTAssertEqual(vm.consecutiveFailureCount, UsageViewModel.staleThreshold + 1)
    }

    /// 5. Success resets the notification counter and re-arms: a second full
    /// outage after recovery notifies again.
    func test_successResets_andRearmsForNextOutage() async {
        let spy = Spy()
        let vm = makeViewModel(spy: spy)
        MockURLProtocol.requestHandler = Self.serverErrorHandler
        for _ in 0..<UsageViewModel.staleThreshold { await vm.refresh() }
        XCTAssertEqual(spy.refreshFailingCount, 1)

        MockURLProtocol.requestHandler = Self.successHandler
        await vm.refresh()

        MockURLProtocol.requestHandler = Self.serverErrorHandler
        for _ in 0..<UsageViewModel.staleThreshold { await vm.refresh() }
        XCTAssertEqual(spy.refreshFailingCount, 2)
    }

    /// 6. Success withdraws any delivered banner (C in #112). The withdrawer
    /// is idempotent at the UNUserNotificationCenter layer, so it runs on
    /// every success — asserting ≥1 after recovery is the contract.
    func test_success_withdrawsDeliveredBanner() async {
        let spy = Spy()
        let vm = makeViewModel(spy: spy)
        MockURLProtocol.requestHandler = Self.serverErrorHandler
        for _ in 0..<UsageViewModel.staleThreshold { await vm.refresh() }
        XCTAssertEqual(spy.withdrawCount, 0)

        MockURLProtocol.requestHandler = Self.successHandler
        await vm.refresh()

        XCTAssertGreaterThanOrEqual(spy.withdrawCount, 1)
    }
}
