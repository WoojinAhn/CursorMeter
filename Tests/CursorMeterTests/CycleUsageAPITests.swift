import XCTest
@testable import CursorMeter

final class CycleUsageAPITests: XCTestCase, @unchecked Sendable {
    override func tearDown() { MockURLProtocol.requestHandler = nil; super.tearDown() }
    static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }; data.append(buffer, count: count)
        }
        return data
    }
    func client() -> CursorAPIClient {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MockURLProtocol.self]
        return CursorAPIClient(configuration: config)
    }
    func testPeriodPostsEmptyPersonalBodyAndOrigin() async throws {
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/dashboard/get-current-period-usage")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://cursor.com")
            XCTAssertEqual(Self.body(request), Data("{}".utf8))
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(#"{"planUsage":{"includedSpend":1}}"#.utf8))
        }
        let response = try await client().fetchCurrentPeriodUsage(cookieHeader: "test")
        XCTAssertEqual(response.planUsage?.includedSpend, 1)
    }
    func testEnrichmentUnauthorizedStaysSeparateFromLegacyAuth() async throws {
        for code in [204, 401, 403] {
            MockURLProtocol.requestHandler = { request in (HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, Data()) }
            do { _ = try await client().fetchCurrentPeriodUsage(cookieHeader: "test"); XCTFail("Expected enrichment failure") }
            catch { XCTAssertTrue(error is CycleEnrichmentError); XCTAssertFalse(error is APIError) }
        }
    }
    func testHistoryBudgetBeforeDecodingAndRetryAfter() async throws {
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(repeating: 32, count: 100))
        }
        do { _ = try await client().fetchCycleUsagePage(cookieHeader: "test", teamId: 0, userId: nil, page: 1, maximumBytes: 99); XCTFail() }
        catch CycleEnrichmentError.oversizedPayload(let bytes) { XCTAssertEqual(bytes, 100) } catch { XCTFail("\(error)") }
        MockURLProtocol.requestHandler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "120"])!, Data())
        }
        do { _ = try await client().fetchCurrentPeriodUsage(cookieHeader: "test"); XCTFail() }
        catch CycleEnrichmentError.http(let status, let wait) { XCTAssertEqual(status, 429); XCTAssertEqual(wait, 120) }
        catch { XCTFail("\(error)") }
    }
    func testHistoryExactMoneyBytesAndOmittedUser() async throws {
        let json = Data(#"{"totalUsageEventsCount":1,"usageEventsDisplay":[{"timestamp":"2000","chargedCents":0.123456789123456789}]}"#.utf8)
        MockURLProtocol.requestHandler = { request in
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Self.body(request)) as? [String: Any])
            XCTAssertNil(body["userId"]); XCTAssertEqual(body["pageSize"] as? Int, 100)
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, json)
        }
        let page = try await client().fetchCycleUsagePage(cookieHeader: "test", teamId: 0, userId: nil, page: 1, maximumBytes: 10000)
        XCTAssertEqual(page.byteCount, json.count)
        XCTAssertEqual(page.page.events[0].chargedCents, Decimal(string: "0.123456789123456789"))
    }
}
