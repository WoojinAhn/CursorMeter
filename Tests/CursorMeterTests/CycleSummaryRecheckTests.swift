import XCTest
@testable import CursorMeter

@MainActor
final class CycleSummaryRecheckTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func collectWithSummaryFailure(status: Int?, retryAfter: String? = nil) async throws -> (SplitUsageController, Date) {
        let summaryJSON = #"{"billingCycleStart":"1970-01-01T00:00:01Z","billingCycleEnd":"1970-01-01T00:00:10Z","membershipType":"ultra","individualUsage":{"plan":{"enabled":true,"used":1,"limit":100,"autoPercentUsed":10,"apiPercentUsed":10}}}"#
        let summary = try JSONDecoder().decode(UsageSummaryResponse.self, from: Data(summaryJSON.utf8))
        let headers = retryAfter.map { ["Retry-After": $0] }
        MockURLProtocol.requestHandler = { request in
            let data: Data
            switch request.url?.path {
            case "/api/dashboard/get-current-period-usage":
                data = Data(#"{"billingCycleStart":"1970-01-01T00:00:01Z","billingCycleEnd":"1970-01-01T00:00:10Z","planUsage":{"includedSpend":1},"autoBucketModels":["composer-2.5"]}"#.utf8)
            case "/api/dashboard/get-filtered-usage-events":
                data = Data(#"{"totalUsageEventsCount":1,"usageEventsDisplay":[{"timestamp":"9000","model":"composer-2.5","kind":"USAGE_EVENT_KIND_INCLUDED_IN_ULTRA","chargedCents":1}]}"#.utf8)
            case "/api/usage-summary":
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "test")
                XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
                XCTAssertNil(request.value(forHTTPHeaderField: "Content-Type"))
                XCTAssertTrue(CycleUsageAPITests.body(request).isEmpty)
                guard let status else { throw URLError(.notConnectedToInternet) }
                return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                    headerFields: headers)!, Data())
            default:
                XCTFail("Unexpected endpoint: \(request.url?.path ?? "nil")")
                throw URLError(.unsupportedURL)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, data)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let now = Date(timeIntervalSince1970: 9)
        let controller = SplitUsageController(apiClient: CursorAPIClient(configuration: configuration), now: { now })
        controller.accept(summary: summary,
            usage: try JSONDecoder().decode(UsageResponse.self, from: Data("{}".utf8)),
            userInfo: .init(email: "demo@example.test", name: "Demo", sub: "demo"), generation: 1, enterpriseScope: false)
        controller.requestAmounts(summary: summary, cookieHeader: "test")
        XCTAssertNotNil(controller.schedule.currentAttemptID)
        for _ in 0..<500 {
            if controller.schedule.currentAttemptID == nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNil(controller.schedule.currentAttemptID, "Collection did not finish")
        XCTAssertEqual(controller.amountState, .failed)
        XCTAssertEqual(controller.eligibility, .eligible)
        XCTAssertNotNil(controller.primarySnapshot)
        XCTAssertFalse(controller.isStale)
        XCTAssertNil(controller.amounts)
        return (controller, now)
    }

    func testSummaryTransportAndServerFailureUseTransientBackoff() async throws {
        for status: Int? in [nil, 503] {
            let (controller, now) = try await collectWithSummaryFailure(status: status)
            XCTAssertEqual(controller.schedule.availability(at: now, manual: false), .waiting(until: now.addingTimeInterval(60)))
            XCTAssertEqual(controller.schedule.availability(at: now.addingTimeInterval(61), manual: false), .ready)
        }
    }

    func testSummaryRateLimitPreservesRetryAfterAndBlocksManualAndAutomaticWork() async throws {
        for (header, delay): (String?, TimeInterval) in [("120", 120), (nil, 1800), ("invalid", 1800), ("0", 60)] {
            let (controller, now) = try await collectWithSummaryFailure(status: 429, retryAfter: header)
            let duringBackoff = now.addingTimeInterval(delay - 1)
            for manual in [false, true] {
                XCTAssertEqual(controller.schedule.availability(at: duringBackoff, manual: manual), .waiting(until: now.addingTimeInterval(delay)))
                XCTAssertEqual(controller.schedule.availability(at: now.addingTimeInterval(delay), manual: manual), .ready)
            }
            XCTAssertFalse(controller.schedule.canFetchSupplement(at: duringBackoff))
        }
    }

    func testSummaryNontransientFailureDoesNotTakePrimaryAuthenticationOwnership() async throws {
        for status in [400, 401, 403] {
            let (controller, now) = try await collectWithSummaryFailure(status: status)
            XCTAssertEqual(controller.schedule.availability(at: now, manual: false), .waiting(until: now.addingTimeInterval(1800)))
            XCTAssertEqual(controller.schedule.availability(at: now.addingTimeInterval(61), manual: true), .ready)
        }
    }
}
