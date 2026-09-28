import XCTest
@testable import CursorMeter

@MainActor
final class LegacyNotificationCompositionTests: XCTestCase {
    @MainActor private final class Gate {
        private var waiting: CheckedContinuation<Void, Never>?
        private var arrival: CheckedContinuation<Void, Never>?
        func pause() async {
            await withCheckedContinuation {
                waiting = $0
                arrival?.resume()
                arrival = nil
            }
        }
        func wait() async {
            if waiting == nil { await withCheckedContinuation { arrival = $0 } }
        }
        func release() { waiting?.resume(); waiting = nil }
    }

    func testThresholdReportsActualUsageAndConfiguredLevelSeparately() async {
        var contents: [UsageNotificationContent] = []
        let manager = NotificationManager(requestAuthorization: { true }, deliver: {
            contents.append(.init(title: $0.content.title, body: $0.content.body))
        })
        await manager.checkAndNotify(percentUsed: 84, warningThreshold: 80, criticalThreshold: 90,
                                     enabled: true, mode: .creditPlan(usedCents: 1680, limitCents: 2000))
        XCTAssertEqual(contents, [.init(title: "Included usage 84.0% · Warning",
                                       body: "$16.80 of $20.00 · alert at 80%")])
    }

    func testSameRefreshThresholdAndBoldDeliverOnce() async {
        var contents: [UsageNotificationContent] = []
        var authorizations = 0
        let manager = NotificationManager(requestAuthorization: { authorizations += 1; return true }, deliver: {
            contents.append(.init(title: $0.content.title, body: $0.content.body))
            XCTAssertTrue($0.identifier.hasPrefix("usage-threshold-"))
        })
        await manager.checkAndNotify(percentUsed: 84, warningThreshold: 80, criticalThreshold: 90,
            enabled: true, mode: .creditPlan(usedCents: 1680, limitCents: 2000),
            jump: .init(mode: .credit, reference: 1590, current: 1680, limit: 2000))
        XCTAssertEqual(authorizations, 1)
        XCTAssertEqual(contents, [.init(title: "Included usage 84.0% · Warning",
            body: "$16.80 of $20.00 · alert at 80%\n+$0.90 since last refresh")])
        XCTAssertEqual(manager.notifiedThresholds, [80])
    }

    func testThresholdAndBoldAdmissionsRemainIndependent() async {
        for thresholds in [false, true] {
            for bold in [false, true] {
                var contents: [UsageNotificationContent] = []
                let manager = NotificationManager(requestAuthorization: { true }, deliver: {
                    contents.append(.init(title: $0.content.title, body: $0.content.body))
                })
                await manager.checkAndNotify(percentUsed: 84, warningThreshold: 80, criticalThreshold: 90,
                    enabled: thresholds, mode: .creditPlan(usedCents: 1680, limitCents: 2000),
                    jump: bold ? .init(mode: .credit, reference: 1590, current: 1680, limit: 2000) : nil)
                await manager.waitUntilUsageIdle()
                XCTAssertEqual(contents.count, thresholds || bold ? 1 : 0)
                if let content = contents.first {
                    XCTAssertEqual(content.title, thresholds ? "Included usage 84.0% · Warning" : "Included usage increased")
                    XCTAssertEqual(content.body.contains("+$0.90"), bold)
                    XCTAssertEqual(content.body.contains("alert at 80%"), thresholds)
                }
                XCTAssertEqual(manager.notifiedThresholds, thresholds ? [80] : [])
            }
        }
    }

    func testDeliveredThresholdDoesNotSuppressNewBold() async {
        var titles: [String] = []
        let manager = NotificationManager(requestAuthorization: { true }, deliver: { titles.append($0.content.title) })
        manager.testHook_seed([80])
        await manager.checkAndNotify(percentUsed: 85, warningThreshold: 80, criticalThreshold: 90,
            enabled: true, mode: .percentOnly,
            jump: .init(mode: .percent, reference: 70, current: 85, limit: 100))
        await manager.waitUntilUsageIdle()
        XCTAssertEqual(titles, ["Included usage increased"])
    }

