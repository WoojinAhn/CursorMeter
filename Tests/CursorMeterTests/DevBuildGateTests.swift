import XCTest
@testable import CursorMeter

/// #109: a dev-build marker (CMDevBuildCommit from package_app.sh) must
/// short-circuit every update-check path — comparing the placeholder 0.1.0
/// against GitHub is pure noise on a dev machine.
@MainActor
final class DevBuildGateTests: XCTestCase {

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    private func makeViewModel() async -> UsageViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let vm = UsageViewModel(apiClient: CursorAPIClient(configuration: config))
        vm.updateCheckRunner = { .upToDate }
        vm.keychainDeleteHandler = {}
        vm.sessionExpiredNotifier = {}
        vm.refreshFailingNotifier = {}
        // Drain the init-launch update check (runs against the stub above) so
        // counters installed by individual tests see only the path under test.
        // The drain depends on the init check actually running — assert the
        // test host carries no dev marker, and bound the loop so a future
        // marker can only fail the assertion, never hang the suite.
        XCTAssertNil(vm.devBuildCommit, "test host bundle unexpectedly carries CMDevBuildCommit")
        var spins = 0
        while vm.lastUpdateCheckResult == nil && spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        return vm
    }

    /// Minimal all-200 API surface so refresh() reaches the periodic
    /// update-recheck block.
    private static let apiHandler: (URLRequest) throws -> (HTTPURLResponse, Data) = { request in
        let url = request.url!
        let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        switch url.path {
        case "/api/usage-summary":
            let json = """
            {"billingCycleEnd":"2099-08-15T00:00:00.000Z","membershipType":"free",
             "individualUsage":{"plan":{"enabled":true,"used":0,"limit":0,"remaining":0,"totalPercentUsed":1.0}}}
            """
            return (ok, Data(json.utf8))
        case "/api/auth/me":
            return (ok, Data("{\"email\":\"d@t.com\",\"name\":\"D\"}".utf8))
        case "/api/usage":
            return (ok, Data("{\"startOfMonth\":\"2099-07-15T00:00:00.000Z\"}".utf8))
        default:
            return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data("{}".utf8))
        }
    }

    // MARK: - Manual path

    func testManualCheckSkippedOnDevBuild() async {
        let vm = await makeViewModel()
        let counter = Counter()
        vm.updateCheckRunner = { counter.bump(); return .upToDate }
        vm.devBuildCommit = "abc1234-dirty"

        await vm.checkForUpdate()

        XCTAssertEqual(counter.count, 0, "dev build must not hit the update runner")
        XCTAssertFalse(vm.isCheckingUpdate)
    }

    func testManualCheckRunsWithoutMarker() async {
        let vm = await makeViewModel()
        let counter = Counter()
        vm.updateCheckRunner = { counter.bump(); return .upToDate }
        vm.devBuildCommit = nil

        await vm.checkForUpdate()

        XCTAssertEqual(counter.count, 1)
    }

    // MARK: - Periodic path (rides refresh success)

    func testPeriodicRecheckSkippedOnDevBuild() async {
        let vm = await makeViewModel()
        let counter = Counter()
        vm.updateCheckRunner = { counter.bump(); return .upToDate }
        vm.devBuildCommit = "abc1234"
        vm.testHook_setLastUpdateCheckAt(Date.distantPast)
        vm.testHook_setCookieHeader("WorkosCursorSessionToken=t")
        vm.authState = .loggedIn
        MockURLProtocol.requestHandler = Self.apiHandler

        await vm.refresh()

        XCTAssertNotNil(vm.usageData, "refresh itself must succeed")
        XCTAssertEqual(counter.count, 0, "stale lastUpdateCheckAt must not trigger a recheck on a dev build")
    }

    func testPeriodicRecheckRunsWithoutMarker() async {
        let vm = await makeViewModel()
        let counter = Counter()
        vm.updateCheckRunner = { counter.bump(); return .upToDate }
        vm.devBuildCommit = nil
        vm.testHook_setLastUpdateCheckAt(Date.distantPast)
        vm.testHook_setCookieHeader("WorkosCursorSessionToken=t")
        vm.authState = .loggedIn
        MockURLProtocol.requestHandler = Self.apiHandler

        await vm.refresh()

        XCTAssertEqual(counter.count, 1, "stale lastUpdateCheckAt triggers exactly one recheck on release builds")
    }
}
