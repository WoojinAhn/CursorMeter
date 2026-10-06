import AppKit

/// Explicit artifact verification only; normal launches never construct these dependencies.
@MainActor
final class ReleaseSmokeTest {
    enum Scenario: String, CaseIterable, Sendable {
        case startup, bonus
        case stallRefresh = "stall-refresh"
        case crashRefresh = "crash-refresh"
    }

    struct Configuration {
        let scenario: Scenario
        let resultURL: URL
        let runID: String

        static func parse(arguments: [String]) throws -> Self? {
            guard arguments.contains(where: { $0 == "--release-smoke-test" || $0.hasPrefix("--release-smoke-test=") })
            else { return nil }
            guard arguments.count == 5, arguments[1] == "--release-smoke-test",
                  let scenario = Scenario(rawValue: arguments[2]), arguments[3].hasPrefix("/"),
                  !arguments[4].isEmpty else { throw SmokeFailure.invalidArguments }
            return Self(scenario: scenario, resultURL: URL(fileURLWithPath: arguments[3]), runID: arguments[4])
        }
    }

    struct Report: Codable, Sendable {
        let schema: Int
        let runID: String
        let scenario: String
        let status: String
        let completedRefreshes: Int
        let completedCollections: Int
        let todayCursorPercent: Double
        let todayOtherPercent: Double
    }

    enum SmokeFailure: Error {
        case invalidArguments, missingStartupRefresh, unexpectedSideEffect
        case invalidUsage(String)
        case incompleteRequests(refreshes: Int, collections: Int, requests: [String: Int])
    }

    let configuration: Configuration
    let viewModel: UsageViewModel
    private let fixture: ReleaseSmokeFixture

    init(configuration: Configuration) {
        self.configuration = configuration
        let fixture = ReleaseSmokeFixture(scenario: configuration.scenario)
        self.fixture = fixture
        ReleaseSmokeURLProtocol.install(fixture)
        let network = URLSessionConfiguration.ephemeral
        network.protocolClasses = [ReleaseSmokeURLProtocol.self]
        network.httpShouldSetCookies = false
        network.httpCookieStorage = nil
        network.urlCredentialStorage = nil
        network.timeoutIntervalForRequest = 3_600
        network.timeoutIntervalForResource = 3_600
        let api = CursorAPIClient(configuration: network)
        let split = SplitUsageController(apiClient: api, now: { fixture.now }, collectToday: { snapshot, summary, cookie, allowance, context, supplement in
            var collector = CycleUsageCollector(budget: .init(maxPages: allowance), fetchPage: { page, bytes in
                try await api.fetchCycleUsagePage(cookieHeader: cookie, teamId: 0, userId: nil,
                                                 page: page, maximumBytes: bytes)
            }, fetchSummary: { try await api.fetchUsageSummaryForCycleValidation(cookieHeader: cookie) }, fetchPeriod: {
                try await api.fetchCurrentPeriodUsage(cookieHeader: cookie)
            }, onSupplement: supplement)
            collector.now = { fixture.now }
            let result = await collector.collect(snapshot: snapshot, summary: summary, todayContext: context)
            fixture.recordCollection()
            return result
        }, waitUntil: { _ in try await Task.sleep(for: .seconds(3_600)) })
        let manager = NotificationManager(requestAuthorization: {
            fixture.recordUnexpectedSideEffect()
            return false
        }, deliver: { _ in fixture.recordUnexpectedSideEffect() }, permissionStateProvider: { .denied })
        viewModel = UsageViewModel(apiClient: api, recentUsage: RecentUsageController(),
            refreshFeedback: RefreshFeedback(timing: .immediate), notificationManager: manager,
            splitUsage: split, splitAlertStore: SplitUsageAlertStore(), defaults: ReleaseSmokeDefaults())
        // MainActor construction is synchronous: all seams precede the initializer's update task.
        viewModel.updateCheckRunner = { .upToDate }
        viewModel.keychainLoadHandler = { ReleaseSmokeFixture.cookie }
        viewModel.keychainSaveHandler = { _ in fixture.recordUnexpectedSideEffect() }
        viewModel.keychainDeleteHandler = { fixture.recordUnexpectedSideEffect() }
        viewModel.sessionExpiredNotifier = { fixture.recordUnexpectedSideEffect() }
    }