    func testCapturedPercentagesStayFixedAcrossPermissionWait() async {
        let gate = Gate()
        var contents: [UsageNotificationContent] = []
        let manager = NotificationManager(requestAuthorization: { await gate.pause(); return true }, deliver: {
            contents.append(.init(title: $0.content.title, body: $0.content.body))
        })
        var sample = LegacyUsageJumpSnapshot(mode: .percent, reference: 63.125, current: 84.25, limit: 100)
        let captured = sample
        let sending = Task {
            await manager.checkAndNotify(percentUsed: 84.25, warningThreshold: 80, criticalThreshold: 90,
                enabled: true, mode: .percentOnly, jump: captured)
        }
        await gate.wait()
        sample = .init(mode: .percent, reference: 84.25, current: 99, limit: 100)
        gate.release()
        await sending.value
        XCTAssertEqual(sample.current, 99)
        XCTAssertEqual(contents, [.init(title: "Included usage 84.3% · Warning",
            body: "Your warning level is 80%.\nLast refresh 63.1% → now 84.3%")])
    }

    func testResetWhileCombinedAuthorizationPendingDropsBothComponents() async {
        let gate = Gate()
        var sent = 0
        let manager = NotificationManager(requestAuthorization: { await gate.pause(); return true }, deliver: { _ in sent += 1 })
        let sending = Task {
            await manager.checkAndNotify(percentUsed: 84, warningThreshold: 80, criticalThreshold: 90,
                enabled: true, mode: .creditPlan(usedCents: 1680, limitCents: 2000),
                jump: .init(mode: .credit, reference: 1590, current: 1680, limit: 2000))
        }
        await gate.wait()
        manager.resetNotifications()
        gate.release()
        await sending.value
        XCTAssertEqual(sent, 0)
        XCTAssertTrue(manager.notifiedThresholds.isEmpty)
    }

    func testLegacyAcknowledgementContractIsUnchangedForDeniedAndFailedDelivery() async {
        enum Failure: Error { case rejected }
        for denied in [false, true] {
            let manager = NotificationManager(requestAuthorization: { !denied }, deliver: { _ in throw Failure.rejected })
            await manager.checkAndNotify(percentUsed: 95, warningThreshold: 80, criticalThreshold: 90,
                                         enabled: true, mode: .percentOnly)
            XCTAssertEqual(manager.notifiedThresholds, [90])
        }
    }

    func testStandaloneLegacyFamiliesAndUnknownLimits() {
        let samples: [(LegacyUsageJumpSnapshot, String, String)] = [
            (.init(mode: .credit, reference: 1600, current: 1630, limit: 2000), "Included usage increased", "+$0.30 since last refresh\n$16.30 of $20.00 used"),
            (.init(mode: .onDemand, reference: 3200, current: 3230, limit: 4000), "Paid spending increased", "+$0.30 since last refresh\n$32.30 of $40.00 budget used"),
            (.init(mode: .request, reference: 400, current: 415, limit: 500), "Request usage increased", "15 more requests since last refresh\n415 of 500 requests used"),
            (.init(mode: .percent, reference: 25, current: 40, limit: 100), "Included usage increased", "Last refresh 25.0% → now 40.0%"),
            (.init(mode: .onDemand, reference: 0, current: 30, limit: 0), "Paid spending increased", "+$0.30 since last refresh")
        ]
        for (jump, title, body) in samples {
            let content = NotificationManager.legacyUsageContent(percentUsed: 0, level: .none,
                threshold: 80, mode: .percentOnly, jump: jump)
            XCTAssertEqual(content, .init(title: title, body: body))
        }
    }

    func testThresholdTitlesPreservePercentageBoundariesAndRequestScope() {
        let request = NotificationManager.legacyUsageContent(percentUsed: 151.4, level: .critical,
            threshold: 90, mode: .requestQuota(used: 757, limit: 500), jump: nil)
        XCTAssertEqual(request, .init(title: "Request quota 151.4% · Critical",
                                      body: "757 of 500 requests · alert at 90%"))
        for (percent, expected) in [(99.99, "<100.0%"), (100.01, ">100.0%"), (0.01, "<0.1%")] {
            let content = NotificationManager.legacyUsageContent(percentUsed: percent, level: .warning,
                threshold: 80, mode: .percentOnly, jump: nil)
            XCTAssertEqual(content?.title, "Included usage \(expected) · Warning")
        }
        XCTAssertNil(NotificationMode.creditPlan(usedCents: 30, limitCents: 0).fraction)
        XCTAssertNil(NotificationMode.requestQuota(used: 15, limit: 0).fraction)
    }

