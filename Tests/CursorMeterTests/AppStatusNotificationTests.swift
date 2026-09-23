import XCTest
@testable import CursorMeter

/// Tests for #83 app-status notifications: release-available and
/// refresh-failing decision logic, dedup, and settings persistence.
@MainActor
final class AppStatusNotificationTests: XCTestCase {

    nonisolated private static let enabledKey = "appStatusNotificationEnabled"
    nonisolated private static let lastNotifiedKey = "lastNotifiedUpdateVersion"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.enabledKey)
        UserDefaults.standard.removeObject(forKey: Self.lastNotifiedKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.enabledKey)
        UserDefaults.standard.removeObject(forKey: Self.lastNotifiedKey)
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    // MARK: - shouldNotifyUpdate

    func testShouldNotifyUpdateFiresForNewVersion() {
        XCTAssertTrue(UsageViewModel.shouldNotifyUpdate(version: "0.8.0", lastNotified: "0.7.1", enabled: true))
    }

    func testShouldNotifyUpdateFiresWhenNeverNotified() {
        XCTAssertTrue(UsageViewModel.shouldNotifyUpdate(version: "0.8.0", lastNotified: nil, enabled: true))
    }

    func testShouldNotifyUpdateSuppressedForSameVersion() {
        XCTAssertFalse(UsageViewModel.shouldNotifyUpdate(version: "0.8.0", lastNotified: "0.8.0", enabled: true))
    }

    func testShouldNotifyUpdateSuppressedWhenDisabled() {
        XCTAssertFalse(UsageViewModel.shouldNotifyUpdate(version: "0.8.0", lastNotified: nil, enabled: false))
    }

    // MARK: - shouldNotifyRefreshFailing

    func testShouldNotifyRefreshFailingFiresExactlyAtThreshold() {
        XCTAssertFalse(UsageViewModel.shouldNotifyRefreshFailing(failureCount: 4, enabled: true))
        XCTAssertTrue(UsageViewModel.shouldNotifyRefreshFailing(failureCount: 5, enabled: true))
        XCTAssertFalse(UsageViewModel.shouldNotifyRefreshFailing(failureCount: 6, enabled: true))
    }

    func testShouldNotifyRefreshFailingSuppressedWhenDisabled() {
        XCTAssertFalse(UsageViewModel.shouldNotifyRefreshFailing(failureCount: 5, enabled: false))
    }

    // MARK: - Helpers

    /// Bare view model with the startup update check stubbed off the network —
    /// the real check runs from `init` and could nondeterministically write
    /// `lastNotifiedUpdateVersion` mid-suite (test host version is "0.0.0").
    private func makeViewModel() -> UsageViewModel {
        let vm = UsageViewModel()
        vm.updateCheckRunner = { .upToDate }
        return vm
    }

    // MARK: - Settings persistence

    func testAppStatusNotificationDefaultsToEnabled() {
        let vm = makeViewModel()
        XCTAssertTrue(vm.appStatusNotificationEnabled)
    }

    func testSetAppStatusNotificationPersistsAndReloads() {
        let vm = makeViewModel()
        vm.setAppStatusNotificationEnabled(false)
        XCTAssertFalse(vm.appStatusNotificationEnabled)
        XCTAssertEqual(UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool, false)

        let reloaded = makeViewModel()
        XCTAssertFalse(reloaded.appStatusNotificationEnabled)
    }

    // MARK: - recordUpdateCheckResult funnel

    private static let release = UpdateChecker.Release(
        tagName: "v9.9.9",
        htmlURL: "https://github.com/WoojinAhn/CursorMeter/releases/tag/v9.9.9",
        version: "9.9.9"
    )

    func testAutomaticAvailableResultNotifiesOncePerVersion() async {
        let vm = makeViewModel()
        var notified: [(String, String)] = []
        vm.updateAvailableNotifier = { version, url in notified.append((version, url)) }

        await vm.recordUpdateCheckResult(.available(Self.release), source: .automatic)
        await vm.recordUpdateCheckResult(.available(Self.release), source: .automatic)

        XCTAssertEqual(notified.count, 1)
        XCTAssertEqual(notified.first?.0, "9.9.9")
        XCTAssertEqual(notified.first?.1, Self.release.htmlURL)
        XCTAssertEqual(vm.availableUpdate, Self.release)
        // Write-before-send: version persisted even though notifier is user code.
        XCTAssertEqual(
            UserDefaults.standard.string(forKey: Self.lastNotifiedKey), "9.9.9")
    }

    func testManualCheckRecordsButNeverNotifies() async {
        let vm = makeViewModel()
        var notifyCount = 0
        vm.updateAvailableNotifier = { _, _ in notifyCount += 1 }

        await vm.recordUpdateCheckResult(.available(Self.release), source: .manual)

        XCTAssertEqual(notifyCount, 0)
        XCTAssertEqual(vm.availableUpdate, Self.release)
        XCTAssertNil(UserDefaults.standard.string(forKey: Self.lastNotifiedKey))
    }

    func testDisabledToggleSuppressesUpdateNotification() async {
        let vm = makeViewModel()
        vm.setAppStatusNotificationEnabled(false)
        var notifyCount = 0
        vm.updateAvailableNotifier = { _, _ in notifyCount += 1 }

        await vm.recordUpdateCheckResult(.available(Self.release), source: .automatic)

        XCTAssertEqual(notifyCount, 0)
        XCTAssertNil(UserDefaults.standard.string(forKey: Self.lastNotifiedKey))
    }

    func testUpToDateAndFailedResultsNeverNotify() async {
        let vm = makeViewModel()
        var notifyCount = 0
        vm.updateAvailableNotifier = { _, _ in notifyCount += 1 }

        await vm.recordUpdateCheckResult(.upToDate, source: .automatic)
        await vm.recordUpdateCheckResult(.failed(reason: "offline"), source: .automatic)

        XCTAssertEqual(notifyCount, 0)
    }

    // MARK: - refresh-failing integration (MockURLProtocol)

    @MainActor final class Spy {
        var refreshFailingCount = 0
        var sessionExpiredCount = 0
    }

    private func makeFailingViewModel(spy: Spy) -> UsageViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let vm = UsageViewModel(
            apiClient: CursorAPIClient(configuration: config),
            refreshFeedback: RefreshFeedback(timing: .immediate)
        )
        vm.updateCheckRunner = { .upToDate }
        vm.keychainDeleteHandler = {}
        vm.sessionExpiredNotifier = { spy.sessionExpiredCount += 1 }
        vm.refreshFailingNotifier = { spy.refreshFailingCount += 1 }
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

    func testRefreshFailingNotifiesExactlyOnceAtThreshold() async {
        let spy = Spy()
        let vm = makeFailingViewModel(spy: spy)
        MockURLProtocol.requestHandler = Self.serverErrorHandler

        for _ in 0..<4 {
            await vm.refresh()
        }
        XCTAssertEqual(spy.refreshFailingCount, 0)

        await vm.refresh()  // 5th failure — the transition
        XCTAssertEqual(spy.refreshFailingCount, 1)

        await vm.refresh()  // 6th failure — no re-fire
        XCTAssertEqual(spy.refreshFailingCount, 1)
        XCTAssertEqual(spy.sessionExpiredCount, 0)
    }

    func testUnauthorizedPathFiresOnlySessionExpiredNotifier() async {
        let spy = Spy()
        let vm = makeFailingViewModel(spy: spy)
        MockURLProtocol.requestHandler = { request in
            let unauthorized = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (unauthorized, Data())
        }

        await vm.refresh()

        XCTAssertEqual(spy.sessionExpiredCount, 1)
        XCTAssertEqual(spy.refreshFailingCount, 0)
    }

    func testDisabledToggleSuppressesRefreshFailingNotification() async {
        let spy = Spy()
        let vm = makeFailingViewModel(spy: spy)
        vm.setAppStatusNotificationEnabled(false)
        MockURLProtocol.requestHandler = Self.serverErrorHandler

        for _ in 0..<6 {
            await vm.refresh()
        }
        XCTAssertEqual(spy.refreshFailingCount, 0)
    }

    func testRecoveryReArmsRefreshFailingNotification() async {
        let spy = Spy()
        let vm = makeFailingViewModel(spy: spy)

        MockURLProtocol.requestHandler = Self.serverErrorHandler
        for _ in 0..<5 { await vm.refresh() }
        XCTAssertEqual(spy.refreshFailingCount, 1)

        MockURLProtocol.requestHandler = Self.successHandler
        await vm.refresh()  // success resets the counter

        MockURLProtocol.requestHandler = Self.serverErrorHandler
        for _ in 0..<5 { await vm.refresh() }
        XCTAssertEqual(spy.refreshFailingCount, 2)
    }
}