    func run(startup: Task<Void, Never>?) async throws -> Report {
        guard let startup else { throw SmokeFailure.missingStartupRefresh }
        let polling = viewModel.stopAutoRefreshForTests()
        await polling?.value
        defer { viewModel.systemWillSleep() }
        await startup.value
        await viewModel.splitUsage.waitForCurrentCollection()
        await viewModel.testHook_waitForSplitAlerts()
        try validate(completedRefreshes: 1)
        fixture.advanceClock()
        await viewModel.refresh()
        await viewModel.splitUsage.waitForCurrentCollection()
        await viewModel.testHook_waitForSplitAlerts()
        try validate(completedRefreshes: 2)
        return Report(schema: 1, runID: configuration.runID, scenario: configuration.scenario.rawValue,
            status: "passed", completedRefreshes: 2, completedCollections: fixture.completedCollections,
            todayCursorPercent: viewModel.splitUsage.todayPercentagePoints![.cursor]!,
            todayOtherPercent: viewModel.splitUsage.todayPercentagePoints![.other]!)
    }

    private func validate(completedRefreshes: Int) throws {
        guard fixture.unexpectedSideEffects == 0 else { throw SmokeFailure.unexpectedSideEffect }
        guard fixture.requestCount("/api/usage") == completedRefreshes,
              fixture.requestCount("/api/auth/me") == completedRefreshes,
              fixture.requestCount("/api/usage-summary") >= completedRefreshes * 2,
              fixture.requestCount("/api/dashboard/get-filtered-usage-events") >= completedRefreshes * 2,
              fixture.requestCount("/api/dashboard/get-current-period-usage") >= completedRefreshes * 2,
              fixture.completedCollections == completedRefreshes else {
            throw SmokeFailure.incompleteRequests(refreshes: completedRefreshes,
                collections: fixture.completedCollections, requests: fixture.requestCounts)
        }
        let split = viewModel.splitUsage
        guard viewModel.authState == .loggedIn, viewModel.activeAuthSource == .browserLogin,
              !viewModel.isLoading, !viewModel.refreshFeedback.isInFlight,
              viewModel.errorMessage == nil, viewModel.consecutiveFailureCount == 0,
              viewModel.usageData?.planUsedCents == fixture.includedCents,
              split.eligibility == .eligible, !split.isStale, split.amountState == .ready,
              let amounts = split.amounts, amounts.coverage.complete,
              amounts.coverage.eventCount == 3, amounts.status == .estimatedAttribution,
              amounts.cursorCents == fixture.cursorCents, amounts.otherCents == Decimal(string: "5.5"),
              amounts.botCents == 7, amounts.unknownCount == 0,
              amounts.residualCents == (configuration.scenario == .bonus ? Decimal(string: "0.5") : 0),
              split.todayPercentagePoints?[.cursor] == 10, split.todayPercentagePoints?[.other] == 20
        else {
            throw SmokeFailure.invalidUsage("refresh=\(completedRefreshes), loggedIn=\(viewModel.authState == .loggedIn), "
                + "loading=\(viewModel.isLoading), included=\(String(describing: viewModel.usageData?.planUsedCents)), "
                + "amountState=\(split.amountState), coverage=\(split.amounts?.coverage.complete.description ?? "nil"), "
                + "events=\(split.amounts?.coverage.eventCount.description ?? "nil"), "
                + "today=\(split.todayPercentagePoints?.description ?? "nil")")
        }
        if configuration.scenario == .bonus {
            guard amounts.bonusReconciliation == .init(sourceIncludedCents: 100, totalCents: 105),
                  amounts.todayUsage?.sourceIncludedTotalCents == 100 else { throw SmokeFailure.invalidUsage("Missing capped-bonus receipt") }
        } else if amounts.bonusReconciliation != nil { throw SmokeFailure.invalidUsage("Unexpected bonus authority below cap") }
    }

    func write(_ report: Report) throws {
        try JSONEncoder().encode(report).write(to: configuration.resultURL, options: [.withoutOverwriting])
    }
}

/// Never creates a persistent preferences domain, including during settings migration.
private final class ReleaseSmokeDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any] = [
        "notificationEnabled": false, "appStatusNotificationEnabled": false,
        "jumpEffectEnabled": false, "activityRefreshEnabled": false
    ]

    override func object(forKey defaultName: String) -> Any? {
        lock.withLock { values[defaultName] }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock { values[defaultName] = value }
    }
}

