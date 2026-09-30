import XCTest
@testable import CursorMeter

@MainActor
final class Profile404MitigationTests: XCTestCase {
    nonisolated private static let ideCookie = "WorkosCursorSessionToken=user_fixture%3A%3Aide-one"
    nonisolated private static let browserCookie = "WorkosCursorSessionToken=browser-fixture"
    nonisolated private static let credit = #"{"membershipType":"pro","individualUsage":{"plan":{"used":20,"limit":2000}}}"#
    nonisolated private static let split = #"{"membershipType":"ultra","individualUsage":{"plan":{"limit":40000,"autoPercentUsed":1,"apiPercentUsed":23}}}"#
    nonisolated private static let profile = #"{"name":"Example","email":"example@example.test","sub":"fixture-subject"}"#

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "ideAuthSuppressed")
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        UserDefaults.standard.removeObject(forKey: "ideAuthSuppressed")
        super.tearDown()
    }

    private func viewModel(recent: RecentUsageController? = nil,
                           manager: NotificationManager? = nil,
                           alertStore: SplitUsageAlertStore? = nil) -> UsageViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let vm = UsageViewModel(apiClient: CursorAPIClient(configuration: config), recentUsage: recent,
            refreshFeedback: RefreshFeedback(timing: .immediate),
            notificationManager: manager ?? NotificationManager(requestAuthorization: { false }, deliver: { _ in }),
            splitUsage: SplitUsageController(), splitAlertStore: alertStore)
        vm.ideCredentialProvider = { IDECredential(cookieHeader: Self.ideCookie, expiresAt: .distantFuture) }
        vm.authState = .loggedIn
        vm.notificationEnabled = false
        vm.updateCheckRunner = { .upToDate }
        vm.keychainDeleteHandler = {}
        vm.sessionExpiredNotifier = {}
        vm.refreshFailingNotifier = {}
        return vm
    }

    private nonisolated static func response(_ request: URLRequest, status: Int, body: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }

    private static func handler(profileStatus: Int = 404, profileBody: String = "{}",
                                summary: String = credit, summaryStatus: Int = 200,
                                usageStatus: Int = 200, usageBody: String = "{}", seen: CookieBox? = nil)
    -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            seen?.append(request.url?.path)
            switch request.url!.path {
            case "/api/auth/me": return response(request, status: profileStatus, body: profileBody)
            case "/api/usage-summary": return response(request, status: summaryStatus, body: summary)
            case "/api/usage": return response(request, status: usageStatus, body: usageBody)
            default: return response(request, status: 404, body: "{}")
            }
        }
    }

    func testOnlyExactIDE404AndUsableSummaryQualifies() async {
        for (summary, status) in [("{}", 200), ("{", 200), (Self.credit, 503),
                                  (#"{"membershipType":"pro"}"#, 200),
                                  (#"{"individualUsage":{"onDemand":{"used":20,"limit":100}}}"#, 200)] {
            let vm = viewModel()
            MockURLProtocol.requestHandler = Self.handler(summary: summary, summaryStatus: status,
                usageBody: #"{"legacy":{"numRequests":50,"maxRequestUsage":500}}"#)
            await vm.refresh()
            XCTAssertNil(vm.usageData, summary)
            XCTAssertEqual(vm.errorMessage, "Server error (404)")
        }
        for status in [403, 429, 500] {
            let vm = viewModel()
            MockURLProtocol.requestHandler = Self.handler(profileStatus: status)
            await vm.refresh()
            XCTAssertNil(vm.usageData, "Profile \(status) must not mitigate")
        }
        let malformed = viewModel()
        MockURLProtocol.requestHandler = Self.handler(profileStatus: 200, profileBody: "{")
        await malformed.refresh()
        XCTAssertNil(malformed.usageData)
    }

    func testProfileTransportFailureDoesNotMitigate() async {
        let vm = viewModel()
        let base = Self.handler()
        MockURLProtocol.requestHandler = { request in
            if request.url!.path == "/api/auth/me" { throw URLError(.notConnectedToInternet) }
            return try base(request)
        }
        await vm.refresh()
        XCTAssertNil(vm.usageData)
        vm.stopAutoRefreshForTests()
    }

    func testUnauthorizedStillWinsOverProfile404() async {
        for path in ["/api/usage-summary", "/api/usage"] {
            let vm = viewModel()
            vm.testHook_setCookieHeader(Self.browserCookie)
            let base = Self.handler(profileStatus: 200, profileBody: Self.profile)
            MockURLProtocol.requestHandler = { request in
                if request.value(forHTTPHeaderField: "Cookie") == Self.ideCookie {
                    return Self.response(request, status: request.url!.path == path ? 401 : 404, body: "{}")
                }
                return try base(request)
            }
            await vm.refresh()
            XCTAssertEqual(vm.activeAuthSource, .browserLogin)
            XCTAssertEqual(vm.usageData?.email, "example@example.test")
        }
    }

    func testProfile401EmptyAnd204FollowExpiryHandling() async {
        for (status, body) in [(401, "{}"), (204, ""), (200, "")] {
            let vm = viewModel()
            MockURLProtocol.requestHandler = Self.handler(profileStatus: status, profileBody: body)
            await vm.refresh()
            XCTAssertNil(vm.usageData)
            XCTAssertNil(vm.activeAuthSource)
        }
    }

    func testCurrentAttemptSourceOverridesPreviousIDEAuthSource() async {
        let vm = viewModel()
        vm.testHook_setCookieHeader(Self.browserCookie)
        MockURLProtocol.requestHandler = Self.handler(profileStatus: 200, profileBody: Self.profile)
        await vm.refresh()
        XCTAssertEqual(vm.activeAuthSource, .cursorIDE)
        let browser404 = Self.handler()
        MockURLProtocol.requestHandler = { request in
            if request.value(forHTTPHeaderField: "Cookie") == Self.ideCookie {
                return Self.response(request, status: 401, body: "{}")
            }
            return try browser404(request)
        }
        let previousSuccess = vm.lastSuccessAt
        await vm.refresh()
        XCTAssertEqual(vm.consecutiveFailureCount, 1)
        XCTAssertEqual(vm.activeAuthSource, .cursorIDE, "The last successful source must not turn browser404 into a success")
        XCTAssertEqual(vm.lastSuccessAt, previousSuccess)
    }

    func testCurrentIDEAttemptCanMitigateAfterBrowserSuccess() async {
        let vm = viewModel()
        vm.ideCredentialProvider = nil
        vm.testHook_setCookieHeader(Self.browserCookie)
        MockURLProtocol.requestHandler = Self.handler(profileStatus: 200, profileBody: Self.profile)
        await vm.refresh()
        XCTAssertEqual(vm.activeAuthSource, .browserLogin)
        vm.ideCredentialProvider = { IDECredential(cookieHeader: Self.ideCookie, expiresAt: .distantFuture) }
        MockURLProtocol.requestHandler = Self.handler()
        await vm.refresh()
        XCTAssertEqual(vm.activeAuthSource, .cursorIDE)
        XCTAssertEqual(vm.usageData?.email, "Unknown")
        XCTAssertEqual(vm.usageData?.planUsedCents, 20)
        XCTAssertNil(vm.errorMessage)
    }

    func testSameCredentialRetainsProfileButNeverPersistentAuthority() async {
        let vm = viewModel()
        MockURLProtocol.requestHandler = Self.handler(profileStatus: 200, profileBody: Self.profile, summary: Self.split)
        await vm.refresh()
        let account = vm.splitUsage.snapshot?.identity.accountDigest
        XCTAssertNotNil(vm.splitUsage.persistentSubjectDigest)
        MockURLProtocol.requestHandler = Self.handler(summary: Self.split)
        await vm.refresh()
        XCTAssertEqual(vm.usageData?.name, "Example")
        XCTAssertEqual(vm.usageData?.email, "example@example.test")
        XCTAssertEqual(vm.splitUsage.snapshot?.identity.accountDigest, account)
        XCTAssertNil(vm.splitUsage.persistentSubjectDigest)
        XCTAssertEqual(vm.usageData?.splitUsage?.otherPercent, 23)
        MockURLProtocol.requestHandler = Self.handler(profileStatus: 200, profileBody: Self.profile, summary: Self.split)
        await vm.refresh()
        XCTAssertNotNil(vm.splitUsage.persistentSubjectDigest)
        XCTAssertEqual(vm.splitUsage.snapshot?.identity.accountDigest, account)
    }

    func testRepeatedUnknownCredentialKeepsOwnershipAndRotationRetiresIt() async {
        let vm = viewModel()
        MockURLProtocol.requestHandler = Self.handler(summary: Self.split)
        await vm.refresh()
        let first = vm.splitUsage.snapshot?.identity
        await vm.refresh()
        XCTAssertEqual(vm.splitUsage.snapshot?.identity.accountDigest, first?.accountDigest)
        XCTAssertEqual(vm.splitUsage.snapshot?.identity.credentialGeneration, first?.credentialGeneration)
        vm.ideCredentialProvider = { IDECredential(cookieHeader: "WorkosCursorSessionToken=user_fixture%3A%3Aide-two", expiresAt: .distantFuture) }
        await vm.refresh()
        XCTAssertNotEqual(vm.splitUsage.snapshot?.identity.accountDigest, first?.accountDigest)
        XCTAssertEqual(vm.usageData?.email, "Unknown")
        XCTAssertNil(vm.lastJump)
    }

    func testUnknownEnterpriseDoesNotDiscoverTeamOrMember() async {
        let vm = viewModel()
        let paths = CookieBox()
        MockURLProtocol.requestHandler = Self.handler(summary: #"{"membershipType":"enterprise","autoModelSelectedDisplayMessage":"25% used","individualUsage":{"overall":{"used":500}}}"#, seen: paths)
        await vm.refresh()
        XCTAssertEqual(vm.usageData?.percentUsed, 25)
        XCTAssertTrue(vm.usageData?.isPercentOnly == true)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(Set(paths.all.compactMap { $0 }), ["/api/auth/me", "/api/usage-summary", "/api/usage"])
    }

    func testEqualProviderSuffixDoesNotPreserveUnknownCredentialOwnership() async throws {
        func cookie(provider: String) throws -> String {
            let payload = try JSONSerialization.data(withJSONObject: ["sub": provider + "|user_shared", "exp": 4_000_000_000])
                .base64EncodedString().replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return CursorAppAuthReader.makeCookieHeader(userID: "user_shared", jwt: "e30.\(payload).fixture")
        }
        let vm = viewModel()
        let firstCookie = try cookie(provider: "auth0")
        vm.ideCredentialProvider = { IDECredential(cookieHeader: firstCookie, expiresAt: .distantFuture) }
        MockURLProtocol.requestHandler = Self.handler(profileStatus: 200, profileBody: Self.profile, summary: Self.split)
        await vm.refresh()
        var previous = try XCTUnwrap(vm.splitUsage.snapshot?.identity)
        for provider in ["github", "another-provider"] {
            let nextCookie = try cookie(provider: provider)
            vm.ideCredentialProvider = { IDECredential(cookieHeader: nextCookie, expiresAt: .distantFuture) }
            MockURLProtocol.requestHandler = Self.handler(summary: Self.split)
            await vm.refresh()
            let current = try XCTUnwrap(vm.splitUsage.snapshot?.identity)
            XCTAssertNotEqual(current.accountDigest, previous.accountDigest)
            XCTAssertNotEqual(current.credentialGeneration, previous.credentialGeneration)
            XCTAssertEqual(vm.usageData?.email, "Unknown")
            XCTAssertNil(vm.splitUsage.persistentSubjectDigest)
            XCTAssertNil(vm.lastJump)
            previous = current
        }
    }

    func testDegradedSplitCreditSplitFlapDoesNotRepeatDeliveredThreshold() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var bodies: [String] = []
        let manager = NotificationManager(requestAuthorization: { true }, deliver: { bodies.append($0.content.body) })
        let vm = viewModel(manager: manager, alertStore: SplitUsageAlertStore(directory: directory))
        vm.notificationEnabled = true
        vm.jumpEffectEnabled = false
        let summary = #"{"membershipType":"ultra","billingCycleStart":"2026-09-01T00:00:00Z","billingCycleEnd":"2026-10-01T00:00:00Z","individualUsage":{"plan":{"used":20,"limit":40000,"autoPercentUsed":1,"apiPercentUsed":99}}}"#
        for usageStatus in [200, 500, 200] {
            MockURLProtocol.requestHandler = Self.handler(summary: summary, usageStatus: usageStatus)
            await vm.refresh()
            await vm.testHook_waitForSplitAlerts()
            XCTAssertEqual(vm.splitUsage.eligibility, usageStatus == 200 ? .eligible : .legacy)
            XCTAssertNil(vm.errorMessage)
        }
        XCTAssertEqual(bodies.count, 1, "The same delivered split threshold must survive a temporary credit representation")
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "No fresh profile means no alert file")
    }
}
