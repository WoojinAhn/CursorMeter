import XCTest
@testable import CursorMeter

/// Integration tests for the #76 regression: an expired session must reach
/// the logout path no matter which endpoint signals it or how the others fail.
///
/// NOTE: `MockURLProtocol.requestHandler` is a single global serving all three
/// parallel requests — keep handlers STATELESS (pure routing on url.path).
/// Counting or ordering assertions inside the handler would be racy.
@MainActor
final class SessionExpiryTests: XCTestCase {

    @MainActor final class ExpirySpy {
        var notifyCount = 0
        var keychainDeleteCount = 0
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    /// View model wired to MockURLProtocol with all real side effects
    /// (Keychain, UNUserNotificationCenter) stubbed out.
    private func makeViewModel(spy: ExpirySpy) -> UsageViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let vm = UsageViewModel(apiClient: CursorAPIClient(configuration: config))
        vm.keychainDeleteHandler = { spy.keychainDeleteCount += 1 }
        vm.sessionExpiredNotifier = { spy.notifyCount += 1 }  // UNUserNotificationCenter crashes in SPM tests
        vm.testHook_setCookieHeader("WorkosCursorSessionToken=test")
        vm.authState = .loggedIn
        return vm
    }

    /// The 2026-07-03 incident was auth/me 204 masking the other 401s; Task 1
    /// already converts 204 → unauthorized, so this test uses 200 + an
    /// undecodable body to keep proving the deeper invariant on its own: a
    /// decode failure on one endpoint must NEVER mask another endpoint's 401.
    func test_refresh_userInfoDecodeFailure_summary401_firesLogoutPath() async {
        let spy = ExpirySpy()
        let vm = makeViewModel(spy: spy)
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            if url.path == "/api/auth/me" {
                let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (ok, Data("not json".utf8))
            }
            let unauthorized = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (unauthorized, Data("{\"error\":\"unauthorized\"}".utf8))
        }

        await vm.refresh()

        XCTAssertEqual(vm.authState, .loginRequired)
        XCTAssertNil(vm.usageData)
        XCTAssertEqual(spy.notifyCount, 1, "expiry notification fires exactly once on the transition")
        XCTAssertEqual(spy.keychainDeleteCount, 1)
    }

    /// /api/auth/me 204 empty body ALONE (Task 1 behavior) must reach the
    /// logout path — the other endpoints fail with 500 here so the 204 is
    /// the only expiry signal in play.
    func test_refresh_authMe204_firesLogoutPath() async {
        let spy = ExpirySpy()
        let vm = makeViewModel(spy: spy)
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            if url.path == "/api/auth/me" {
                let noContent = HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!
                return (noContent, Data())
            }
            let serverError = HTTPURLResponse(url: url, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (serverError, Data("oops".utf8))
        }

        await vm.refresh()

        XCTAssertEqual(vm.authState, .loginRequired)
        XCTAssertEqual(spy.notifyCount, 1)
        XCTAssertEqual(spy.keychainDeleteCount, 1)
    }

    /// userInfo decodes FINE but summary/usage return 401 — the logout path
    /// must not depend on /api/auth/me being the endpoint that fails.
    func test_refresh_userInfoOK_summary401_firesLogoutPath() async {
        let spy = ExpirySpy()
        let vm = makeViewModel(spy: spy)
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            if url.path == "/api/auth/me" {
                let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (ok, Data("{\"email\":\"test@test.com\",\"name\":\"Test\"}".utf8))
            }
            let unauthorized = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (unauthorized, Data())
        }

        await vm.refresh()

        XCTAssertEqual(vm.authState, .loginRequired)
        XCTAssertEqual(spy.notifyCount, 1)
        XCTAssertEqual(spy.keychainDeleteCount, 1)
    }

    /// A second refresh in the expired state must not re-notify — the cookie
    /// is already cleared, so refresh() early-returns before any API call.
    func test_refresh_repeatedInExpiredState_doesNotRenotify() async {
        let spy = ExpirySpy()
        let vm = makeViewModel(spy: spy)
        MockURLProtocol.requestHandler = { request in
            let unauthorized = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (unauthorized, Data())
        }

        await vm.refresh()
        await vm.refresh()

        XCTAssertEqual(vm.authState, .loginRequired)
        XCTAssertEqual(spy.notifyCount, 1, "only the loggedIn → loginRequired transition notifies")
        XCTAssertEqual(spy.keychainDeleteCount, 1, "second refresh early-returns before any API call")
    }

    /// Non-401 failures (e.g. server error) must NOT trigger the logout path.
    func test_refresh_serverError_keepsSession() async {
        let spy = ExpirySpy()
        let vm = makeViewModel(spy: spy)
        MockURLProtocol.requestHandler = { request in
            let serverError = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (serverError, Data("oops".utf8))
        }

        await vm.refresh()

        XCTAssertEqual(vm.authState, .loggedIn)
        XCTAssertEqual(spy.notifyCount, 0)
        XCTAssertEqual(spy.keychainDeleteCount, 0)
    }

    /// #82: logout() must delete the credential through the injectable seam,
    /// not KeychainStore directly — otherwise every test calling logout()
    /// attempts a REAL keychain delete on the dev machine (-25244 log noise).
    func test_logout_routesKeychainDeleteThroughSeam() {
        let spy = ExpirySpy()
        let vm = makeViewModel(spy: spy)

        vm.logout()

        XCTAssertEqual(spy.keychainDeleteCount, 1)
        XCTAssertEqual(vm.authState, .loggedOut)
    }
}
