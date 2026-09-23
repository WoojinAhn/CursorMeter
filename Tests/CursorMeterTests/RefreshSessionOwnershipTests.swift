import XCTest
import Observation
@testable import CursorMeter

@MainActor
final class RefreshSessionOwnershipTests: XCTestCase {
    private nonisolated static let suppressionKey = "ideAuthSuppressed"
    private nonisolated static let oldCookie = "WorkosCursorSessionToken=old-browser-fixture"
    private nonisolated static let ideCookie = "WorkosCursorSessionToken=new-ide-fixture"
    private nonisolated static let eventsPath = "/api/dashboard/get-filtered-usage-events"
    private nonisolated static let primaryPaths = ["/api/auth/me", "/api/usage-summary", "/api/usage"]

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.suppressionKey)
    }

    override func tearDown() {
        OwnershipURLProtocol.network?.finishPending()
        OwnershipURLProtocol.network = nil
        UserDefaults.standard.removeObject(forKey: Self.suppressionKey)
        super.tearDown()
    }

    private func makeViewModel(
        network: OwnershipNetwork, feedback: RefreshFeedback? = nil
    ) -> UsageViewModel {
        OwnershipURLProtocol.network = network
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OwnershipURLProtocol.self]
        let vm = UsageViewModel(
            apiClient: CursorAPIClient(configuration: configuration),
            refreshFeedback: feedback ?? RefreshFeedback(timing: .immediate)
        )
        vm.updateCheckRunner = { .upToDate }
        vm.keychainDeleteHandler = {}
        vm.sessionExpiredNotifier = {}
        vm.refreshFailingNotifier = {}
        vm.notificationEnabled = false
        vm.weeklyChartEnabled = true
        vm.testHook_setCookieHeader(Self.oldCookie)
        vm.authState = .loggedIn
        return vm
    }

    func testLogoutCancelsDelayedSuccessWithoutAffectingReconnectedRefresh() async throws {
        try await assertLogoutCancelsDelayedResponse { Self.success($0, model: "obsolete") }
    }

    func testLogoutCancelsDelayedNetworkErrorWithoutAffectingReconnectedRefresh() async throws {
        try await assertLogoutCancelsDelayedResponse { _ in .failure(.timedOut) }
    }

    func testLogoutCancelsDelayedUnauthorizedWithoutExpiringReconnectedSession() async throws {
        try await assertLogoutCancelsDelayedResponse { _ in .http(401, Data()) }
    }

    private func assertLogoutCancelsDelayedResponse(
        _ delayed: (OwnershipRequest) -> OwnershipReply
    ) async throws {
        let oldStarted = expectation(description: "Old primary requests are held")
        oldStarted.expectedFulfillmentCount = 3
        let oldStopped = expectation(description: "Logout cancels all old primary requests")
        oldStopped.expectedFulfillmentCount = 3
        let newStarted = expectation(description: "New IDE primary requests are held")
        newStarted.expectedFulfillmentCount = 3
        let network = OwnershipNetwork { request in
            if request.cookie == Self.oldCookie {
                oldStarted.fulfill()
                return nil
            }
            if Self.primaryPaths.contains(request.path) {
                newStarted.fulfill()
                return nil
            }
            return Self.success(request, model: "new")
        }
        network.onStop = { request in
            if request.cookie == Self.oldCookie { oldStopped.fulfill() }
        }
        let vm = makeViewModel(network: network)
        defer { vm.stopAutoRefreshForTests() }
        var deletions = 0
        var expiryNotifications = 0
        var failureNotifications = 0
        vm.keychainDeleteHandler = { deletions += 1 }
        vm.sessionExpiredNotifier = { expiryNotifications += 1 }
        vm.refreshFailingNotifier = { failureNotifications += 1 }
        let old = Task { await vm.refresh() }
        await fulfillment(of: [oldStarted], timeout: 2)
        let oldRequests = network.requests.filter { $0.cookie == Self.oldCookie }
        XCTAssertEqual(oldRequests.count, 3)

        vm.logout()
        XCTAssertEqual(vm.authState, .loggedOut)
        XCTAssertNil(vm.usageData)
        XCTAssertNil(vm.recentUsage.snapshot)
        XCTAssertNil(vm.activeAuthSource)
        XCTAssertEqual(deletions, 1)

        vm.ideCredentialProvider = {
            IDECredential(cookieHeader: Self.ideCookie, expiresAt: .distantFuture)
        }
        vm.connectViaIDE()
        let reconnected = Task { await vm.refresh() }
        await fulfillment(of: [newStarted, oldStopped], timeout: 2)
        let newAttempt = try XCTUnwrap(vm.refreshFeedback.currentAttempt)
        await old.value
        for request in oldRequests {
            XCTAssertFalse(network.respond(to: request, with: delayed(request)),
                           "A cancelled URLProtocol must discard its queued callback")
        }

        XCTAssertEqual(network.cancelledIDs, Set(oldRequests.map(\.id)))
        XCTAssertEqual(vm.authState, .loggedIn)
        XCTAssertNil(vm.activeAuthSource)
        XCTAssertTrue(vm.isLoading, "Retired work must not release the new attempt's busy state")
        XCTAssertTrue(vm.refreshFeedback.isInFlight)
        XCTAssertEqual(vm.refreshFeedback.currentAttempt, newAttempt)
        XCTAssertEqual(vm.refreshFeedback.phase, .updating)
        XCTAssertNil(vm.usageData)
        XCTAssertNil(vm.recentUsage.snapshot)
        XCTAssertNil(vm.lastSuccessAt)
        XCTAssertNil(vm.errorMessage)
        XCTAssertEqual(vm.consecutiveFailureCount, 0)
        XCTAssertEqual(vm.notificationFailureCount, 0)
        XCTAssertEqual(vm.weeklyConsecutiveFailureCount, 0)
        XCTAssertEqual(deletions, 1)
        XCTAssertEqual(expiryNotifications, 0)
        XCTAssertEqual(failureNotifications, 0)

        for request in network.requests where request.cookie == Self.ideCookie {
            XCTAssertTrue(network.respond(to: request, with: Self.success(request, model: "new")))
        }
        await reconnected.value

        XCTAssertEqual(vm.authState, .loggedIn)
        XCTAssertEqual(vm.activeAuthSource, .cursorIDE)
        XCTAssertEqual(vm.recentUsage.snapshot?.candidate.entries.first?.model, "new")
        XCTAssertNotNil(vm.usageData)
        XCTAssertFalse(vm.isLoading)
        XCTAssertFalse(vm.refreshFeedback.isInFlight)
        XCTAssertEqual(vm.consecutiveFailureCount, 0)
        XCTAssertEqual(deletions, 1)
        XCTAssertEqual(network.requests.count, 7)
    }

    func testExplicitReconnectStartsInsidePreviousSessionsThreeSecondCooldown() async throws {
        let instant = ContinuousClock.now
        let feedback = RefreshFeedback(now: { instant }, sleepUntil: { _ in
            try await Task.sleep(for: .seconds(10))
        })
        defer { feedback.invalidate() }
        let network = OwnershipNetwork { Self.success($0, model: "old") }
        let vm = makeViewModel(network: network, feedback: feedback)
        defer { vm.stopAutoRefreshForTests() }
        await vm.refresh()
        let oldAttempt = try XCTUnwrap(feedback.currentAttempt)
        XCTAssertFalse(feedback.isReady)
        XCTAssertEqual(feedback.timeline?.readyAt, instant.advanced(by: .seconds(3)))
        await vm.refresh()
        XCTAssertEqual(network.requests.count, 4, "An ordinary refresh still respects the guard")

        network.handler = { Self.success($0, model: "reconnected") }
        vm.ideCredentialProvider = {
            IDECredential(cookieHeader: Self.ideCookie, expiresAt: .distantFuture)
        }
        vm.connectViaIDE()
        await vm.refresh()

        let newRequests = network.requests.filter { $0.cookie == Self.ideCookie }
        XCTAssertEqual(newRequests.count, 4)
        for path in Self.primaryPaths + [Self.eventsPath] {
            XCTAssertEqual(newRequests.filter { $0.path == path }.count, 1)
        }
        XCTAssertNotEqual(feedback.currentAttempt?.generation, oldAttempt.generation)
        XCTAssertEqual(vm.activeAuthSource, .cursorIDE)
        XCTAssertEqual(vm.recentUsage.snapshot?.candidate.entries.first?.model, "reconnected")
        XCTAssertFalse(vm.isLoading)
        XCTAssertFalse(feedback.isReady, "The new session has its own unchanged three-second guard")
    }

    func testLogoutCancelsOptimisticFirstPageWhileItsParentAwaitsCollection() async throws {
        try await assertLogoutCancelsAwaitedCollection(heldPage: 1)
    }

    func testLogoutCancelsOptimisticSecondPageWithoutRequestingThirdPage() async throws {
        try await assertLogoutCancelsAwaitedCollection(heldPage: 2)
    }

    private func assertLogoutCancelsAwaitedCollection(heldPage: Int) async throws {
        let network = OwnershipNetwork { Self.success($0, model: "cached") }
        let vm = makeViewModel(network: network)
        defer { vm.stopAutoRefreshForTests() }
        await vm.refresh()
        XCTAssertEqual(vm.cachedWeeklyMode, .personal)
        let initialCount = network.requests.count
        let meterUpdated = expectation(description: "Primary results publish before awaiting the collection")
        withObservationTracking { _ = vm.lastSuccessAt } onChange: { meterUpdated.fulfill() }
        let oldPageStarted = expectation(description: "Old optimistic page is held")
        let oldPageStopped = expectation(description: "Logout cancels the awaited optimistic page")
        let newStarted = expectation(description: "New IDE primary requests are held")
        newStarted.expectedFulfillmentCount = 3
        network.onStop = { request in
            if request.cookie == Self.oldCookie, request.path == Self.eventsPath {
                oldPageStopped.fulfill()
            }
        }
        network.handler = { request in
            if request.cookie == Self.oldCookie, request.path == Self.eventsPath {
                if request.body["page"] == heldPage {
                    oldPageStarted.fulfill()
                    return nil
                }
                return .http(200, Self.events("obsolete", total: heldPage + 1))
            }
            if request.cookie == Self.ideCookie, Self.primaryPaths.contains(request.path) {
                newStarted.fulfill()
                return nil
            }
            return Self.success(request, model: "new")
        }
        let old = Task { await vm.refresh() }
        await fulfillment(of: [meterUpdated, oldPageStarted], timeout: 2)
        let oldPage = try XCTUnwrap(network.requests.last {
            $0.cookie == Self.oldCookie && $0.path == Self.eventsPath
        })
        XCTAssertTrue(vm.isLoading)

        vm.logout()
        vm.ideCredentialProvider = {
            IDECredential(cookieHeader: Self.ideCookie, expiresAt: .distantFuture)
        }
        vm.connectViaIDE()
        let reconnected = Task { await vm.refresh() }
        await fulfillment(of: [newStarted, oldPageStopped], timeout: 2)
        XCTAssertTrue(network.cancelledIDs.contains(oldPage.id))
        // Release even when cancellation is broken, so the red test cannot
        // leave its parent waiting forever or block subsequent test cases.
        XCTAssertFalse(network.respond(to: oldPage, with: .http(200, Self.events("obsolete", total: heldPage + 1))))
        await old.value

        let oldPages = network.requests.dropFirst(initialCount).filter {
            $0.cookie == Self.oldCookie && $0.path == Self.eventsPath
        }
        XCTAssertEqual(oldPages.map { $0.body["page"] }, Array(1...heldPage).map(Optional.some))
        XCTAssertTrue(vm.isLoading)
        XCTAssertTrue(vm.refreshFeedback.isInFlight)
        XCTAssertNil(vm.usageData)
        XCTAssertNil(vm.recentUsage.snapshot)
        for request in network.requests where request.cookie == Self.ideCookie {
            _ = network.respond(to: request, with: Self.success(request, model: "new"))
        }
        await reconnected.value
        XCTAssertEqual(vm.recentUsage.snapshot?.candidate.entries.first?.model, "new")
        XCTAssertEqual(vm.activeAuthSource, .cursorIDE)
        XCTAssertFalse(vm.isLoading)
    }

    func testLogoutCancelsAwaitedHardLimitAndItsConcurrentEventCollection() async throws {
        let network = OwnershipNetwork { Self.success($0, model: "cached", membership: "enterprise") }
        let vm = makeViewModel(network: network)
        defer { vm.stopAutoRefreshForTests() }
        await vm.refresh()
        XCTAssertEqual(vm.cachedWeeklyMode, .enterprise(teamId: 77, userId: 42))
        let lastSuccess = vm.lastSuccessAt
        let initialCount = network.requests.count
        let oldStarted = expectation(description: "Primary replies complete while both optimistic requests are held")
        oldStarted.expectedFulfillmentCount = 5
        let oldStopped = expectation(description: "Logout cancels the hard limit and event requests")
        oldStopped.expectedFulfillmentCount = 2
        let newStarted = expectation(description: "New IDE primary requests are held")
        newStarted.expectedFulfillmentCount = 3
        network.onStop = { request in
            if request.cookie == Self.oldCookie { oldStopped.fulfill() }
        }
        network.handler = { request in
            if request.cookie == Self.oldCookie {
                oldStarted.fulfill()
                if Self.primaryPaths.contains(request.path) {
                    return Self.success(request, membership: "enterprise")
                }
                return nil
            }
            if Self.primaryPaths.contains(request.path) {
                newStarted.fulfill()
                return nil
            }
            return Self.success(request, model: "new")
        }
        let old = Task { await vm.refresh() }
        await fulfillment(of: [oldStarted], timeout: 2)
        // The primary callbacks are complete; let their async-let continuations
        // reach the hard-limit await, which precedes any meter publication.
        for _ in 0..<32 { await Task.yield() }
        XCTAssertEqual(vm.lastSuccessAt, lastSuccess)
        let held = network.requests.dropFirst(initialCount).filter { !Self.primaryPaths.contains($0.path) }
        XCTAssertEqual(held.count, 2)

        vm.logout()
        vm.ideCredentialProvider = {
            IDECredential(cookieHeader: Self.ideCookie, expiresAt: .distantFuture)
        }
        vm.connectViaIDE()
        let reconnected = Task { await vm.refresh() }
        await fulfillment(of: [newStarted, oldStopped], timeout: 2)
        XCTAssertTrue(Set(held.map(\.id)).isSubset(of: network.cancelledIDs))
        for request in held {
            XCTAssertFalse(network.respond(to: request, with: Self.success(request, model: "obsolete")))
        }
        await old.value

        XCTAssertTrue(vm.isLoading)
        XCTAssertTrue(vm.refreshFeedback.isInFlight)
        XCTAssertNil(vm.usageData)
        XCTAssertNil(vm.recentUsage.snapshot)
        for request in network.requests where request.cookie == Self.ideCookie {
            _ = network.respond(to: request, with: Self.success(request, model: "new"))
        }
        await reconnected.value
        XCTAssertEqual(vm.recentUsage.snapshot?.candidate.entries.first?.model, "new")
        XCTAssertEqual(vm.activeAuthSource, .cursorIDE)
        XCTAssertFalse(vm.isLoading)
    }

    func testIDEUnauthorizedCancelsOptimisticPageBeforeSingleBrowserFallback() async throws {
        let network = OwnershipNetwork { Self.success($0, model: "cached") }
        let vm = makeViewModel(network: network)
        await vm.refresh()
        XCTAssertEqual(vm.cachedWeeklyMode, .personal)
        let initialCount = network.requests.count
        var deletions = 0
        vm.keychainDeleteHandler = { deletions += 1 }
        vm.ideCredentialProvider = {
            IDECredential(cookieHeader: Self.ideCookie, expiresAt: .distantFuture)
        }
        let ideStarted = expectation(description: "IDE primary and optimistic page one are held")
        ideStarted.expectedFulfillmentCount = 4
        let pageStopped = expectation(description: "IDE rejection cancels optimistic page one")
        network.onStop = { request in
            if request.cookie == Self.ideCookie, request.path == Self.eventsPath {
                pageStopped.fulfill()
            }
        }
        network.handler = { request in
            if request.cookie == Self.ideCookie {
                ideStarted.fulfill()
                return nil
            }
            return Self.success(request, model: "browser")
        }
        let refresh = Task { await vm.refresh() }
        await fulfillment(of: [ideStarted], timeout: 2)
        let ideRequests = network.requests.filter { $0.cookie == Self.ideCookie }
        let oldPage = try XCTUnwrap(ideRequests.first { $0.path == Self.eventsPath })
        XCTAssertEqual(oldPage.body["page"], 1)
        XCTAssertEqual(oldPage.body["teamId"], 0)
        XCTAssertNil(oldPage.body["userId"])
        for request in ideRequests where request.path != Self.eventsPath {
            let reply: OwnershipReply = request.path == "/api/usage-summary"
                ? .http(401, Data()) : Self.success(request, model: "obsolete")
            XCTAssertTrue(network.respond(to: request, with: reply))
        }

        await fulfillment(of: [pageStopped], timeout: 2)
        XCTAssertFalse(network.respond(to: oldPage, with: .http(200, Self.events("obsolete", total: 2))))
        await refresh.value

        let attemptRequests = Array(network.requests.dropFirst(initialCount))
        XCTAssertEqual(attemptRequests.count, 8)
        for cookie in [Self.ideCookie, Self.oldCookie] {
            for path in Self.primaryPaths + [Self.eventsPath] {
                XCTAssertEqual(attemptRequests.filter { $0.cookie == cookie && $0.path == path }.count, 1)
            }
        }
        XCTAssertFalse(attemptRequests.contains { $0.body["page"] == 2 })
        XCTAssertEqual(network.cancelledIDs, [oldPage.id])
        XCTAssertEqual(vm.authState, .loggedIn)
        XCTAssertEqual(vm.activeAuthSource, .browserLogin)
        XCTAssertEqual(vm.recentUsage.snapshot?.candidate.entries.first?.model, "browser")
        XCTAssertEqual(vm.recentUsage.status, .current)
        XCTAssertEqual(vm.cachedWeeklyMode, .personal)
        XCTAssertEqual(vm.consecutiveFailureCount, 0)
        XCTAssertEqual(vm.weeklyConsecutiveFailureCount, 0)
        XCTAssertEqual(deletions, 0)
        XCTAssertFalse(vm.isLoading)
    }

    func testRejectedEnterpriseShapeWithoutMeterDiscardsWeeklyButRetainsFailedRecentSnapshot() async throws {
        for status in [400, 404] {
            let network = OwnershipNetwork { Self.success($0, model: "cached", membership: "enterprise") }
            let vm = makeViewModel(network: network)
            await vm.refresh()
            let snapshot = try XCTUnwrap(vm.recentUsage.snapshot)
            XCTAssertEqual(vm.cachedWeeklyMode, .enterprise(teamId: 77, userId: 42))
            XCTAssertEqual(vm.weeklyChartStatus, .ready)
            let initialCount = network.requests.count
            network.handler = { request in
                switch request.path {
                case "/api/usage-summary", "/api/usage": .http(503, Data())
                case Self.eventsPath: .http(status, Data())
                default: Self.success(request, membership: "enterprise")
                }
            }

            await vm.refresh()

            let failedRequests = Array(network.requests.dropFirst(initialCount))
            XCTAssertEqual(failedRequests.count, 5)
            XCTAssertEqual(failedRequests.filter { $0.path == Self.eventsPath }.count, 1)
            XCTAssertFalse(failedRequests.contains { $0.path == "/api/dashboard/teams" })
            XCTAssertFalse(failedRequests.contains { $0.path == "/api/dashboard/get-team-spend" })
            XCTAssertNil(vm.cachedWeeklyMode)
            XCTAssertNil(vm.weeklyData, "Rejected shape cannot leave the previous chart visible")
            XCTAssertFalse(vm.weeklyChartAvailable)
            XCTAssertEqual(vm.weeklyChartStatus, .unavailable)
            XCTAssertEqual(vm.weeklyConsecutiveFailureCount, 1)
            XCTAssertEqual(vm.recentUsage.snapshot, snapshot)
            XCTAssertEqual(vm.recentUsage.status, .failed)
            XCTAssertEqual(vm.consecutiveFailureCount, 1)
        }
    }

    func testEnterprisePageTwoShapeRejectionPublishesOnlyRediscoveredFirstPage() async throws {
        for status in [400, 404] {
            let network = OwnershipNetwork { Self.success($0, model: "cached", membership: "enterprise") }
            let vm = makeViewModel(network: network)
            await vm.refresh()
            let snapshot = try XCTUnwrap(vm.recentUsage.snapshot)
            let initialCount = network.requests.count
            let retryStarted = expectation(description: "Rediscovered first page is held")
            network.handler = { [weak network] request in
                if request.path == Self.eventsPath {
                    if request.body["page"] == 2 { return .http(status, Data()) }
                    let firstPages = network?.requests.filter {
                        $0.path == Self.eventsPath && $0.body["page"] == 1
                    }.count
                    if firstPages == 2 { return .http(200, Self.events("rejected-first-page", total: 2)) }
                    retryStarted.fulfill()
                    return nil
                }
                return Self.success(request, membership: "enterprise")
            }
            let refresh = Task { await vm.refresh() }
            await fulfillment(of: [retryStarted], timeout: 2)

            XCTAssertEqual(vm.recentUsage.snapshot, snapshot,
                           "A first page whose collection hit a shape rejection is not publishable")
            let retry = try XCTUnwrap(network.requests.last { $0.path == Self.eventsPath })
            XCTAssertTrue(network.respond(to: retry, with: .http(200, Self.events("rediscovered"))))
            await refresh.value

            let attemptRequests = Array(network.requests.dropFirst(initialCount))
            XCTAssertEqual(attemptRequests.count, 9)
            XCTAssertEqual(attemptRequests.filter { $0.path == Self.eventsPath }.map { $0.body["page"] }, [1, 2, 1])
            XCTAssertEqual(attemptRequests.filter { $0.path == "/api/dashboard/teams" }.count, 1)
            XCTAssertEqual(attemptRequests.filter { $0.path == "/api/dashboard/get-team-spend" }.count, 1)
            XCTAssertTrue(attemptRequests.allSatisfy { $0.cookie == Self.oldCookie })
            XCTAssertEqual(vm.recentUsage.snapshot?.candidate.entries.first?.model, "rediscovered")
            XCTAssertEqual(vm.recentUsage.status, .current)
            XCTAssertEqual(vm.weeklyChartStatus, .ready)
            XCTAssertEqual(vm.weeklyConsecutiveFailureCount, 0)
        }
    }

    func testRediscoveredScopeRetainsItsNewOnDemandLatchAcrossSameCycleJitter() async throws {
        try await assertRediscoveredScopeLatch(oldUsed: 8, newUsed: 2_000, expectedActive: true)
    }

    func testRediscoveredScopeImmediatelyDiscardsPreviousScopesOnDemandLatch() async throws {
        try await assertRediscoveredScopeLatch(oldUsed: 2_000, newUsed: 1_999, expectedActive: false)
    }

    private func assertRediscoveredScopeLatch(oldUsed: Int, newUsed: Int, expectedActive: Bool) async throws {
        for rejection in [400, 404] {
            let network = OwnershipNetwork {
                Self.enterpriseScopeReply($0, planUsed: oldUsed, teamID: 77, userID: 42)
            }
            let vm = makeViewModel(network: network)
            await vm.refresh()
            let cycle = try XCTUnwrap(vm.usageData?.cycleStartDate)
            XCTAssertEqual(vm.cachedWeeklyMode, .enterprise(teamId: 77, userId: 42))
            XCTAssertEqual(vm.usageData?.isOnDemandActive, oldUsed >= 2_000)
            let initialCount = network.requests.count
            network.handler = { request in
                if request.path == Self.eventsPath, request.body["teamId"] == 77 {
                    return .http(rejection, Data())
                }
                return Self.enterpriseScopeReply(request, planUsed: newUsed, teamID: 88, userID: 99)
            }

            await vm.refresh()

            let switchedRequests = Array(network.requests.dropFirst(initialCount))
            XCTAssertEqual(switchedRequests.count, 8)
            for path in Self.primaryPaths {
                XCTAssertEqual(switchedRequests.filter { $0.path == path }.count, 1)
            }
            let eventRequests = switchedRequests.filter { $0.path == Self.eventsPath }
            XCTAssertEqual(eventRequests.map { $0.body["teamId"] }, [77, 88])
            XCTAssertEqual(eventRequests.map { $0.body["userId"] }, [42, 99])
            XCTAssertEqual(vm.cachedWeeklyMode, .enterprise(teamId: 88, userId: 99))
            XCTAssertEqual(vm.recentUsage.snapshot?.candidate.entries.first?.model, "team-88-user-99")
            XCTAssertEqual(vm.usageData?.planUsedCents, newUsed)
            XCTAssertEqual(vm.usageData?.cycleStartDate, cycle)
            XCTAssertEqual(vm.usageData?.isOnDemandActive, expectedActive,
                           "The current meter must use only the newly authenticated scope's latch")
            XCTAssertEqual(vm.consecutiveFailureCount, 0)
            let switchedCount = network.requests.count
            network.handler = {
                Self.enterpriseScopeReply($0, planUsed: 1_999, teamID: 88, userID: 99)
            }

            await vm.refresh()

            let nextRequests = Array(network.requests.dropFirst(switchedCount))
            XCTAssertEqual(nextRequests.count, 5)
            XCTAssertFalse(nextRequests.contains { $0.path == "/api/dashboard/teams" })
            XCTAssertFalse(nextRequests.contains { $0.path == "/api/dashboard/get-team-spend" })
            XCTAssertEqual(vm.usageData?.cycleStartDate, cycle)
            XCTAssertEqual(vm.usageData?.planUsedCents, 1_999)
            XCTAssertEqual(vm.usageData?.wouldActivateOnDemand, false)
            XCTAssertEqual(vm.usageData?.isOnDemandActive, expectedActive,
                           "Same-cycle jitter must retain the new scope's latch, never the previous scope's latch")
            XCTAssertEqual(vm.cachedWeeklyMode, .enterprise(teamId: 88, userId: 99))
            XCTAssertEqual(vm.consecutiveFailureCount, 0)
        }
    }

    private nonisolated static func enterpriseScopeReply(
        _ request: OwnershipRequest, planUsed: Int, teamID: Int, userID: Int
    ) -> OwnershipReply {
        switch request.path {
        case "/api/usage-summary":
            return .http(200, Data("""
            {"membershipType":"enterprise","billingCycleStart":"2026-09-01T00:00:00.000Z",
             "individualUsage":{"plan":{"enabled":true,"used":\(planUsed),"limit":2000},
             "onDemand":{"enabled":true,"used":0,"limit":4000}}}
            """.utf8))
        case "/api/dashboard/teams":
            return .http(200, Data("{\"teams\":[{\"id\":\(teamID),\"name\":\"Fixture Team\"}]}".utf8))
        case "/api/dashboard/get-team-spend":
            return .http(200, Data("{\"teamMemberSpend\":[{\"userId\":\(userID),\"email\":\"fixture@example.com\"}]}".utf8))
        default:
            return success(request, model: "team-\(teamID)-user-\(userID)", membership: "enterprise")
        }
    }

    private nonisolated static func events(_ model: String, total: Int = 1) -> Data {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        return Data("""
        {"usageEventsDisplay":[{"timestamp":"\(timestamp)","model":"\(model)",
        "kind":"included","requestsCosts":1,"chargedCents":15}],"totalUsageEventsCount":\(total)}
        """.utf8)
    }

    private nonisolated static func success(
        _ request: OwnershipRequest, model: String = "fixture", membership: String = "pro"
    ) -> OwnershipReply {
        let data: Data
        switch request.path {
        case "/api/auth/me":
            data = Data("{\"email\":\"fixture@example.com\",\"name\":\"Fixture\",\"sub\":\"fixture-subject\"}".utf8)
        case "/api/usage-summary":
            data = Data("""
            {"membershipType":"\(membership)","individualUsage":{"plan":{
            "enabled":true,"used":8,"limit":2000,"remaining":1992,"totalPercentUsed":0.4}}}
            """.utf8)
        case "/api/usage":
            data = Data("{\"startOfMonth\":\"2026-09-01T00:00:00.000Z\"}".utf8)
        case "/api/dashboard/teams":
            data = Data("{\"teams\":[{\"id\":77,\"name\":\"Fixture Team\"}]}".utf8)
        case "/api/dashboard/get-team-spend":
            data = Data("{\"teamMemberSpend\":[{\"userId\":42,\"email\":\"fixture@example.com\"}]}".utf8)
        case "/api/dashboard/get-hard-limit":
            data = Data("{}".utf8)
        case eventsPath:
            data = events(model)
        default:
            return .http(404, Data())
        }
        return .http(200, data)
    }
}

