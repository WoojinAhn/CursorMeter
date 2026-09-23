import XCTest
@testable import CursorMeter

/// Thread-safe hit counter for MockURLProtocol handlers (which run off-main).
final class RequestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var _count = 0
    var count: Int { lock.withLock { _count } }
    func increment() { lock.withLock { _count += 1 } }
}

@MainActor
final class ActivityRefreshTests: XCTestCase {

    nonisolated private static let enabledKey = "activityRefreshEnabled"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.enabledKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.enabledKey)
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeViewModel(counting counter: RequestCounter) -> UsageViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        MockURLProtocol.requestHandler = { request in
            let url = request.url!
            if url.path == "/api/usage-summary" { counter.increment() }
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (ok, Data("{}".utf8))
        }
        let vm = UsageViewModel(
            apiClient: CursorAPIClient(configuration: config),
            refreshFeedback: RefreshFeedback(timing: .immediate)
        )
        vm.keychainDeleteHandler = {}
        vm.sessionExpiredNotifier = {}   // UNUserNotificationCenter crashes in SPM tests
        vm.updateCheckRunner = { .upToDate }
        vm.testHook_setCookieHeader("WorkosCursorSessionToken=TEST")
        vm.activityDebounceInterval = .milliseconds(30)
        vm.activityMinRefreshInterval = .milliseconds(150)
        return vm
    }

    private func waitUntil(_ timeoutMs: Int = 2000, _ condition: () -> Bool) async {
        var waited = 0
        while !condition() && waited < timeoutMs {
            try? await Task.sleep(for: .milliseconds(10))
            waited += 10
        }
    }

    func testBurstCollapsesToSingleRefresh() async {
        let counter = RequestCounter()
        let vm = makeViewModel(counting: counter)
        for _ in 0..<5 { vm.noteActivity() }
        await waitUntil { counter.count >= 1 }
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(counter.count, 1)
    }

    func testGuardDefersButNeverDrops() async {
        let counter = RequestCounter()
        let vm = makeViewModel(counting: counter)
        vm.activityMinRefreshInterval = .milliseconds(400)  // wide guard: mid-flight margin survives slow CI
        await vm.refresh()                       // any-source refresh stamps the guard
        XCTAssertEqual(counter.count, 1)

        vm.noteActivity()                        // debounce 30ms < guard 400ms
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(counter.count, 1)         // deferred: not fired early...
        await waitUntil { counter.count >= 2 }
        XCTAssertEqual(counter.count, 2)         // ...and not dropped
    }

    /// Finding 1 regression: an interleaved direct refresh during the deferred
    /// wait re-stamps the guard, and the deferred fire must recompute against
    /// the fresh window rather than firing immediately after its original sleep.
    func testDeferredRefreshRecomputesGuardAcrossInterleavedRefresh() async {
        let counter = RequestCounter()
        let vm = makeViewModel(counting: counter)
        vm.activityDebounceInterval = .milliseconds(20)
        vm.activityMinRefreshInterval = .milliseconds(500)

        await vm.refresh()                 // count 1, stamps the guard at t0
        XCTAssertEqual(counter.count, 1)

        vm.noteActivity()                  // deferred: debounce 20ms, then guard ~480ms

        // Mid-flight, re-stamp the guard with a direct refresh (t≈250). This
        // opens a fresh 500ms window (recomputed fire ≈ t750). The pre-fix
        // single-`if` code ignores this re-stamp and still fires at ≈ t500.
        try? await Task.sleep(for: .milliseconds(250))
        await vm.refresh()
        XCTAssertEqual(counter.count, 2)

        // Discriminating assertion — INSIDE the (t500, t750) gap. Pre-fix code
        // has already fired here (count would be 3); the recomputed guard has
        // not (count 2). ~125ms margin on each side for CI slack.
        try? await Task.sleep(for: .milliseconds(375))   // now ≈ t=625
        XCTAssertEqual(counter.count, 2)

        // Past the recomputed window it fires exactly once (defer-not-drop).
        await waitUntil { counter.count >= 3 }
        XCTAssertEqual(counter.count, 3)
        try? await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(counter.count, 3)
    }

    func testToggleOffCancelsPendingDebounce() async {
        let counter = RequestCounter()
        let vm = makeViewModel(counting: counter)
        vm.noteActivity()
        vm.setActivityRefreshEnabled(false)
        try? await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(counter.count, 0)
        XCTAssertFalse(vm.activityRefreshEnabled)
    }

    func testNoteActivityWhileDisabledIsNoOp() async {
        let counter = RequestCounter()
        let vm = makeViewModel(counting: counter)
        vm.setActivityRefreshEnabled(false)
        vm.noteActivity()
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(counter.count, 0)
    }
}