private final class ReleaseSmokeFixture: @unchecked Sendable {
    static let cookie = "WorkosCursorSessionToken=release-smoke-fixed-fixture"
    let scenario: ReleaseSmokeTest.Scenario
    let includedCents: Int
    let cursorCents: Decimal
    private let lock = NSLock()
    private var clock = Date(timeIntervalSince1970: 1_791_255_600) // 2026-10-06 03:00 UTC
    private var counts: [String: Int] = [:]
    private var collections = 0
    private var sideEffects = 0

    init(scenario: ReleaseSmokeTest.Scenario) {
        self.scenario = scenario
        includedCents = scenario == .bonus ? 100 : 90
        cursorCents = scenario == .bonus ? 100 : Decimal(string: "84.5")!
    }

    var now: Date { lock.withLock { clock } }
    var completedCollections: Int { lock.withLock { collections } }
    var unexpectedSideEffects: Int { lock.withLock { sideEffects } }
    var requestCounts: [String: Int] { lock.withLock { counts } }
    func advanceClock() { lock.withLock { clock += 120 } }
    func recordCollection() { lock.withLock { collections += 1 } }
    func recordUnexpectedSideEffect() { lock.withLock { sideEffects += 1 } }
    func requestCount(_ path: String) -> Int { lock.withLock { counts[path, default: 0] } }

    func response(for request: URLRequest) -> Data? {
        let path = request.url?.path ?? ""
        lock.withLock { counts[path, default: 0] += 1 }
        guard request.url?.scheme == "https", request.url?.host == "cursor.com",
              request.value(forHTTPHeaderField: "Cookie") == Self.cookie else {
            recordUnexpectedSideEffect()
            return nil
        }
        if path == "/api/usage-summary" {
            switch scenario {
            case .crashRefresh: abort()
            case .stallRefresh: return nil
            default: break
            }
        }
        let json: String
        switch path {
        case "/api/usage-summary":
            json = #"{"billingCycleStart":"2026-10-01T00:00:00Z","billingCycleEnd":"2026-11-01T00:00:00Z","membershipType":"ultra","individualUsage":{"plan":{"used":\#(includedCents),"limit":100,"autoPercentUsed":10,"apiPercentUsed":20}}}"#
        case "/api/usage":
            json = #"{"gpt-4":{"numRequests":3,"numRequestsTotal":3},"startOfMonth":"2026-10-01T00:00:00Z"}"#
        case "/api/auth/me":
            json = #"{"sub":"release-smoke-subject","email":"smoke@example.invalid","name":"Release Smoke"}"#
        case "/api/dashboard/teams":
            json = #"{"teams":[]}"#
        case "/api/dashboard/get-hard-limit":
            json = #"{"hardLimit":0}"#
        case "/api/dashboard/get-current-period-usage":
            let total = scenario == .bonus ? 105 : 90
            let bonus = scenario == .bonus ? 5 : 0
            json = #"{"billingCycleStart":"1790812800000","billingCycleEnd":"1793491200000","planUsage":{"includedSpend":\#(includedCents),"totalSpend":\#(total),"bonusSpend":\#(bonus),"limit":100,"autoPercentUsed":10,"apiPercentUsed":20},"autoBucketModels":["composer-2.5"]}"#
        case "/api/dashboard/get-filtered-usage-events":
            let timestamp = String(Int(now.timeIntervalSince1970 * 1000))
            json = #"{"totalUsageEventsCount":3,"usageEventsDisplay":[{"timestamp":"\#(timestamp)","model":"composer-2.5","kind":"USAGE_EVENT_KIND_INCLUDED_IN_ULTRA","chargedCents":\#(cursorCents),"requestsCosts":1},{"timestamp":"\#(timestamp)","model":"other-model","kind":"USAGE_EVENT_KIND_INCLUDED_IN_ULTRA","chargedCents":5.5,"requestsCosts":1},{"timestamp":"\#(timestamp)","model":"grok-bot-4.7","kind":"USAGE_EVENT_KIND_INCLUDED_IN_ULTRA","chargedCents":7,"requestsCosts":1}]}"#
        default:
            recordUnexpectedSideEffect()
            return nil
        }
        return Data(json.utf8)
    }
}

/// Intercepts every URL, including unexpected hosts, so fixture errors cannot use the network.
private final class ReleaseSmokeURLProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var fixture: ReleaseSmokeFixture?

    static func install(_ fixture: ReleaseSmokeFixture) {
        lock.withLock { Self.fixture = fixture }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let fixture = Self.lock.withLock({ Self.fixture }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        guard let data = fixture.response(for: request) else {
            if fixture.scenario != .stallRefresh {
                client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            }
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