private enum OwnershipReply: Sendable {
    case http(Int, Data)
    case failure(URLError.Code)
}

private struct OwnershipRequest: Sendable {
    let id: UUID
    let path: String
    let cookie: String
    let body: [String: Int]

    init(id: UUID, request: URLRequest) {
        self.id = id
        path = request.url!.path
        cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        body = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Int]) ?? [:]
    }
}

private final class OwnershipNetwork: @unchecked Sendable {
    typealias Handler = @Sendable (OwnershipRequest) -> OwnershipReply?
    private let lock = NSLock()
    private var storedHandler: Handler
    private var storedOnStop: (@Sendable (OwnershipRequest) -> Void)?
    private var protocols: [UUID: OwnershipURLProtocol] = [:]
    private var recordedRequests: [OwnershipRequest] = []
    private var stoppedIDs = Set<UUID>()

    init(handler: @escaping Handler) { storedHandler = handler }

    var handler: Handler {
        get { lock.withLock { storedHandler } }
        set { lock.withLock { storedHandler = newValue } }
    }

    var onStop: (@Sendable (OwnershipRequest) -> Void)? {
        get { lock.withLock { storedOnStop } }
        set { lock.withLock { storedOnStop = newValue } }
    }

    var requests: [OwnershipRequest] { lock.withLock { recordedRequests } }
    var cancelledIDs: Set<UUID> { lock.withLock { stoppedIDs } }