    func testAppStatusPayloadsAndIdentifiersRemainSeparate() async {
        var messages: [(String, UsageNotificationContent)] = []
        let manager = NotificationManager(requestAuthorization: { true }, deliver: {
            messages.append(($0.identifier, .init(title: $0.content.title, body: $0.content.body)))
        })
        await manager.notifyUpdateAvailable(version: "0.8.2", releaseURL: "https://github.com/WoojinAhn/CursorMeter/releases/tag/v0.8.2")
        await manager.notifyRefreshFailing()
        await manager.notifySessionExpired()
        XCTAssertEqual(messages.map(\.0), ["update-available", "refresh-failing", "session-expired"])
        XCTAssertEqual(messages.map(\.1), [
            .init(title: "Update available: v0.8.2", body: "See what’s new on GitHub."),
            .init(title: "Can’t refresh Cursor usage", body: "5 refreshes failed in a row.\nData may be out of date."),
            .init(title: "Cursor session expired", body: "Reconnect to resume usage updates.")
        ])
    }

    func testRefreshPipelineCoalescesAndHonorsAllJumpSettings() async {
        defer { MockURLProtocol.requestHandler = nil }
        for enabled in [false, true] {
            for intensity in JumpIntensity.allCases {
                var contents: [UsageNotificationContent] = []
                let manager = NotificationManager(requestAuthorization: { true }, deliver: {
                    contents.append(.init(title: $0.content.title, body: $0.content.body))
                })
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [MockURLProtocol.self]
                let vm = UsageViewModel(apiClient: CursorAPIClient(configuration: configuration),
                    refreshFeedback: RefreshFeedback(timing: .immediate), notificationManager: manager)
                vm.updateCheckRunner = { .upToDate }
                vm.keychainDeleteHandler = {}
                vm.notificationEnabled = true
                vm.warningThreshold = 80
                vm.criticalThreshold = 90
                vm.jumpEffectEnabled = enabled
                vm.jumpIntensity = intensity
                vm.authState = .loggedIn
                vm.testHook_setCookieHeader("WorkosCursorSessionToken=test")
                MockURLProtocol.requestHandler = Self.handler(usedCents: 1590)
                await vm.refresh()
                XCTAssertTrue(contents.isEmpty)
                MockURLProtocol.requestHandler = Self.handler(usedCents: 1680)
                await vm.refresh()
                XCTAssertEqual(contents.count, 1)
                XCTAssertEqual(contents.first?.title, "Included usage 84.0% · Warning")
                XCTAssertEqual(contents.first?.body.contains("+$0.90"), enabled && intensity == .bold)
                XCTAssertEqual(vm.lastJump?.legacySnapshot?.reference, 1590)
                XCTAssertEqual(vm.lastJump?.legacySnapshot?.current, 1680)
            }
        }
    }

    func testBoldOnlyAuthorizationDoesNotBlockNextLegacyRefresh() async {
        defer { MockURLProtocol.requestHandler = nil }
        let gate = Gate()
        var authorizations = 0
        let manager = NotificationManager(requestAuthorization: {
            authorizations += 1
            if authorizations == 1 { await gate.pause() }
            return true
        }, deliver: { _ in })
        let vm = makeViewModel(manager: manager)
        MockURLProtocol.requestHandler = Self.handler(usedCents: 100)
        await vm.refresh()
        MockURLProtocol.requestHandler = Self.handler(usedCents: 140)
        let firstRefresh = Task { await vm.refresh() }
        await gate.wait()
        MockURLProtocol.requestHandler = Self.handler(usedCents: 180)
        let secondFinished = expectation(description: "Next refresh finishes before Bold authorization")
        let secondRefresh = Task {
            await vm.refresh()
            secondFinished.fulfill()
        }
        await fulfillment(of: [secondFinished], timeout: 1)
        let valueBeforeAuthorization = vm.usageData?.planUsedCents
        gate.release()
        await firstRefresh.value
        await secondRefresh.value
        await manager.waitUntilUsageIdle()
        XCTAssertEqual(valueBeforeAuthorization, 180)
    }

