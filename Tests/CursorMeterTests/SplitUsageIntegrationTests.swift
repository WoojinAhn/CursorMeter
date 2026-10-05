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
        let vm = makeTestUsageViewModel(apiClient: CursorAPIClient(configuration: config), refreshFeedback: RefreshFeedback(timing: .immediate),
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

    private func installEnterpriseHistoryFailure(fallback: @escaping (URLRequest) throws -> (HTTPURLResponse, Data)) {
        MockURLProtocol.requestHandler = { request in
            let body: String
            var status = 200
            switch request.url!.path {
            case "/api/usage-summary": body = """
                {"membershipType":"enterprise","billingCycleStart":"2026-09-01T00:00:00Z","billingCycleEnd":"2026-10-01T00:00:00Z","individualUsage":{"plan":{"used":0,"limit":40000}}}
                """
            case "/api/dashboard/teams": body = "{\"teams\":[{\"id\":7}]}"
            case "/api/dashboard/get-team-spend": body = "{\"teamMemberSpend\":[{\"userId\":42,\"email\":\"demo@example.test\"}]}"
            case "/api/dashboard/get-filtered-usage-events": body = "{}"; status = 403
            default: return try fallback(request)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
    }

    func testPersonalSplitPublishesOnFirstRefreshAfterEnterpriseHistoryFailure() async {
        var bodies: [String] = []
        let manager = NotificationManager(requestAuthorization: { true }, deliver: { bodies.append($0.content.body) })
        let vm = vm(used: 38000, manager: manager)
        defer { vm.stopAutoRefreshForTests() }
        let personal = MockURLProtocol.requestHandler!
        installEnterpriseHistoryFailure(fallback: personal)
        await vm.refresh()
        XCTAssertEqual(vm.usageData?.membershipType, "enterprise")
        XCTAssertNil(vm.cachedWeeklyMode, "The rejected history shape drops its optimization cache")
        MockURLProtocol.requestHandler = personal
        vm.notificationEnabled = true
        await vm.refresh()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(vm.splitUsage.eligibility, .eligible)
        XCTAssertEqual(vm.usageData?.splitUsage?.cursorPercent, 10)
        XCTAssertEqual(vm.usageData?.splitEligibility, .eligible)
        XCTAssertEqual(vm.cachedWeeklyMode, .personal)
        XCTAssertTrue(bodies.isEmpty, "The legacy95% ratio must never alert during scope adoption")
    }

    func testSleepRetiresHeldMonthlyWorkWithoutTerminalPartialOrClearingMeter() async throws {
        actor CollectionGate {
            var started = false
            var continuation: CheckedContinuation<Void, Never>?
            func collect() async -> CycleCollectionResult {
                started = true
                await withCheckedContinuation { continuation = $0 }
                return .init(status: .partial, snapshot: nil, pageCount: 1, byteCount: 0)
            }
            func release() { continuation?.resume(); continuation = nil }
        }
        let gate = CollectionGate()
        var time = Date()
        let controller = SplitUsageController(now: { time }, collect: { _, _, _, _, _ in await gate.collect() })
        let vm = vm(controller: controller)
        defer { vm.stopAutoRefreshForTests() }
        await vm.refresh()
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await gate.started), ContinuousClock.now < end { await Task.yield() }
        let original = try XCTUnwrap(controller.primarySnapshot)
        vm.systemWillSleep()
        XCTAssertFalse(controller.canRefreshAmounts)
        XCTAssertEqual(controller.primarySnapshot, original)
        time = time.addingTimeInterval(3600)
        await gate.release()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while controller.schedule.automaticPagesRemaining(at: time) != 299, ContinuousClock.now < deadline { await Task.yield() }
        vm.systemDidWake()
        XCTAssertEqual(controller.schedule.availability(at: time, manual: false), .ready)
        XCTAssertTrue(controller.canRefreshAmounts)
        XCTAssertEqual(controller.primarySnapshot, original)
        XCTAssertEqual(controller.eligibility, .eligible)
    }

    func testMissingMembershipCannotReplaceKnownEnterpriseRequestScopeWithSplit() async {
        let vm = vm()
        defer { vm.stopAutoRefreshForTests() }
        let personal = MockURLProtocol.requestHandler!
        installEnterpriseHistoryFailure(fallback: personal)
        await vm.refresh()
        XCTAssertNil(vm.cachedWeeklyMode)
        MockURLProtocol.requestHandler = { request in
            let (response, data) = try personal(request)
            guard request.url!.path == "/api/usage-summary" else { return (response, data) }
            var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            json.removeValue(forKey: "membershipType")
            return (response, try JSONSerialization.data(withJSONObject: json))
        }
        await vm.refresh()
        XCTAssertEqual(vm.splitUsage.eligibility, .legacy)
        XCTAssertNil(vm.splitUsage.primarySnapshot)
        XCTAssertNil(vm.usageData?.splitUsage)
    }

    func testAmountCollectionWaitsForHistoryButPrimaryPublishesImmediately() async throws {
        actor Calls {
            var count = 0
            func collect() -> CycleCollectionResult {
                count += 1
                return .init(status: .transportFailure, snapshot: nil, pageCount: 0, byteCount: 0)
            }
        }
        let calls = Calls()
        let controller = SplitUsageController(collectToday: { _, _, _, _, _, _ in await calls.collect() })
        let vm = vm(controller: controller)
        defer { vm.stopAutoRefreshForTests() }
        let handler = MockURLProtocol.requestHandler!
        let entered = expectation(description: "history entered")
        let release = DispatchSemaphore(value: 0)
        MockURLProtocol.requestHandler = { request in
            if request.url!.path == "/api/dashboard/get-filtered-usage-events" {
                entered.fulfill()
                release.wait()
            }
            return try handler(request)
        }
        let refresh = Task { await vm.refresh() }
        await fulfillment(of: [entered], timeout: 2)
        XCTAssertNotNil(controller.primarySnapshot)
        XCTAssertNotNil(vm.lastSuccessAt)
        let before = await calls.count
        XCTAssertEqual(before, 0)
        release.signal()
        await refresh.value
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await calls.count == 0, ContinuousClock.now < deadline { await Task.yield() }
        let after = await calls.count
        XCTAssertEqual(after, 1)
    }

    func testLiveHistoryChangeAndFailedHistoryEachProduceNewSupportingDemand() async throws {
        actor Calls {
            var count = 0
            func collect(_ snapshot: SplitUsageSnapshot) -> CycleCollectionResult {
                count += 1
                var amounts = CycleAmountSnapshot(identity: snapshot.identity, capturedAt: snapshot.capturedAt)
                amounts.coverage.complete = true
                amounts.status = .estimatedAttribution
                amounts.residualCents = 0
                amounts.cursorCents = 100; amounts.otherCents = 18100
                return .init(status: .complete, snapshot: amounts, pageCount: 1, byteCount: 0)
            }
        }
        var time = Date()
        let calls = Calls()
        let controller = SplitUsageController(now: { time }, collectToday: { snapshot, _, _, _, _, _ in await calls.collect(snapshot) })
        let vm = vm(controller: controller)
        defer { vm.stopAutoRefreshForTests() }
        let base = MockURLProtocol.requestHandler!
        for (index, total) in [0, 0, 1, -1, -1].enumerated() {
            time = time.addingTimeInterval(60)
            MockURLProtocol.requestHandler = { request in
                if request.url!.path == "/api/dashboard/get-filtered-usage-events" {
                    let status = total < 0 ? 503 : 200
                    return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            Data("{\"usageEventsDisplay\":[],\"totalUsageEventsCount\":\(max(0, total))}".utf8))
                }
                return try base(request)
            }
            await vm.refresh()
            let expected = index == 0 ? 1 : index
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while await calls.count < expected, ContinuousClock.now < deadline { await Task.yield() }
            for _ in 0..<30 { await Task.yield() }
            let count = await calls.count
            XCTAssertEqual(count, expected, "Batch \(index): identical revision coalesces; each failure uses its own network ID")
        }
    }

}
