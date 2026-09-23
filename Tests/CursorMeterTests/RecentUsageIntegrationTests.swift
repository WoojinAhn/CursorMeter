import XCTest
@testable import CursorMeter

@MainActor
final class RecentUsageIntegrationTests: XCTestCase {
    private nonisolated static let suppressionKey = "ideAuthSuppressed"

    @MainActor private final class Gate {
        private var paused = false
        private var waiter: CheckedContinuation<Void, Never>?
        private var arrival: CheckedContinuation<Void, Never>?

        func pause() async {
            paused = true
            arrival?.resume()
            arrival = nil
            await withCheckedContinuation { waiter = $0 }
        }

        func waitForPause() async {
            if !paused { await withCheckedContinuation { arrival = $0 } }
        }

        func release() { waiter?.resume(); waiter = nil }
    }

    private final class Requests: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: [String] = []

        func append(_ request: URLRequest) {
            lock.withLock { paths.append(request.url!.path) }
        }

        var all: [String] { lock.withLock { paths } }
    }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.suppressionKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.suppressionKey)
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeViewModel(feedback: RefreshFeedback? = nil) -> UsageViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let vm = UsageViewModel(
            apiClient: CursorAPIClient(configuration: config),
            refreshFeedback: feedback ?? RefreshFeedback(timing: .immediate)
        )
        vm.updateCheckRunner = { .upToDate }
        vm.keychainDeleteHandler = {}
        vm.sessionExpiredNotifier = {}
        vm.refreshFailingNotifier = {}
        vm.notificationEnabled = false
        vm.testHook_setCookieHeader("WorkosCursorSessionToken=fixture")
        vm.authState = .loggedIn
        return vm
    }

    func testTimeZonePreferenceDefaultsToLocalAndPersistsUTC() {
        let key = "recentUsageTimeZone"
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        let vm = makeViewModel()
        XCTAssertEqual(vm.recentUsageTimeZone, .local)
        vm.setRecentUsageTimeZone(.utc)
        XCTAssertEqual(makeViewModel().recentUsageTimeZone, .utc)
        UserDefaults.standard.set("invalid", forKey: key)
        XCTAssertEqual(makeViewModel().recentUsageTimeZone, .local)
    }

    func testTimeZoneChangesPreserveSnapshotAndMakeNoRequests() async throws {
        let key = "recentUsageTimeZone"
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        let requests = Requests()
        MockURLProtocol.requestHandler = Self.handler(requests: requests)
        let vm = makeViewModel()
        await vm.refresh()
        let snapshot = try XCTUnwrap(vm.recentUsage.snapshot)
        let revision = vm.recentUsageTimeZoneRevision
        vm.setRecentUsageTimeZone(.utc)
        vm.setRecentUsageTimeZone(.local)
        vm.systemTimeZoneDidChange()
        XCTAssertEqual(vm.recentUsageTimeZoneRevision, revision + 1)
        XCTAssertEqual(vm.recentUsage.snapshot, snapshot)
        XCTAssertEqual(requests.all.count, 4)
    }

    func testSystemTimeZoneChangeOnlyInvalidatesLocalPresentation() {
        let key = "recentUsageTimeZone"
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        let vm = makeViewModel()
        vm.setRecentUsageTimeZone(.utc)
        let revision = vm.recentUsageTimeZoneRevision

        vm.systemTimeZoneDidChange()
        XCTAssertEqual(vm.recentUsageTimeZoneRevision, revision)

        vm.setRecentUsageTimeZone(.local)
        vm.systemTimeZoneDidChange()
        XCTAssertEqual(vm.recentUsageTimeZoneRevision, revision + 1)
    }

    private nonisolated static func events(_ model: String = "model", count: Int = 1, total: Int? = nil) -> Data {
        let timestamp = Int(Date().timeIntervalSince1970 * 1000)
        return try! JSONSerialization.data(withJSONObject: [
            "usageEventsDisplay": (0..<count).map { index in
                ["timestamp": String(timestamp - index), "model": "\(model)-\(index)",
                 "kind": "included", "requestsCosts": 1, "chargedCents": 15] as [String: Any]
            },
            "totalUsageEventsCount": total ?? count,
        ])
    }

    private nonisolated static func page(_ request: URLRequest) -> Int {
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
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Int])?["page"] ?? 1
    }

    private nonisolated static func handler(
        requests: Requests,
        meterFails: Bool = false,
        eventData: Data = events(),
        secondPageStatus: Int? = nil,
        email: String = "demo@example.com",
        subject: String = "fixture-subject",
        membership: String = "pro"
    ) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            requests.append(request)
            var status = 200
            let data: Data
            switch request.url!.path {
            case "/api/auth/me":
                data = try JSONSerialization.data(withJSONObject: ["email": email, "name": "Demo User", "sub": subject])
            case "/api/usage-summary":
                status = meterFails ? 503 : 200
                data = Data("""
                {"membershipType":"\(membership)","individualUsage":{"plan":{
                "enabled":true,"used":8,"limit":2000,"remaining":1992,"totalPercentUsed":0.4}}}
                """.utf8)
            case "/api/usage":
                status = meterFails ? 503 : 200
                data = Data("{\"startOfMonth\":\"2026-09-01T00:00:00.000Z\"}".utf8)
            case "/api/dashboard/get-filtered-usage-events":
                if Self.page(request) == 2, let secondPageStatus { status = secondPageStatus }
                data = eventData
            default:
                status = 404
                data = Data("{}".utf8)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, data)
        }
    }

    func testOneFirstPageFeedsRecentAndWeeklyWithChartHidden() async {
        let vm = makeViewModel()
        vm.weeklyChartEnabled = false
        let requests = Requests()
        MockURLProtocol.requestHandler = Self.handler(requests: requests, eventData: Self.events(count: 45))

        await vm.refresh()

        XCTAssertEqual(vm.recentUsage.snapshot?.candidate.entries.count, 30)
        XCTAssertEqual(vm.recentUsage.snapshot?.candidate.entries.first?.model, "model-0")
        XCTAssertNotNil(vm.weeklyData)
        XCTAssertEqual(vm.recentUsage.status, .current)
        XCTAssertEqual(requests.all.count, 4)
        XCTAssertEqual(requests.all.filter { $0.hasSuffix("get-filtered-usage-events") }.count, 1)
        XCTAssertFalse(vm.isLoading)
    }

    func testLaterPageFailurePublishesRecentWhileWeeklyFails() async {
        let vm = makeViewModel()
        let requests = Requests()
        MockURLProtocol.requestHandler = Self.handler(
            requests: requests, eventData: Self.events("new", total: 2), secondPageStatus: 503
        )

        await vm.refresh()

        XCTAssertEqual(vm.recentUsage.snapshot?.candidate.entries.first?.model, "new-0")
        XCTAssertEqual(vm.recentUsage.status, .current)
        XCTAssertEqual(vm.weeklyConsecutiveFailureCount, 1)
        XCTAssertEqual(vm.consecutiveFailureCount, 0)
        XCTAssertEqual(requests.all.count, 5)
    }

    func testAuthenticatedCachedScopeCanRefreshRecentWhenBothMeterSourcesFail() async {
        let vm = makeViewModel()
        MockURLProtocol.requestHandler = Self.handler(requests: Requests())
        await vm.refresh()
        let previousMeterTime = vm.lastSuccessAt
        let requests = Requests()
        MockURLProtocol.requestHandler = Self.handler(
            requests: requests, meterFails: true, eventData: Self.events("fresh")
        )

        await vm.refresh()

        XCTAssertEqual(vm.recentUsage.snapshot?.candidate.entries.first?.model, "fresh-0")
        XCTAssertEqual(vm.recentUsage.status, .current)
        XCTAssertEqual(vm.consecutiveFailureCount, 1)
        XCTAssertEqual(vm.lastSuccessAt, previousMeterTime)
        XCTAssertEqual(requests.all.count, 4)
    }

    func testUnknownFirstSessionScopeDoesNotGuessPersonalOnMeterFailure() async {
        let vm = makeViewModel()
        let requests = Requests()
        MockURLProtocol.requestHandler = Self.handler(requests: requests, meterFails: true)

        await vm.refresh()

        XCTAssertNil(vm.recentUsage.snapshot)
        XCTAssertEqual(vm.consecutiveFailureCount, 1)
        XCTAssertEqual(requests.all.count, 3)
    }

    func testAmbiguousFirstPageRetainsOriginalRowsAndCacheTime() async {
        let vm = makeViewModel()
        MockURLProtocol.requestHandler = Self.handler(requests: Requests())
        await vm.refresh()
        let previous = vm.recentUsage.snapshot
        MockURLProtocol.requestHandler = Self.handler(
            requests: Requests(), eventData: Data("{\"totalUsageEventsCount\":2}".utf8)
        )

        await vm.refresh()

        XCTAssertNotNil(previous)
        XCTAssertEqual(vm.recentUsage.snapshot, previous)
        XCTAssertEqual(vm.recentUsage.status, .failed)
        XCTAssertEqual(vm.consecutiveFailureCount, 0)
    }

    func testExplicitEmptyPageReplacesPreviousRecentSnapshot() async {
        let vm = makeViewModel()
        MockURLProtocol.requestHandler = Self.handler(requests: Requests())
        await vm.refresh()
        MockURLProtocol.requestHandler = Self.handler(requests: Requests(), eventData: Self.events(count: 0))

        await vm.refresh()

        XCTAssertEqual(vm.recentUsage.snapshot?.candidate.entries.count, 0)
        XCTAssertEqual(vm.recentUsage.status, .current)
    }

    func testRapidConcurrentAndFollowingRefreshesShareOneBatch() async {
        let instant = ContinuousClock.now
        let feedback = RefreshFeedback(now: { instant }, sleepUntil: { _ in
            try await Task.sleep(for: .seconds(10))
        })
        defer { feedback.invalidate() }
        let vm = makeViewModel(feedback: feedback)
        let requests = Requests()
        MockURLProtocol.requestHandler = Self.handler(requests: requests)

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 { group.addTask { await vm.refresh() } }
        }
        for _ in 0..<8 { await vm.refresh() }

        XCTAssertEqual(requests.all.count, 4)
        XCTAssertFalse(vm.isLoading)
        XCTAssertFalse(feedback.isInFlight)
        XCTAssertFalse(feedback.isReady)
    }

    func testAuthenticatedSubjectDecodesWithoutBreakingLegacyInitializer() throws {
        let decoded = try JSONDecoder().decode(UserInfoResponse.self, from: Data("{\"sub\":\"verified\"}".utf8))
        XCTAssertEqual(decoded.sub, "verified")
        XCTAssertNil(UserInfoResponse(email: nil, name: nil).sub)
    }

    func testLateIDEReadAfterLogoutCannotReconnectOrSendRequests() async {
        let vm = makeViewModel()
        let entered = XCTestExpectation(description: "IDE read entered")
        let release = DispatchSemaphore(value: 0)
        vm.ideCredentialProvider = {
            entered.fulfill()
            _ = release.wait(timeout: .now() + 2)
            return IDECredential(cookieHeader: "WorkosCursorSessionToken=old-ide", expiresAt: .distantFuture)
        }
        let requests = Requests()
        MockURLProtocol.requestHandler = Self.handler(requests: requests)
        let old = Task { await vm.refresh() }
        await fulfillment(of: [entered], timeout: 1)

        vm.logout()
        release.signal()
        await old.value

        XCTAssertEqual(vm.authState, .loggedOut)
        XCTAssertNil(vm.usageData)
        XCTAssertNil(vm.recentUsage.snapshot)
        XCTAssertNil(vm.activeAuthSource)
        XCTAssertTrue(requests.all.isEmpty)
        XCTAssertFalse(vm.isLoading)
    }

    func testDelayedFailureNotifierCannotOverwriteReconnectedSession() async {
        let vm = makeViewModel()
        defer { vm.stopAutoRefreshForTests() }
        vm.appStatusNotificationEnabled = true
        let gate = Gate()
        vm.refreshFailingNotifier = { await gate.pause() }
        MockURLProtocol.requestHandler = Self.handler(requests: Requests(), meterFails: true)
        for _ in 0..<4 { await vm.refresh() }
        let old = Task { await vm.refresh() }
        await gate.waitForPause()

        vm.logout()
        vm.ideCredentialProvider = {
            IDECredential(cookieHeader: "WorkosCursorSessionToken=new-ide", expiresAt: .distantFuture)
        }
        MockURLProtocol.requestHandler = Self.handler(requests: Requests(), eventData: Self.events("new"))
        vm.connectViaIDE()
        await vm.refresh()
        gate.release()
        await old.value

        XCTAssertEqual(vm.authState, .loggedIn)
        XCTAssertEqual(vm.recentUsage.snapshot?.candidate.entries.first?.model, "new-0")
        XCTAssertEqual(vm.consecutiveFailureCount, 0)
        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.isLoading)
    }

    func testDelayedExpiryNotifierCannotClearReconnectedSession() async {
        let vm = makeViewModel()
        defer { vm.stopAutoRefreshForTests() }
        let gate = Gate()
        var deletions = 0
        vm.keychainDeleteHandler = { deletions += 1 }
        vm.sessionExpiredNotifier = { await gate.pause() }
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        let old = Task { await vm.refresh() }
        await gate.waitForPause()

        vm.ideCredentialProvider = {
            IDECredential(cookieHeader: "WorkosCursorSessionToken=new-ide", expiresAt: .distantFuture)
        }
        MockURLProtocol.requestHandler = Self.handler(requests: Requests(), eventData: Self.events("new"))
        vm.connectViaIDE()
        await vm.refresh()
        gate.release()
        await old.value

        XCTAssertEqual(vm.authState, .loggedIn)
        XCTAssertEqual(vm.activeAuthSource, .cursorIDE)
        XCTAssertEqual(vm.recentUsage.snapshot?.candidate.entries.first?.model, "new-0")
        XCTAssertEqual(deletions, 1)
        XCTAssertEqual(vm.consecutiveFailureCount, 0)
        XCTAssertFalse(vm.isLoading)
    }

    func testChangedSubjectWithFailedMeterCannotReusePreviousAccountScope() async {
        let vm = makeViewModel()
        MockURLProtocol.requestHandler = Self.handler(requests: Requests())
        await vm.refresh()
        let generation = vm.refreshFeedback.currentAttempt?.generation
        MockURLProtocol.requestHandler = Self.handler(
            requests: Requests(), meterFails: true, eventData: Self.events("other"), subject: "other-subject"
        )

        await vm.refresh()

        XCTAssertNil(vm.usageData)
        XCTAssertNil(vm.recentUsage.snapshot)
        XCTAssertNil(vm.cachedWeeklyMode)
        XCTAssertEqual(vm.consecutiveFailureCount, 1)
        XCTAssertNotEqual(vm.refreshFeedback.currentAttempt?.generation, generation)
        XCTAssertFalse(vm.isLoading)
    }

    func testScopeChangeThenDiscoveryFailureRetainsPrimaryWithoutRepeatingIt() async {
        let vm = makeViewModel()
        MockURLProtocol.requestHandler = Self.handler(requests: Requests())
        await vm.refresh()
        let generation = vm.refreshFeedback.currentAttempt?.generation
        let requests = Requests()
        MockURLProtocol.requestHandler = Self.handler(requests: requests, membership: "enterprise")

        await vm.refresh()

        for path in ["/api/auth/me", "/api/usage-summary", "/api/usage"] {
            XCTAssertEqual(requests.all.filter { $0 == path }.count, 1)
        }
        XCTAssertEqual(vm.usageData?.membershipType, "enterprise")
        XCTAssertNil(vm.recentUsage.snapshot)
        XCTAssertEqual(vm.weeklyConsecutiveFailureCount, 1)
        XCTAssertNotEqual(vm.refreshFeedback.currentAttempt?.generation, generation)
        XCTAssertFalse(vm.isLoading)
    }
}
