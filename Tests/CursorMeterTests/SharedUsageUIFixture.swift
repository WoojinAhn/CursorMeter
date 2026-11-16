import AppKit
import XCTest
@testable import CursorMeter

struct SharedUsageUIFixture: CursorSharedUsageFetching {
    var now = Date()
    var weekly: Double = 25
    var balance = 1240
    var purchased: Int? = 2000
    var monthly = 760
    var cap: Int? = 50
    var autoTopUp: Bool? = false
    var weeklyFails = false

    var end: Date { Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) + 86_400) }

    func fetchPlanInfo(cookieHeader: String) async throws -> CursorPlanInfoResponse {
        try decode("{\"isMerged\":true,\"planInfo\":{\"includedUsagePeriod\":\"INCLUDED_USAGE_PERIOD_WEEKLY\",\"includedUsageResetsAt\":\"\(Int64(end.timeIntervalSince1970 * 1000))\"}}")
    }
    func fetchCurrentPeriod(cookieHeader: String) async throws -> CurrentPeriodUsageResponse {
        if weeklyFails { throw CursorSharedAPIError.transport }
        let formatter = ISO8601DateFormatter()
        return try decode("{\"billingCycleStart\":\"\(formatter.string(from: end.addingTimeInterval(-604800)))\",\"billingCycleEnd\":\"\(formatter.string(from: end))\",\"planUsage\":{\"totalPercentUsed\":\(weekly)}}")
    }
    func fetchPrepaid(cookieHeader: String) async throws -> CursorPrepaidBillingResponse {
        let total = purchased ?? balance
        let purchases = purchased.map { $0 == 0 ? "[]" : "[{\"ticket\":1,\"origin\":\"TOPUP_MANUAL\",\"amountCents\":\($0),\"status\":\"SUCCEEDED\",\"createdAtMs\":1}]" } ?? "null"
        let auto = autoTopUp.map { ",\"autoTopUp\":{\"enabled\":\($0)}" } ?? ""
        return try decode("{\"billingMode\":\"PREPAID_BILLING_MODE_PREPAID\",\"eligible\":true,\"availableCents\":\(balance),\"fundedCents\":\(total),\"spentCents\":\(total - balance),\"spentThisMonthCents\":\(monthly),\"topUps\":\(purchases)\(auto)}")
    }
    func fetchPaidCap(cookieHeader: String) async throws -> CursorPaidCapResponse {
        try decode(cap.map { "{\"hardLimit\":\($0)}" } ?? "{}")
    }
    private func decode<T: Decodable>(_ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }
}

@MainActor
func makeSharedUsageUIViewModel(_ fixture: SharedUsageUIFixture = .init(),
                               feedback: RefreshFeedback? = nil, test: XCTestCase) async -> UsageViewModel {
    let suite = "SharedUsageUITests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    test.addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SharedUsageUIProtocol.self]
    let vm = makeTestUsageViewModel(apiClient: CursorAPIClient(configuration: configuration),
        refreshFeedback: feedback ?? RefreshFeedback(timing: .immediate),
        sharedUsage: SharedUsageController(provider: fixture, now: { fixture.now }), defaults: defaults)
    vm.keychainLoadHandler = { nil }
    vm.testHook_setCookieHeader("WorkosCursorSessionToken=synthetic-ui")
    vm.authState = .loggedIn
    vm.notificationEnabled = false
    await vm.refresh()
    return vm
}

private final class SharedUsageUIProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let json: String
        switch request.url!.path {
        case "/api/auth/me": json = #"{"email":"demo@example.com","name":"Demo User","sub":"synthetic-shared-ui"}"#
        case "/api/usage-summary": json = #"{"membershipType":"pro","individualUsage":{"plan":{"enabled":true,"used":8,"limit":2000}}}"#
        case "/api/usage": json = "{}"
        default:
            XCTFail("Unexpected synthetic UI request: \(request.url!.path)")
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
