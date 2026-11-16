import XCTest
@testable import CursorMeter

@MainActor
final class SharedUsageRefreshTests: XCTestCase {
    nonisolated private static let cookie = "WorkosCursorSessionToken=shared-fixture"
    private let now = Date(timeIntervalSince1970: 1_794_873_500)

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeViewModel(provider: SharedUsageFixtureProvider, network: SharedRefreshNetwork = .init(),
                               capturedCookie: String? = SharedUsageRefreshTests.cookie) -> UsageViewModel {
        MockURLProtocol.requestHandler = { try network.respond($0) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let controller = SharedUsageController(provider: provider, now: { self.now })
        let suite = "SharedUsageRefreshTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let vm = makeTestUsageViewModel(apiClient: CursorAPIClient(configuration: configuration),
            refreshFeedback: RefreshFeedback(timing: .immediate), sharedUsage: controller, defaults: defaults)
        vm.keychainLoadHandler = { nil }
        if let capturedCookie { vm.testHook_setCookieHeader(capturedCookie) }
        vm.notificationEnabled = false
        vm.authState = .loggedIn
        return vm
    }

    func testSharedPlanPublishesIndependentSnapshotWithoutLegacyCollection() async {
        let network = SharedRefreshNetwork()
        let vm = makeViewModel(provider: SharedUsageFixtureProvider(), network: network)
        await vm.refresh()
        XCTAssertEqual(vm.sharedUsage.mode, .sharedWeekly)
        XCTAssertEqual(vm.sharedUsage.snapshot?.weekly.value?.percentUsed, 25)
        XCTAssertNil(vm.usageData)
        XCTAssertNil(vm.splitUsage.snapshot)
        XCTAssertNil(vm.recentUsage.snapshot)
        XCTAssertNil(vm.weeklyData)
        XCTAssertNil(vm.lastJump)
        XCTAssertEqual(vm.authenticatedUserInfo?.sub, "shared-subject")
        XCTAssertEqual(network.requests.map { $0.url!.path }.sorted(), ["/api/auth/me", "/api/usage", "/api/usage-summary"])
        XCTAssertEqual(vm.authState, .loggedIn)
        XCTAssertEqual(vm.activeAuthSource, .browserLogin)
        XCTAssertEqual(vm.consecutiveFailureCount, 0)
    }

