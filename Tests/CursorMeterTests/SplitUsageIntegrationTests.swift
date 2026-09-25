import XCTest
@testable import CursorMeter

@MainActor
final class SplitUsageIntegrationTests: XCTestCase {
    override func tearDown() { MockURLProtocol.requestHandler = nil; super.tearDown() }

    private func vm(summaryStatus: Int = 200, cursor: Double? = 10, other: Double = 41, used: Int = 18200,
                    manager: NotificationManager? = nil, controller: SplitUsageController? = nil) -> UsageViewModel {
        let summary = """
        {"membershipType":"ultra","billingCycleStart":"2026-09-01T00:00:00Z","billingCycleEnd":"2026-10-01T00:00:00Z","individualUsage":{"plan":{"used":\(used),"limit":40000,"autoPercentUsed":\(cursor.map(String.init(describing:)) ?? "null"),"apiPercentUsed":\(other)},"onDemand":{"used":100,"limit":1000,"enabled":true}}}
        """
        MockURLProtocol.requestHandler = { request in
            let path = request.url!.path
            let status = path == "/api/usage-summary" ? summaryStatus : 200
            let body: String
            switch path {
            case "/api/usage-summary": body = summary
            case "/api/auth/me": body = "{\"email\":\"demo@example.test\",\"name\":\"Demo\",\"sub\":\"demo\"}"
            case "/api/usage": body = "{}"
            default: body = "{\"usageEventsDisplay\":[],\"totalUsageEventsCount\":0}"
            }
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let vm = UsageViewModel(apiClient: CursorAPIClient(configuration: config), refreshFeedback: RefreshFeedback(timing: .immediate),
            notificationManager: manager ?? NotificationManager(requestAuthorization: { false }, deliver: { _ in }),
            splitUsage: controller ?? SplitUsageController())
        vm.updateCheckRunner = { .upToDate }
        vm.keychainDeleteHandler = {}
        vm.sessionExpiredNotifier = {}
        vm.notificationEnabled = false
        vm.authState = .loggedIn
        vm.testHook_setCookieHeader("WorkosCursorSessionToken=fixture")
        return vm
    }

    func testSplitDoesNotLatchLegacyFourHundredDollarMeterAndPreservesTextPreference() async {
        let vm = vm(used: 50000)
        vm.menuBarDisplayMode = 1
        await vm.refresh()
        defer { vm.stopAutoRefreshForTests() }
        XCTAssertEqual(vm.splitUsage.eligibility, .eligible)
        XCTAssertEqual(vm.usageData?.splitUsage?.otherPercent, 41)
        XCTAssertEqual(vm.usageData?.isOnDemandActive, false)
        XCTAssertEqual(vm.effectiveMenuBarDisplayMode, 0)
        XCTAssertEqual(vm.menuBarDisplayMode, 1)
        XCTAssertTrue(vm.splitPresentation?.tooltip.contains("Other Models") == true)
    }

    func testLatchedSummaryFailureDoesNotPublishFreshUsageOnlyFallback() async throws {
        let vm = vm()
        await vm.refresh()
        let previous = try XCTUnwrap(vm.splitUsage.snapshot)
        let successAt = vm.lastSuccessAt
        let priorHandler = MockURLProtocol.requestHandler!
        MockURLProtocol.requestHandler = { request in
            if request.url!.path == "/api/usage-summary" {
                return (HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!, Data())
            }
            return try priorHandler(request)
        }
        await vm.refresh()
        defer { vm.stopAutoRefreshForTests() }
        XCTAssertEqual(vm.splitUsage.snapshot, previous)
        XCTAssertTrue(vm.splitUsage.isStale)
        XCTAssertEqual(vm.lastSuccessAt, successAt)
        XCTAssertEqual(vm.consecutiveFailureCount, 1)
        XCTAssertEqual(vm.usageData?.splitUsage?.otherPercent, 41)
    }

    func testPermissionReadUsesInjectedManagerAndDoesNotPrompt() async {
        var prompts = 0
        let manager = NotificationManager(requestAuthorization: { prompts += 1; return true }, deliver: { _ in }, permissionStateProvider: { .denied })
        let vm = vm(manager: manager)
        await vm.refreshNotificationPermissionStatus()
        XCTAssertEqual(vm.notificationPermissionStatus, "Denied in macOS Settings")
        XCTAssertEqual(prompts, 0)
    }
    func testPermissionPromptDoesNotHoldPrimaryRefreshOpen() async {
        var pendingAuthorization: CheckedContinuation<Bool, Never>?
        let manager = NotificationManager(requestAuthorization: {
            await withCheckedContinuation { pendingAuthorization = $0 }
        }, deliver: { _ in })
        let vm = vm(cursor: 95, manager: manager)
        vm.notificationEnabled = true
        var finished = false
        let refresh = Task { await vm.refresh(); finished = true }
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while (!finished || pendingAuthorization == nil), ContinuousClock.now < end { await Task.yield() }
        XCTAssertTrue(finished, "Primary refresh must not wait for notification permission")
        XCTAssertNotNil(pendingAuthorization)
        XCTAssertFalse(vm.isLoading)
        XCTAssertNotNil(vm.lastSuccessAt)
        pendingAuthorization?.resume(returning: false)
        await refresh.value
        vm.stopAutoRefreshForTests()
    }

    func testRetainedSupplementNeverBecomesAlertSourceOnNextPrimary() async throws {
        let period = try JSONDecoder().decode(CurrentPeriodUsageResponse.self, from: Data("""
        {"billingCycleStart":"2026-09-01T00:00:00Z","billingCycleEnd":"2026-10-01T00:00:00Z","planUsage":{"includedSpend":18200,"autoPercentUsed":95,"apiPercentUsed":41}}
        """.utf8))
        let controller = SplitUsageController(collect: { snapshot, summary, _, _, supplement in
            await supplement(snapshot.supplemented(by: period, summary: summary, at: snapshot.capturedAt))
            return .init(status: .transportFailure, snapshot: nil, pageCount: 1, byteCount: 0)
        })
        var prompts = 0
        var bodies: [String] = []
        let manager = NotificationManager(requestAuthorization: { prompts += 1; return true }, deliver: { bodies.append($0.content.body) })
        let vm = vm(cursor: nil, manager: manager, controller: controller)
        defer { vm.stopAutoRefreshForTests() }
        vm.notificationEnabled = true
        await vm.refresh()
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while controller.snapshot?.cursorPercent != 95, ContinuousClock.now < end { await Task.yield() }
        XCTAssertEqual(controller.snapshot?.cursorPercent, 95)
        await vm.refresh()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(controller.snapshot?.cursorPercent, 95)
        XCTAssertNil(controller.primarySnapshot?.cursorPercent)
        XCTAssertEqual(prompts, 0)
        XCTAssertTrue(bodies.isEmpty)
    }

}
