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
        try decode("{\"isMerged\":true,\"planInfo\":{\"planName\":\"Premium\",\"includedUsagePeriod\":\"INCLUDED_USAGE_PERIOD_WEEKLY\",\"includedUsageResetsAt\":\"\(Int64(end.timeIntervalSince1970 * 1000))\"}}")
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
                               feedback: RefreshFeedback? = nil,
                               activity: (any CursorSharedActivityFetching)? = nil, test: XCTestCase) async -> UsageViewModel {
    let suite = "SharedUsageUITests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    test.addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SharedUsageUIProtocol.self]
    let vm = makeTestUsageViewModel(apiClient: CursorAPIClient(configuration: configuration),
        refreshFeedback: feedback ?? RefreshFeedback(timing: .immediate),
        sharedUsage: SharedUsageController(provider: fixture, now: { fixture.now }),
        sharedActivity: SharedActivityController(provider: activity, now: { fixture.now }), defaults: defaults)
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
        case "/api/usage-summary": json = #"{"membershipType":"premium","individualUsage":{"plan":{"enabled":true,"used":8,"limit":2000}}}"#
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

struct SharedActivityUIFixture: CursorSharedActivityFetching {
    func fetchStatus(cookieHeader: String) async throws -> SharedUsageStatusResponse {
        let calendar = SharedActivityValue.utc
        let now = Date()
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let end = calendar.date(byAdding: .month, value: 1, to: start)!
        return try decode(["availability": "available", "monthlyUsage": ["periodStart": timestamp(start), "resetsAt": timestamp(end)]])
    }

    func fetchRecent(cookieHeader: String, start: Date, end: Date) async throws -> SharedBillingItemsResponse {
        let records: [[String: Any]] = [
            ["product": "cursor", "chargeCategory": "usage", "usageType": "on_demand", "totalTokens": "48210", "pricing": ["currency": "USD", "contracted": "0.4210000000"], "displayExtras": ["model": "Demo model A"]],
            ["product": "grok-chat", "chargeCategory": "usage", "usageType": "included", "totalTokens": "9100", "pricing": ["currency": "USD", "contracted": "0.0000000000"], "displayExtras": ["model": "Demo model B"]],
            ["product": "cursor", "chargeCategory": "credit", "usageType": "credits", "hasTokenMeters": false, "totalTokens": "0", "pricing": ["currency": "USD", "contracted": "-5.0000000000"], "displayExtras": ["displayLabel": "Promotional credit"]],
            ["product": "cursor", "chargeCategory": "adjustment", "usageType": "on_demand", "hasTokenMeters": false, "totalTokens": "0", "pricing": ["currency": "USD", "contracted": "-0.1200000000"], "displayExtras": ["displayLabel": "Usage correction"]],
        ]
        let rows: [[String: Any]] = records.enumerated().map { index, source in
            var row = source
            row["eventTime"] = timestamp(end.addingTimeInterval(-Double(index * 3600 + 60)))
            row["billingItemId"] = "synthetic-activity-\(index)"
            return row
        }
        return try decode(["data": rows, "pagination": ["hasMore": false]])
    }

    func fetchDaily(cookieHeader: String, start: Date, end: Date) async throws -> SharedDailyUsageResponse {
        var points: [[String: Any]] = []
        for offset in 0..<7 {
            let day = SharedActivityValue.utc.startOfDay(for: start).addingTimeInterval(Double(offset * 86400))
            let tokens = (offset + 1) * 12000
            let cost = String(format: "%.10f", Double(offset + 1) / 4)
            points.append(["dayStartTime": timestamp(day), "contractedCost": cost,
                           "tokens": tokens, "includedTokens": tokens])
        }
        return try decode(["startTime": timestamp(start), "endTime": timestamp(end),
            "totalContractedCost": "7.0000000000", "totalTokens": 336000, "totalIncludedTokens": 336000,
            "series": [["dimensions": ["usageType": "included"], "costRank": 1, "tokenRank": 1,
                "totalContractedCost": "7.0000000000", "totalTokens": 336000, "totalIncludedTokens": 336000, "points": points]],
            "other": ["totalContractedCost": "0", "totalTokens": 0, "totalIncludedTokens": 0, "points": []]])
    }

    private func timestamp(_ value: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: value)
    }
    private func decode<T: Decodable>(_ object: [String: Any]) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: object))
    }
}