    func testScheduledBoldCapturesRevisionBeforeWorkerStarts() async {
        var sent = 0
        let manager = NotificationManager(requestAuthorization: { true }, deliver: { _ in sent += 1 })
        await manager.checkAndNotify(percentUsed: 15, warningThreshold: 80, criticalThreshold: 90,
            enabled: false, mode: .percentOnly,
            jump: .init(mode: .percent, reference: 0, current: 15, limit: 100))
        manager.resetNotifications()
        await manager.waitUntilUsageIdle()
        XCTAssertEqual(sent, 0)
    }

    func testLogoutDuringBoldAuthorizationRetiresActiveAndPendingOldAccountPayloads() async {
        defer { MockURLProtocol.requestHandler = nil }
        let gate = Gate()
        var sent = 0
        let manager = NotificationManager(requestAuthorization: { await gate.pause(); return true }, deliver: { _ in sent += 1 })
        let vm = makeViewModel(manager: manager)
        MockURLProtocol.requestHandler = Self.handler(usedCents: 100)
        await vm.refresh()
        MockURLProtocol.requestHandler = Self.handler(usedCents: 140)
        await vm.refresh()
        await gate.wait()
        MockURLProtocol.requestHandler = Self.handler(usedCents: 180)
        await vm.refresh()
        vm.logout()
        gate.release()
        await manager.waitUntilUsageIdle()
        XCTAssertEqual(sent, 0)
        XCTAssertTrue(manager.notifiedThresholds.isEmpty)
    }

    func testBoldWorkerKeepsOnlyNewestPendingSnapshot() async {
        let gate = Gate()
        var authorizations = 0
        var contents: [UsageNotificationContent] = []
        let manager = NotificationManager(requestAuthorization: {
            authorizations += 1
            if authorizations == 1 { await gate.pause() }
            return true
        }, deliver: { contents.append(.init(title: $0.content.title, body: $0.content.body)) })
        await manager.checkAndNotify(percentUsed: 15, warningThreshold: 80, criticalThreshold: 90,
            enabled: false, mode: .percentOnly,
            jump: .init(mode: .percent, reference: 0, current: 15, limit: 100))
        await gate.wait()
        for current in [30.0, 45.0, 60.0] {
            await manager.checkAndNotify(percentUsed: current, warningThreshold: 80, criticalThreshold: 90,
                enabled: false, mode: .percentOnly,
                jump: .init(mode: .percent, reference: current - 15, current: current, limit: 100))
        }
        gate.release()
        await manager.waitUntilUsageIdle()
        XCTAssertEqual(authorizations, 2)
        XCTAssertEqual(contents.map(\.body), ["Last refresh 0.0% → now 15.0%", "Last refresh 45.0% → now 60.0%"])
    }

    private func makeViewModel(manager: NotificationManager) -> UsageViewModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let vm = UsageViewModel(apiClient: CursorAPIClient(configuration: configuration),
            refreshFeedback: RefreshFeedback(timing: .immediate), notificationManager: manager)
        vm.updateCheckRunner = { .upToDate }
        vm.keychainDeleteHandler = {}
        vm.notificationEnabled = true
        vm.warningThreshold = 80
        vm.criticalThreshold = 90
        vm.jumpEffectEnabled = true
        vm.jumpIntensity = .bold
        vm.authState = .loggedIn
        vm.testHook_setCookieHeader("WorkosCursorSessionToken=test")
        return vm
    }

    private nonisolated static func handler(usedCents: Int) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            let url = request.url!
            let json: String
            switch url.path {
            case "/api/usage-summary":
                json = """
                {"billingCycleStart":"2026-09-01T00:00:00.000Z","billingCycleEnd":"2026-10-01T00:00:00.000Z",
                 "membershipType":"pro","individualUsage":{"plan":{"enabled":true,"used":\(usedCents),
                 "limit":2000,"remaining":\(2000-usedCents),"totalPercentUsed":\(Double(usedCents)/20)}}}
                """
            case "/api/auth/me": json = "{\"email\":\"fixture@example.com\",\"name\":\"Fixture\"}"
            case "/api/usage": json = "{\"startOfMonth\":\"2026-09-01T00:00:00.000Z\"}"
            default:
                return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
        }
    }
}