    func testSharedRPC401KeepsAcceptedIDEAuthAndDoesNotFallback() async {
        let network = SharedRefreshNetwork()
        let provider = SharedUsageFixtureProvider()
        await provider.setFailures(prepaid: .unauthorized, cap: .forbidden)
        let vm = makeViewModel(provider: provider, network: network)
        vm.ideCredentialProvider = { IDECredential(cookieHeader: "WorkosCursorSessionToken=ide-fixture", expiresAt: .distantFuture) }
        var deletions = 0
        var expiries = 0
        vm.keychainDeleteHandler = { deletions += 1 }
        vm.sessionExpiredNotifier = { expiries += 1 }
        await vm.refresh()
        XCTAssertEqual(vm.authState, .loggedIn)
        XCTAssertEqual(vm.activeAuthSource, .cursorIDE)
        XCTAssertEqual(vm.sharedUsage.snapshot?.weekly.value?.percentUsed, 25)
        XCTAssertEqual(vm.consecutiveFailureCount, 1)
        XCTAssertNotNil(vm.errorMessage)
        XCTAssertEqual(deletions, 0)
        XCTAssertEqual(expiries, 0)
        XCTAssertTrue(network.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == "WorkosCursorSessionToken=ide-fixture" })
    }

    func testColdDetectorFailureSuppressesMonthlyDataWithoutExpiringAuth() async {
        let provider = SharedUsageFixtureProvider()
        await provider.setFailures(plan: .invalidResponse)
        let vm = makeViewModel(provider: provider)
        await vm.refresh()
        XCTAssertEqual(vm.sharedUsage.mode, .unavailable)
        XCTAssertNil(vm.usageData)
        XCTAssertEqual(vm.authState, .loggedIn)
        XCTAssertEqual(vm.consecutiveFailureCount, 1)
    }

    func testKnownSharedDetectionFailureKeepsStaleValues() async {
        let provider = SharedUsageFixtureProvider()
        let vm = makeViewModel(provider: provider)
        await vm.refresh()
        let success = vm.lastSuccessAt
        await provider.setFailures(plan: .unauthorized)
        await vm.refresh()
        XCTAssertEqual(vm.sharedUsage.mode, .sharedWeekly)
        XCTAssertEqual(vm.sharedUsage.snapshot?.weekly.value?.percentUsed, 25)
        XCTAssertTrue(vm.isDataStale)
        XCTAssertEqual(vm.lastSuccessAt, success)
        XCTAssertEqual(vm.consecutiveFailureCount, 1)
        XCTAssertNil(vm.usageData)
        XCTAssertEqual(vm.authState, .loggedIn)
    }

    func testVerifiedLegacyRestoresExistingRefreshAfterSharedMode() async {
        let provider = SharedUsageFixtureProvider()
        let vm = makeViewModel(provider: provider)
        await vm.refresh()
        await provider.setPlan(#"{"isMerged":false}"#)
        await vm.refresh()
        XCTAssertEqual(vm.sharedUsage.mode, .legacy)
        XCTAssertNil(vm.sharedUsage.snapshot)
        XCTAssertEqual(vm.usageData?.planUsedCents, 8)
        XCTAssertNotNil(vm.recentUsage.snapshot)
    }

    func testTransitionFromLegacyRetiresPriorCollectorsAndJumpState() async {
        let provider = SharedUsageFixtureProvider()
        await provider.setPlan(#"{"isMerged":false}"#)
        let network = SharedRefreshNetwork()
        let vm = makeViewModel(provider: provider, network: network)
        await vm.refresh()
        XCTAssertNotNil(vm.recentUsage.snapshot)
        let count = network.requests.count
        await provider.setPlan(#"{"isMerged":true,"planInfo":{"includedUsagePeriod":"INCLUDED_USAGE_PERIOD_WEEKLY","includedUsageResetsAt":"1794873600000"}}"#)
        await vm.refresh()
        XCTAssertEqual(network.requests.count - count, 3)
        XCTAssertNil(vm.usageData)
        XCTAssertNil(vm.recentUsage.snapshot)
        XCTAssertNil(vm.weeklyData)
        XCTAssertNil(vm.cachedWeeklyMode)
        XCTAssertNil(vm.lastJump)
    }

    func testKnownLegacyDetectionFailureKeepsVerifiedLegacyPath() async {
        let provider = SharedUsageFixtureProvider()
        await provider.setPlan(#"{"isMerged":false}"#)
        let vm = makeViewModel(provider: provider)
        await vm.refresh()
        await provider.setFailures(plan: .transport)
        await vm.refresh()
        XCTAssertEqual(vm.sharedUsage.mode, .legacy)
        XCTAssertEqual(vm.usageData?.planUsedCents, 8)
        XCTAssertEqual(vm.consecutiveFailureCount, 0)
    }

    func testKnownLegacyOwnerSurvivesSummaryAndDetectorFailureTogether() async {
        let provider = SharedUsageFixtureProvider()
        await provider.setPlan(#"{"isMerged":false}"#)
        let network = SharedRefreshNetwork()
        let vm = makeViewModel(provider: provider, network: network)
        await vm.refresh()
        network.configure(summaryStatus: 503)
        await provider.setFailures(plan: .transport)
        await vm.refresh()
        XCTAssertEqual(vm.sharedUsage.mode, .legacy)
        XCTAssertNotNil(vm.usageData)
        XCTAssertEqual(vm.authState, .loggedIn)
    }

    func testColdUnknownScopeNeverFetchesPersonalWallet() async {
        let provider = SharedUsageFixtureProvider()
        let network = SharedRefreshNetwork(membership: "future-scope")
        let vm = makeViewModel(provider: provider, network: network)
        await vm.refresh()
        XCTAssertEqual(vm.sharedUsage.mode, .unavailable)
        XCTAssertNil(vm.sharedUsage.snapshot)
        XCTAssertNil(vm.usageData)
        let calls = await provider.calls
        XCTAssertEqual(calls, ["plan"])
    }

    func testUnknownScopeKeepsSameOwnerSharedSnapshotStaleWithoutWalletFetch() async {
        for summaryStatus in [200, 503] {
            let provider = SharedUsageFixtureProvider()
            let network = SharedRefreshNetwork()
            let vm = makeViewModel(provider: provider, network: network)
            await vm.refresh()
            let previousCalls = await provider.calls.count
            network.configure(membership: "future-scope", summaryStatus: summaryStatus)
            await vm.refresh()
            XCTAssertEqual(vm.sharedUsage.mode, .sharedWeekly)
            XCTAssertEqual(vm.sharedUsage.snapshot?.credit.value?.remainingCents, 6200)
            XCTAssertTrue(vm.sharedUsage.isStale)
            XCTAssertEqual(vm.authenticatedUserInfo?.sub, "shared-subject")
            let calls = await provider.calls.count
            XCTAssertEqual(calls - previousCalls, 1)
        }
    }

    func testPrimaryProfileFailureMarksSameOwnerSharedDataStale() async {
        let provider = SharedUsageFixtureProvider()
        let network = SharedRefreshNetwork()
        let vm = makeViewModel(provider: provider, network: network)
        await vm.refresh()
        let success = vm.lastSuccessAt
        network.configure(profileStatus: 503)
        await vm.refresh()
        XCTAssertEqual(vm.sharedUsage.mode, .sharedWeekly)
        XCTAssertEqual(vm.sharedUsage.snapshot?.weekly.value?.percentUsed, 25)
        XCTAssertTrue(vm.isDataStale)
        XCTAssertEqual(vm.lastSuccessAt, success)
        XCTAssertEqual(vm.authState, .loggedIn)
    }

    func testExplicitUnsupportedPlanRetiresSharedSnapshotWhenSummaryFails() async {
        let provider = SharedUsageFixtureProvider()
        let network = SharedRefreshNetwork()
        let vm = makeViewModel(provider: provider, network: network)
        await vm.refresh()
        let previousCalls = await provider.calls.count
        network.configure(summaryStatus: 503)
        await provider.setPlan(#"{"isMerged":true,"planInfo":{"includedUsagePeriod":"INCLUDED_USAGE_PERIOD_MONTHLY"}}"#)
        await vm.refresh()
        XCTAssertEqual(vm.sharedUsage.mode, .unsupported)
        XCTAssertNil(vm.sharedUsage.snapshot)
        XCTAssertNil(vm.lastSuccessAt)
        XCTAssertNil(vm.usageData)
        let calls = await provider.calls.count
        XCTAssertEqual(calls - previousCalls, 1)
    }

    func testKnownLegacyIDEProfile404AndDetectorFailurePreserveLegacyOwner() async {
        let provider = SharedUsageFixtureProvider()
        await provider.setPlan(#"{"isMerged":false}"#)
        let network = SharedRefreshNetwork()
        let vm = makeViewModel(provider: provider, network: network)
        vm.ideCredentialProvider = { IDECredential(cookieHeader: "WorkosCursorSessionToken=ide-fixture", expiresAt: .distantFuture) }
        await vm.refresh()
        XCTAssertEqual(vm.sharedUsage.mode, .legacy)
        let previousCalls = await provider.calls.count
        network.configure(profileStatus: 404)
        await provider.setFailures(plan: .transport)
        await vm.refresh()
        XCTAssertEqual(vm.sharedUsage.mode, .legacy)
        XCTAssertEqual(vm.usageData?.planUsedCents, 8)
        XCTAssertEqual(vm.authenticatedUserInfo?.sub, "shared-subject")
        XCTAssertEqual(vm.authState, .loggedIn)
        XCTAssertEqual(vm.activeAuthSource, .cursorIDE)
        XCTAssertEqual(vm.consecutiveFailureCount, 0)
        let calls = await provider.calls.count
        XCTAssertEqual(calls - previousCalls, 1)
    }

    func testLegacyToSharedWithIDEProfile404CannotFetchWalletOrPublishMonthlyUsage() async {
        let provider = SharedUsageFixtureProvider()
        await provider.setPlan(#"{"isMerged":false}"#)
        let network = SharedRefreshNetwork()
        let vm = makeViewModel(provider: provider, network: network)
        vm.ideCredentialProvider = { IDECredential(cookieHeader: "WorkosCursorSessionToken=ide-fixture", expiresAt: .distantFuture) }
        await vm.refresh()
        let previousCalls = await provider.calls.count
        network.configure(profileStatus: 404)
        await provider.setPlan(#"{"isMerged":true,"planInfo":{"includedUsagePeriod":"INCLUDED_USAGE_PERIOD_WEEKLY","includedUsageResetsAt":"1794873600000"}}"#)
        await vm.refresh()
        XCTAssertTrue(vm.sharedUsage.suppressesLegacyMeter)
        XCTAssertNil(vm.sharedUsage.snapshot)
        XCTAssertNil(vm.usageData)
        XCTAssertEqual(vm.authenticatedUserInfo?.sub, "shared-subject")
        XCTAssertEqual(vm.authState, .loggedIn)
        XCTAssertEqual(vm.activeAuthSource, .cursorIDE)
        let calls = await provider.calls.count
        XCTAssertEqual(calls - previousCalls, 1)
    }

    func testSameIDEProfile404And503PreserveVerifiedSharedSnapshotWithoutWalletFetch() async {
        for status in [404, 503] {
            let provider = SharedUsageFixtureProvider()
            let network = SharedRefreshNetwork()
            let vm = makeViewModel(provider: provider, network: network)
            vm.ideCredentialProvider = { IDECredential(cookieHeader: "WorkosCursorSessionToken=ide-fixture", expiresAt: .distantFuture) }
            await vm.refresh()
            let lastSuccess = vm.lastSuccessAt
            let previousCalls = await provider.calls.count
            network.configure(profileStatus: status)
            await vm.refresh()
            XCTAssertEqual(vm.sharedUsage.mode, .sharedWeekly)
            XCTAssertEqual(vm.sharedUsage.snapshot?.credit.value?.remainingCents, 6200)
            XCTAssertEqual(vm.sharedUsage.snapshot?.weekly.value?.percentUsed, 25)
            XCTAssertTrue(vm.sharedUsage.isStale)
            XCTAssertEqual(vm.lastSuccessAt, lastSuccess)
            XCTAssertEqual(vm.authenticatedUserInfo?.sub, "shared-subject")
            XCTAssertEqual(vm.authState, .loggedIn)
            XCTAssertEqual(vm.activeAuthSource, .cursorIDE)
            let calls = await provider.calls.count
            XCTAssertEqual(calls - previousCalls, 1)
            XCTAssertTrue(network.requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == "WorkosCursorSessionToken=ide-fixture" })
        }
    }

    func testColdIDEProfile404CannotEstablishSharedIdentity() async {
        let provider = SharedUsageFixtureProvider()
        let network = SharedRefreshNetwork()
        network.configure(profileStatus: 404)
        let vm = makeViewModel(provider: provider, network: network)
        vm.ideCredentialProvider = { IDECredential(cookieHeader: "WorkosCursorSessionToken=ide-fixture", expiresAt: .distantFuture) }
        await vm.refresh()
        XCTAssertEqual(vm.sharedUsage.mode, .unavailable)
        XCTAssertNil(vm.sharedUsage.snapshot)
        XCTAssertNil(vm.authenticatedUserInfo)
        let calls = await provider.calls
        XCTAssertEqual(calls, ["plan"])
    }

    func testChangedIDECredentialProfile404CannotReusePreviousSharedOwner() async {
        let provider = SharedUsageFixtureProvider()
        let network = SharedRefreshNetwork()
        let vm = makeViewModel(provider: provider, network: network)
        vm.ideCredentialProvider = { IDECredential(cookieHeader: "WorkosCursorSessionToken=ide-fixture", expiresAt: .distantFuture) }
        await vm.refresh()
        let previousCalls = await provider.calls.count
        network.configure(profileStatus: 404)
        vm.ideCredentialProvider = { IDECredential(cookieHeader: "WorkosCursorSessionToken=changed-ide-fixture", expiresAt: .distantFuture) }
        await vm.refresh()
        XCTAssertEqual(vm.sharedUsage.mode, .unavailable)
        XCTAssertNil(vm.sharedUsage.snapshot)
        XCTAssertNil(vm.authenticatedUserInfo)
        let calls = await provider.calls.count
        XCTAssertEqual(calls - previousCalls, 1)
    }

    func testAccountSwitchCannotKeepPreviousWalletWhenDetectionFails() async {
        let provider = SharedUsageFixtureProvider()
        let network = SharedRefreshNetwork()
        let vm = makeViewModel(provider: provider, network: network)
        await vm.refresh()
        network.configure(subject: "different-subject")
        await provider.setFailures(plan: .transport)
        await vm.refresh()
        XCTAssertNil(vm.sharedUsage.snapshot)
        XCTAssertEqual(vm.sharedUsage.mode, .unavailable)
        XCTAssertEqual(vm.authenticatedUserInfo?.sub, "different-subject")
    }

    func testLogoutDiscardsLateSharedSuccessAndErrors() async {
        for error in [nil, .transport, .unauthorized] as [CursorSharedAPIError?] {
            let provider = SharedUsageFixtureProvider()
            let started = expectation(description: "Shared period request suspended")
            await provider.holdNextPeriod { started.fulfill() }
            let vm = makeViewModel(provider: provider)
            let refresh = Task { await vm.refresh() }
            await fulfillment(of: [started], timeout: 2)
            vm.logout()
            await provider.finishHeldPeriod(error: error)
            await refresh.value
            XCTAssertEqual(vm.authState, .loggedOut)
            XCTAssertNil(vm.sharedUsage.snapshot)
            XCTAssertNil(vm.authenticatedUserInfo)
            XCTAssertNil(vm.errorMessage)
            XCTAssertEqual(vm.consecutiveFailureCount, 0)
        }
    }

    func testReloginDiscardsOldOwnerResponseWithoutClobberingNewSuccess() async {
        for error in [nil, .transport, .unauthorized] as [CursorSharedAPIError?] {
            let provider = SharedUsageFixtureProvider()
            let started = expectation(description: "Old owner's shared period suspended")
            await provider.holdNextPeriod { started.fulfill() }
            let network = SharedRefreshNetwork()
            let vm = makeViewModel(provider: provider, network: network)
            let old = Task { await vm.refresh() }
            await fulfillment(of: [started], timeout: 2)
            vm.logout()
            network.configure(subject: "reconnected-subject")
            vm.keychainSaveHandler = { _ in }
            vm.onLoginSuccess(cookieHeader: "WorkosCursorSessionToken=reconnected")
            await vm.refresh()
            vm.stopAutoRefreshForTests()
            let success = vm.lastSuccessAt
            await provider.finishHeldPeriod(error: error)
            await old.value
            XCTAssertEqual(vm.authState, .loggedIn)
            XCTAssertEqual(vm.authenticatedUserInfo?.sub, "reconnected-subject")
            XCTAssertEqual(vm.sharedUsage.snapshot?.weekly.availability, .current)
            XCTAssertEqual(vm.lastSuccessAt, success)
            XCTAssertEqual(vm.consecutiveFailureCount, 0)
            XCTAssertNil(vm.errorMessage)
        }
    }

    func testRejectedIDEWithoutBrowserCredentialClearsSharedOwner() async {
        let network = SharedRefreshNetwork()
        let vm = makeViewModel(provider: SharedUsageFixtureProvider(), network: network, capturedCookie: nil)
        vm.ideCredentialProvider = { IDECredential(cookieHeader: "WorkosCursorSessionToken=ide-fixture", expiresAt: .distantFuture) }
        await vm.refresh()
        XCTAssertEqual(vm.sharedUsage.snapshot?.credit.value?.remainingCents, 6200)
        network.configure(profileStatus: 401)
        await vm.refresh()
        XCTAssertEqual(vm.authState, .loginRequired)
        XCTAssertNil(vm.sharedUsage.snapshot)
        XCTAssertNil(vm.authenticatedUserInfo)
    }

    func testPartialSharedRefreshCannotReuseLegacySuccessTimestamp() async {
        let provider = SharedUsageFixtureProvider()
        await provider.setPlan(#"{"isMerged":false}"#)
        let vm = makeViewModel(provider: provider)
        await vm.refresh()
        XCTAssertNotNil(vm.lastSuccessAt)
        await provider.setPlan(#"{"isMerged":true,"planInfo":{"includedUsagePeriod":"INCLUDED_USAGE_PERIOD_WEEKLY","includedUsageResetsAt":"1794873600000"}}"#)
        await provider.setFailures(prepaid: .transport)
        await vm.refresh()
        XCTAssertNil(vm.lastSuccessAt)
        XCTAssertEqual(vm.sharedUsage.snapshot?.weekly.lastSuccessAt, now)
    }

    func testSharedSuccessRetainsPeriodicUpdateChecks() async {
        let vm = makeViewModel(provider: SharedUsageFixtureProvider())
        await vm.refresh()
        let checked = expectation(description: "Successful shared refresh checks overdue app update")
        vm.updateCheckRunner = { checked.fulfill(); return .upToDate }
        vm.testHook_setLastUpdateCheckAt(.distantPast)
        await vm.refresh()
        await fulfillment(of: [checked], timeout: 1)
    }

    func testExplicitTeamTransitionMatrixRetiresPersonalSharedWallet() async {
        for membership in ["team", "teams", "enterprise"] {
            for profileStatus in [200, 404] {
                for detectorFails in [false, true] {
                    let scenario = "\(membership), profile \(profileStatus), detector failure \(detectorFails)"
                    let provider = SharedUsageFixtureProvider()
                    let network = SharedRefreshNetwork()
                    let vm = makeViewModel(provider: provider, network: network)
                    vm.ideCredentialProvider = { IDECredential(cookieHeader: "WorkosCursorSessionToken=ide-fixture", expiresAt: .distantFuture) }
                    await vm.refresh()
                    let previousCalls = await provider.calls.count
                    network.configure(membership: membership, profileStatus: profileStatus)
                    if detectorFails { await provider.setFailures(plan: .transport) }
                    await vm.refresh()
                    XCTAssertEqual(vm.sharedUsage.mode, .unsupported, scenario)
                    XCTAssertNil(vm.sharedUsage.snapshot, scenario)
                    XCTAssertNil(vm.sharedUsage.lastCompleteSuccessAt, scenario)
                    XCTAssertNil(vm.lastSuccessAt, scenario)
                    XCTAssertNil(vm.usageData, scenario)
                    let calls = await provider.calls.count
                    XCTAssertEqual(calls - previousCalls, 1, scenario)
                }
            }
        }
    }

    func testTeamSharedPlanNeverMixesPersonalWallet() async {
        let provider = SharedUsageFixtureProvider()
        let network = SharedRefreshNetwork(membership: "enterprise")
        let vm = makeViewModel(provider: provider, network: network)
        await vm.refresh()
        XCTAssertEqual(vm.sharedUsage.mode, .unsupported)
        XCTAssertNil(vm.sharedUsage.snapshot)
        XCTAssertNil(vm.usageData)
        let calls = await provider.calls
        XCTAssertEqual(calls, ["plan"])
    }
}

private final class SharedRefreshNetwork: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []
    private var membership: String
    private var subject = "shared-subject"
    private var profileStatus = 200
    private var summaryStatus = 200
    init(membership: String = "pro") { self.membership = membership }
    func configure(membership: String? = nil, subject: String? = nil,
                   profileStatus: Int? = nil, summaryStatus: Int? = nil) {
        lock.withLock {
            if let membership { self.membership = membership }
            if let subject { self.subject = subject }
            if let profileStatus { self.profileStatus = profileStatus }
            if let summaryStatus { self.summaryStatus = summaryStatus }
        }
    }
    var requests: [URLRequest] { lock.withLock { storedRequests } }
    func respond(_ request: URLRequest) throws -> (HTTPURLResponse, Data) {
        let (membership, subject, profileStatus, summaryStatus) = lock.withLock {
            storedRequests.append(request)
            return (self.membership, self.subject, self.profileStatus, self.summaryStatus)
        }
        let status = request.url!.path == "/api/auth/me" ? profileStatus
            : (request.url!.path == "/api/usage-summary" ? summaryStatus : 200)
        let json: String
        switch request.url!.path {
        case "/api/auth/me": json = "{\"email\":\"fixture@example.com\",\"name\":\"Fixture\",\"sub\":\"\(subject)\"}"
        case "/api/usage-summary": json = "{\"membershipType\":\"\(membership)\",\"individualUsage\":{\"plan\":{\"enabled\":true,\"used\":8,\"limit\":2000,\"remaining\":1992,\"totalPercentUsed\":0.4}}}"
        case "/api/usage": json = #"{"startOfMonth":"2026-11-01T00:00:00Z"}"#
        case "/api/dashboard/get-filtered-usage-events": json = #"{"usageEventsDisplay":[],"totalUsageEventsCount":0}"#
        case "/api/dashboard/teams": json = #"{"teams":[]}"#
        default: json = "{}"
        }
        return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(json.utf8))
    }
}
