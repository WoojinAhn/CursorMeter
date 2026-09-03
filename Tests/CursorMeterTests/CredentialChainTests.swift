import XCTest
@testable import CursorMeter

/// #54 credential chain: IDE-first resolution, 401 fallthrough to the captured
/// cookie, all-sources-exhausted expiry, and activeAuthSource reporting.
@MainActor
final class CredentialChainTests: XCTestCase {

    nonisolated private static let suppressedKey = "ideAuthSuppressed"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.suppressedKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.suppressedKey)
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeViewModel() -> UsageViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let vm = UsageViewModel(apiClient: CursorAPIClient(configuration: config))
        vm.updateCheckRunner = { .upToDate }
        vm.keychainDeleteHandler = {}
        vm.sessionExpiredNotifier = {}
        vm.refreshFailingNotifier = {}
        return vm
    }

    private nonisolated static let ideCredential = IDECredential(
        cookieHeader: "WorkosCursorSessionToken=user_ide%3A%3AJ.W.T",
        expiresAt: Date().addingTimeInterval(3600)
    )

    /// 200 for every endpoint; captures the Cookie header of each request.
    private static func successHandler(
        seenCookies: @escaping @Sendable (String?) -> Void
    ) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            seenCookies(request.value(forHTTPHeaderField: "Cookie"))
            let url = request.url!
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            switch url.path {
            case "/api/usage-summary":
                let json = """
                {"billingCycleStart":"2026-07-01T00:00:00.000Z","billingCycleEnd":"2026-08-01T00:00:00.000Z",
                 "membershipType":"pro","limitType":"user","isUnlimited":false,
                 "individualUsage":{"plan":{"enabled":true,"used":8,"limit":2000,"remaining":1992,"totalPercentUsed":0.1}}}
                """
                return (ok, Data(json.utf8))
            case "/api/auth/me":
                return (ok, Data("{\"email\":\"t@t.com\",\"name\":\"T\"}".utf8))
            case "/api/usage":
                return (ok, Data("{\"startOfMonth\":\"2026-07-01T00:00:00.000Z\"}".utf8))
            default:
                return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
            }
        }
    }

    private static let unauthorizedHandler: (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
        (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
    }

    // MARK: - Chain resolution

    func testIDECredentialUsedWhenAvailable() async {
        let vm = makeViewModel()
        vm.ideCredentialProvider = { Self.ideCredential }
        let box = CookieBox()
        MockURLProtocol.requestHandler = Self.successHandler { box.append($0) }

        await vm.refresh()

        XCTAssertEqual(vm.activeAuthSource, .cursorIDE)
        XCTAssertEqual(vm.authState, .loggedIn)
        XCTAssertNotNil(vm.usageData)
        XCTAssertTrue(box.all.allSatisfy { $0 == Self.ideCredential.cookieHeader })
    }

    func testNoIDEFallsBackToCapturedCookie() async {
        let vm = makeViewModel()  // provider nil
        vm.testHook_setCookieHeader("WorkosCursorSessionToken=captured")
        vm.authState = .loggedIn
        let box = CookieBox()
        MockURLProtocol.requestHandler = Self.successHandler { box.append($0) }

        await vm.refresh()

        XCTAssertEqual(vm.activeAuthSource, .browserLogin)
        XCTAssertTrue(box.all.allSatisfy { $0 == "WorkosCursorSessionToken=captured" })
    }

    func testNeitherSourceMeansLoginRequiredWithoutNetwork() async {
        let vm = makeViewModel()
        let box = CookieBox()
        MockURLProtocol.requestHandler = Self.successHandler { box.append($0) }

        await vm.refresh()

        XCTAssertEqual(vm.authState, .loggedOut, "never authenticated — Not connected, not Session expired")
        XCTAssertNil(vm.activeAuthSource)
        XCTAssertTrue(box.all.isEmpty, "no API call without any credential")
    }

    // MARK: - 401 fallthrough

    func testIDE401FallsThroughToCapturedCookieWithinOneRefresh() async {
        let vm = makeViewModel()
        vm.ideCredentialProvider = { Self.ideCredential }
        vm.testHook_setCookieHeader("WorkosCursorSessionToken=captured")
        vm.authState = .loggedIn
        var keychainDeletes = 0
        vm.keychainDeleteHandler = { keychainDeletes += 1 }
        let box = CookieBox()
        // 401 for the IDE cookie, 200 for the captured one.
        let success = Self.successHandler { box.append($0) }
        MockURLProtocol.requestHandler = { request in
            if request.value(forHTTPHeaderField: "Cookie") == Self.ideCredential.cookieHeader {
                return try Self.unauthorizedHandler(request)
            }
            return try success(request)
        }

        await vm.refresh()

        XCTAssertEqual(vm.activeAuthSource, .browserLogin, "fell back within one refresh")
        XCTAssertEqual(vm.authState, .loggedIn)
        XCTAssertEqual(keychainDeletes, 0, "IDE 401 must not delete the captured cookie")
        XCTAssertNotNil(vm.usageData)
    }

    func testAllSources401RunsExpiryFlowOnce() async {
        let vm = makeViewModel()
        vm.ideCredentialProvider = { Self.ideCredential }
        vm.testHook_setCookieHeader("WorkosCursorSessionToken=captured")
        vm.authState = .loggedIn
        var expiredNotifications = 0
        vm.sessionExpiredNotifier = { expiredNotifications += 1 }
        MockURLProtocol.requestHandler = Self.unauthorizedHandler

        await vm.refresh()

        XCTAssertEqual(vm.authState, .loginRequired)
        XCTAssertNil(vm.activeAuthSource)
        XCTAssertEqual(expiredNotifications, 1, "single expiry flow for the whole chain")
    }

    // MARK: - Logout suppression / connect / account switch (#54 Task 4)

    /// successHandler variant with a parameterized auth/me email.
    private static func emailHandler(_ email: String) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        let base = successHandler { _ in }
        return { request in
            if request.url!.path == "/api/auth/me" {
                let ok = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (ok, Data("{\"email\":\"\(email)\",\"name\":\"T\"}".utf8))
            }
            return try base(request)
        }
    }

    func testLogoutSuppressesIDESource() async {
        let vm = makeViewModel()
        vm.ideCredentialProvider = { Self.ideCredential }
        let box = CookieBox()
        MockURLProtocol.requestHandler = Self.successHandler { box.append($0) }

        await vm.refresh()
        XCTAssertEqual(vm.authState, .loggedIn)

        vm.logout()
        XCTAssertTrue(vm.ideAuthSuppressed)
        XCTAssertEqual(vm.authState, .loggedOut)
        XCTAssertNil(vm.activeAuthSource)

        let callsBefore = box.all.count
        await vm.refresh()
        XCTAssertEqual(vm.authState, .loggedOut, "suppressed IDE + no cookie + no prior session = Not connected")
        XCTAssertEqual(box.all.count, callsBefore, "no API call while suppressed")
    }

    func testConnectViaIDEClearsSuppressionAndRefreshes() async {
        let vm = makeViewModel()
        vm.ideCredentialProvider = { Self.ideCredential }
        MockURLProtocol.requestHandler = Self.successHandler { _ in }

        vm.logout()
        vm.connectViaIDE()
        XCTAssertFalse(vm.ideAuthSuppressed)
        vm.stopAutoRefreshForTests()
        await vm.refresh()
        XCTAssertEqual(vm.activeAuthSource, .cursorIDE)
    }

    func testBrowserLoginClearsSuppression() {
        let vm = makeViewModel()
        MockURLProtocol.requestHandler = Self.successHandler { _ in }
        vm.logout()
        XCTAssertTrue(vm.ideAuthSuppressed)
        vm.onLoginSuccess(cookieHeader: "WorkosCursorSessionToken=fresh")
        XCTAssertFalse(vm.ideAuthSuppressed, "explicit reconnect intent clears suppression")
    }

    /// GitHub-linked IDE sessions 404 `/api/auth/me` ("User not found: '<numeric>'")
    /// while usage-summary still returns 200. Identity must not fail the refresh.
    func testAuthMe404DoesNotFailRefreshWhenSummarySucceeds() async {
        let vm = makeViewModel()
        vm.ideCredentialProvider = { Self.ideCredential }
        MockURLProtocol.requestHandler = Self.authMe404Handler()

        await vm.refresh()

        XCTAssertEqual(vm.authState, .loggedIn)
        XCTAssertEqual(vm.activeAuthSource, .cursorIDE)
        XCTAssertNotNil(vm.usageData)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.usageData?.email, "Unknown")
    }

    func testAuthMe404UsesIdentityFallbackForDisplay() async {
        let vm = makeViewModel()
        vm.ideCredentialProvider = {
            IDECredential(
                cookieHeader: Self.ideCredential.cookieHeader,
                expiresAt: Self.ideCredential.expiresAt,
                email: "fallback@t.com",
                name: "Fallback"
            )
        }
        MockURLProtocol.requestHandler = Self.authMe404Handler()

        await vm.refresh()

        XCTAssertEqual(vm.usageData?.email, "fallback@t.com")
        XCTAssertEqual(vm.usageData?.name, "Fallback")
        XCTAssertNil(vm.errorMessage)
    }

    /// When identity AND both usage endpoints fail, the identity 404 still surfaces.
    func testAuthMe404SurfacesWhenUsageAlsoFails() async {
        let vm = makeViewModel()
        vm.ideCredentialProvider = { Self.ideCredential }
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            return (
                HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data("not found".utf8)
            )
        }

        await vm.refresh()

        XCTAssertNil(vm.usageData)
        XCTAssertEqual(vm.errorMessage, "Server error (404)")
    }

    private static func authMe404Handler() -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        let base = successHandler { _ in }
        return { request in
            if request.url!.path == "/api/auth/me" {
                let notFound = HTTPURLResponse(
                    url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (notFound, Data("Failed to handle profile: User not found".utf8))
            }
            return try base(request)
        }
    }

    func testAccountSwitchResetsPerAccountState() async {
        let vm = makeViewModel()
        vm.ideCredentialProvider = { Self.ideCredential }
        MockURLProtocol.requestHandler = Self.emailHandler("alice@t.com")
        await vm.refresh()
        XCTAssertEqual(vm.usageData?.email, "alice@t.com")
        vm.testHook_seedWeeklyData([DayUsage(date: Date(), requests: 1, isToday: true, isOnDemand: false, onDemandCents: 0, totalChargedCents: 0)])

        MockURLProtocol.requestHandler = Self.emailHandler("bob@t.com")
        await vm.refresh()
        XCTAssertEqual(vm.usageData?.email, "bob@t.com")
        XCTAssertNil(vm.weeklyData, "per-account state reset on account switch")
    }
}

/// Reference box so the @Sendable capture-handler can accumulate cookies.
final class CookieBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String?] = []
    func append(_ v: String?) { lock.lock(); storage.append(v); lock.unlock() }
    var all: [String?] { lock.lock(); defer { lock.unlock() }; return storage }
}