    func started(_ loader: OwnershipURLProtocol, request: OwnershipRequest) {
        lock.withLock {
            protocols[request.id] = loader
            recordedRequests.append(request)
        }
        if let reply = handler(request) { _ = loader.deliver(reply) }
    }

    func stopped(_ request: OwnershipRequest) {
        lock.withLock { _ = stoppedIDs.insert(request.id) }
        onStop?(request)
    }

    func respond(to request: OwnershipRequest, with reply: OwnershipReply) -> Bool {
        let loader = lock.withLock { protocols[request.id] }
        return loader?.deliver(reply) ?? false
    }

    func finishPending() {
        let loaders = lock.withLock { Array(protocols.values) }
        for loader in loaders { _ = loader.deliver(.failure(.cancelled)) }
    }
}

private final class OwnershipURLProtocol: URLProtocol {
    nonisolated(unsafe) static var network: OwnershipNetwork?
    private let stateLock = NSRecursiveLock()
    private var isPending = true
    private weak var owner: OwnershipNetwork?
    private var captured: OwnershipRequest?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let captured = OwnershipRequest(id: UUID(), request: request)
        stateLock.withLock {
            self.captured = captured
            owner = Self.network
        }
        owner?.started(self, request: captured)
    }

    override func stopLoading() {
        stateLock.withLock {
            guard isPending else { return }
            isPending = false
            if let captured { owner?.stopped(captured) }
        }
    }

    // Holding this lock through delivery prevents a queued reply from calling
    // URLProtocolClient after stopLoading has retired the URLSession task.
    func deliver(_ reply: OwnershipReply) -> Bool {
        stateLock.withLock {
            guard isPending else { return false }
            isPending = false
            switch reply {
            case let .http(status, data):
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            case let .failure(code):
                client?.urlProtocol(self, didFailWithError: URLError(code))
            }
            return true
        }
    }
}
