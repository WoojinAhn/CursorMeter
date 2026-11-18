import XCTest
@testable import CursorMeter

final class CursorSharedActivityAPIClientTests: XCTestCase, @unchecked Sendable {
    override func tearDown() { ActivityURLProtocol.handler = nil; super.tearDown() }
    private func client() -> CursorSharedActivityAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActivityURLProtocol.self]
        configuration.httpAdditionalHeaders = ["Authorization": "unwanted", "X-Team-Id": "unwanted"]
        return CursorSharedActivityAPIClient(configuration: configuration)
    }
    func testCanonicalCookieRequestsUseBoundedPersonalWindowsAndOfficialHeaders() async throws {
        let start = ISO8601DateFormatter().date(from: "2026-11-13T00:00:00Z")!
        let end = start.addingTimeInterval(6 * 86400 + 60)
        ActivityURLProtocol.handler = { call in
            let request = call.request
            XCTAssertEqual(request.url?.host, "cursor.com")
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "WorkosCursorSessionToken=synthetic")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-cursor-dashboard-surface"), "v2")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Team-Id"))
            XCTAssertEqual(request.timeoutInterval, 15)
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            switch request.url!.lastPathComponent {
            case "usage-status":
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(query, [.init(name: "scope", value: "user")])
                call.respond(#"{"availability":"identity_unlinked"}"#)
            case "query-billing-items":
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(query.first { $0.name == "pageSize" }?.value, "30")
                XCTAssertEqual(query.first { $0.name == "scope" }?.value, "user")
                XCTAssertEqual(query.first { $0.name == "startTime" }?.value, "2026-11-13T00:00:00.000Z")
                XCTAssertFalse(query.contains { $0.name == "cursor" })
                call.respond(#"{"data":[],"pagination":{"hasMore":false}}"#)
            case "query-daily-usage":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://cursor.com")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                let body = try! JSONSerialization.jsonObject(with: call.body) as! [String: Any]
                XCTAssertEqual(body["scope"] as? String, "user")
                XCTAssertEqual(body["groupBy"] as? [String], ["usageType"])
                XCTAssertEqual(body["topN"] as? Int, 20)
                XCTAssertEqual((body["filters"] as? [String: String])?.count, 0)
                XCTAssertEqual(body["endTime"] as? String, "2026-11-19T00:01:00.000Z")
                call.respond(#"{"availability":"identity_unlinked"}"#)
            default: XCTFail("Unexpected endpoint")
            }
        }
        let api = client()
        _ = try await api.fetchStatus(cookieHeader: "WorkosCursorSessionToken=synthetic")
        _ = try await api.fetchRecent(cookieHeader: "WorkosCursorSessionToken=synthetic", start: start, end: end)
        _ = try await api.fetchDaily(cookieHeader: "WorkosCursorSessionToken=synthetic", start: start, end: end)
    }
    func testEmptyMalformedOversizedAndHTTPResponsesStayTyped() async {
        let api = client()
        for (json, status, error) in [("", 200, CursorSharedAPIError.emptyResponse), ("{}", 200, .invalidResponse),
            (String(repeating: "x", count: 1_048_577), 200, .responseTooLarge), ("private", 401, .unauthorized),
            ("private", 403, .forbidden), ("private", 500, .httpStatus(500))] {
            ActivityURLProtocol.handler = { $0.respond(json, status: status) }
            do { _ = try await api.fetchStatus(cookieHeader: "fixture"); XCTFail("Expected rejection") }
            catch let actual { XCTAssertEqual(actual as? CursorSharedAPIError, error) }
        }
        ActivityURLProtocol.handler = { $0.respond("{}", headers: ["Content-Length": "1048577"]) }
        do { _ = try await api.fetchStatus(cookieHeader: "fixture"); XCTFail("Expected bound") }
        catch { XCTAssertEqual(error as? CursorSharedAPIError, .responseTooLarge) }
    }
    func testRedirectNeverForwardsSelectedCookie() async {
        ActivityURLProtocol.handler = { call in
            XCTAssertEqual(call.request.url?.host, "cursor.com")
            let response = HTTPURLResponse(url: call.request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://example.invalid/"])!
            call.client?.urlProtocol(call, wasRedirectedTo: URLRequest(url: URL(string: "https://example.invalid/")!), redirectResponse: response)
            call.respond("", status: 302)
        }
        do { _ = try await client().fetchStatus(cookieHeader: "fixture"); XCTFail("Expected rejected redirect") }
        catch { XCTAssertEqual(error as? CursorSharedAPIError, .httpStatus(302)) }
    }
    func testCancelledRequestDoesNotPublishAndInvalidHeadersNeverReachNetwork() async {
        ActivityURLProtocol.handler = { _ in XCTFail("Invalid header reached network") }
        for header in ["", "fixture\r\nInjected: header"] {
            do { _ = try await client().fetchStatus(cookieHeader: header); XCTFail("Expected invalid credential") }
            catch { XCTAssertEqual(error as? CursorSharedAPIError, .invalidCredential) }
        }
        let started = expectation(description: "started")
        ActivityURLProtocol.handler = { _ in started.fulfill() }
        let api = client()
        let task = Task { try await api.fetchStatus(cookieHeader: "fixture") }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? CursorSharedAPIError, .cancelled) }
    }
}

private final class ActivityURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((ActivityURLProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() {}
    var body: Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        return result
    }
    func respond(_ json: String, status: Int = 200, headers: [String: String] = [:]) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
