import XCTest
@testable import CursorMeter

final class CursorSharedAPIClientTests: XCTestCase, @unchecked Sendable {
    override func tearDown() {
        SharedRPCURLProtocol.handler = nil
        super.tearDown()
    }

    private func makeClient() -> CursorSharedAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SharedRPCURLProtocol.self]
        configuration.httpAdditionalHeaders = ["Cookie": "unwanted=1", "Authorization": "unwanted", "X-Team-Id": "unwanted"]
        return CursorSharedAPIClient(configuration: configuration)
    }

    private func token(subject: String = "user_fixture", expires: Double = 4_102_444_800) -> String {
        func encode(_ data: Data) -> String {
            data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let payload = try! JSONSerialization.data(withJSONObject: ["sub": subject, "exp": expires], options: [.sortedKeys])
        return encode(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8)) + "." + encode(payload) + "." + encode(Data("synthetic-signature".utf8))
    }

    private func cookie(_ value: String? = nil) -> String { "WorkosCursorSessionToken=user_fixture%3A%3A" + (value ?? token()) }

    func testAllRPCsUseFixedEndpointBearerAndExactPersonalBodiesWithoutCookies() async throws {
        let expectedToken = token()
        SharedRPCURLProtocol.handler = { request in
            XCTAssertEqual(request.request.url?.scheme, "https")
            XCTAssertEqual(request.request.url?.host, "api2.cursor.sh")
            XCTAssertEqual(request.request.httpMethod, "POST")
            XCTAssertEqual(request.request.value(forHTTPHeaderField: "Authorization"), "Bearer " + expectedToken)
            XCTAssertEqual(request.request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.request.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")
            XCTAssertNil(request.request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.request.value(forHTTPHeaderField: "X-Team-Id"))
            XCTAssertEqual(request.request.timeoutInterval, 15)
            let path = request.request.url!.path
            let body = request.request.httpBody ?? request.request.httpBodyStream.map { stream in
                stream.open()
                defer { stream.close() }
                var result = Data()
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    result.append(contentsOf: buffer.prefix(count))
                }
                return result
            } ?? Data()
            let object = try! JSONSerialization.jsonObject(with: body) as! [String: Bool]
            let scoped = path.hasSuffix("/GetCurrentPeriodUsage") || path.hasSuffix("/GetHardLimit")
            XCTAssertEqual(object, scoped ? ["personalScope": true] : [:])
            switch path {
            case "/aiserver.v1.DashboardService/GetPlanInfo": request.respond(#"{"isMerged":true,"planInfo":{"includedUsagePeriod":"INCLUDED_USAGE_PERIOD_WEEKLY"}}"#)
            case "/aiserver.v1.DashboardService/GetCurrentPeriodUsage": request.respond(#"{"planUsage":{"totalPercentUsed":0}}"#)
            case "/aiserver.v1.DashboardService/GetUserPrepaidBilling": request.respond(#"{"billingMode":"PREPAID_BILLING_MODE_PREPAID","eligible":true}"#)
            case "/aiserver.v1.DashboardService/GetHardLimit": request.respond(#"{"hardLimit":2147483647}"#)
            default: XCTFail("Unexpected RPC"); request.respond("{}", status: 404)
            }
        }
        let client: any CursorSharedUsageFetching = makeClient()
        let plan = try await client.fetchPlanInfo(cookieHeader: cookie())
        let current = try await client.fetchCurrentPeriod(cookieHeader: cookie())
        let prepaid = try await client.fetchPrepaid(cookieHeader: cookie())
        let cap = try await client.fetchPaidCap(cookieHeader: cookie())
        XCTAssertEqual(plan.classification, .sharedWeekly)
        XCTAssertEqual(current.planUsage?.totalPercentUsed, 0)
        XCTAssertTrue(prepaid.creditUsage.hasNoPurchases)
        XCTAssertEqual(cap.cap, .uncapped)
    }

    func testEncodedAndDecodedCookieDelimitersAreAccepted() async throws {
        SharedRPCURLProtocol.handler = { $0.respond(#"{"isMerged":false}"#) }
        let client = makeClient()
        for separator in ["::", "%3A%3A", "%3a%3a"] {
            _ = try await client.fetchPlanInfo(cookieHeader: "other=ignored; WorkosCursorSessionToken=user_fixture" + separator + token() + "; next=ignored")
        }
    }

    func testExistingIDEReaderCookiePreservesNamespacedSubjectAndRejectsOtherUser() async throws {
        let jwt = token(subject: "auth0|user_fixture")
        let userID = try XCTUnwrap(CursorAppAuthReader.userID(fromSub: "auth0|user_fixture"))
        let header = CursorAppAuthReader.makeCookieHeader(userID: userID, jwt: jwt)
        SharedRPCURLProtocol.handler = { request in
            XCTAssertEqual(request.request.value(forHTTPHeaderField: "Authorization"), "Bearer " + jwt)
            request.respond(#"{"isMerged":false}"#)
        }
        let client = makeClient()
        _ = try await client.fetchPlanInfo(cookieHeader: header)
        _ = try await client.fetchPlanInfo(cookieHeader: header.replacingOccurrences(of: "%3A", with: ":"))
        SharedRPCURLProtocol.handler = { request in XCTFail("Different account reached network"); request.respond(#"{"isMerged":false}"#) }
        do {
            _ = try await client.fetchPlanInfo(cookieHeader: CursorAppAuthReader.makeCookieHeader(userID: "user_other", jwt: jwt))
            XCTFail("Expected mismatched credential rejection")
        } catch { XCTAssertEqual(error as? CursorSharedAPIError, .invalidCredential) }
    }

    func testMalformedAmbiguousExpiredAndMismatchedCredentialsNeverReachNetwork() async {
        SharedRPCURLProtocol.handler = { request in XCTFail("Invalid credentials reached network"); request.respond("{}") }
        let client = makeClient()
        let malformed = ["", "other=value", "WorkosCursorSessionToken=", "WorkosCursorSessionToken=invalid", cookie() + "; " + cookie(), cookie() + "\r\nInjected: value", cookie() + "%", cookie() + "%2G", cookie().replacingOccurrences(of: "user_fixture%3A", with: "other_user%3A"), cookie(token(expires: 1)), cookie("a.b.c"), cookie("e30.e30.c2ln"), cookie().replacingOccurrences(of: "%3A%3A", with: "%253A%253A"), cookie() + " "]
        for header in malformed {
            do {
                _ = try await client.fetchPlanInfo(cookieHeader: header)
                XCTFail("Expected invalid credential")
            } catch { XCTAssertEqual(error as? CursorSharedAPIError, .invalidCredential) }
        }
    }

    func testHTTPFailuresRemainTypedAndSeparateFromLegacyAuthentication() async {
        let client = makeClient()
        for (status, expected) in [(401, CursorSharedAPIError.unauthorized), (403, .forbidden), (429, .httpStatus(429)), (500, .httpStatus(500))] {
            SharedRPCURLProtocol.handler = { $0.respond("sensitive response must not enter errors", status: status) }
            do { _ = try await client.fetchPlanInfo(cookieHeader: cookie()); XCTFail("Expected HTTP failure") }
            catch { XCTAssertEqual(error as? CursorSharedAPIError, expected) }
        }
    }

    func testDecodedControlsAndMalformedDuplicateCookieNeverReachNetwork() async {
        SharedRPCURLProtocol.handler = { request in XCTFail("Malformed cookie reached network"); request.respond(#"{"isMerged":false}"#) }
        let client = makeClient()
        for header in ["WorkosCursorSessionToken=user%0Afixture::" + token(subject: "user\nfixture"), "WorkosCursorSessionToken; " + cookie()] {
            do { _ = try await client.fetchPlanInfo(cookieHeader: header); XCTFail("Expected invalid credential") }
            catch { XCTAssertEqual(error as? CursorSharedAPIError, .invalidCredential) }
        }
    }

    func testEmptyMalformedAndOversizedResponsesAreRejected() async {
        let client = makeClient()
        for (body, expected) in [("", CursorSharedAPIError.emptyResponse), ("not JSON", .invalidResponse), ("{}", .invalidResponse), (String(repeating: "x", count: 1_048_577), .responseTooLarge)] {
            SharedRPCURLProtocol.handler = { $0.respond(body) }
            do { _ = try await client.fetchPlanInfo(cookieHeader: cookie()); XCTFail("Expected invalid response") }
            catch { XCTAssertEqual(error as? CursorSharedAPIError, expected) }
        }
    }

    func testOversizedContentLengthIsRejectedBeforeBody() async {
        SharedRPCURLProtocol.handler = { $0.respond("{}", headers: ["Content-Length": "1048577"]) }
        do { _ = try await makeClient().fetchPlanInfo(cookieHeader: cookie()); XCTFail("Expected oversized response") }
        catch { XCTAssertEqual(error as? CursorSharedAPIError, .responseTooLarge) }
    }

    func testRedirectDoesNotForwardCredentialsOrReachDestination() async {
        SharedRPCURLProtocol.handler = { request in
            guard request.request.url?.host == "api2.cursor.sh" else { return XCTFail("Followed credential redirect") }
            let response = HTTPURLResponse(url: request.request.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://example.invalid/redirect"])!
            request.client?.urlProtocol(request, wasRedirectedTo: URLRequest(url: URL(string: "https://example.invalid/redirect")!), redirectResponse: response)
            request.respond("", status: 302, headers: ["Location": "https://example.invalid/redirect"])
        }
        do { _ = try await makeClient().fetchPlanInfo(cookieHeader: cookie()); XCTFail("Expected redirect rejection") }
        catch { XCTAssertEqual(error as? CursorSharedAPIError, .httpStatus(302)) }
    }

    func testTransportFailureDoesNotExposeUnderlyingPayload() async {
        SharedRPCURLProtocol.handler = { $0.client?.urlProtocol($0, didFailWithError: URLError(.notConnectedToInternet)) }
        do { _ = try await makeClient().fetchPlanInfo(cookieHeader: cookie()); XCTFail("Expected transport failure") }
        catch { XCTAssertEqual(error as? CursorSharedAPIError, .transport) }
    }

    func testCancelledTaskCancelsRequest() async {
        let started = expectation(description: "RPC started")
        SharedRPCURLProtocol.handler = { _ in started.fulfill() }
        let client = makeClient()
        let header = cookie()
        let task = Task { try await client.fetchPlanInfo(cookieHeader: header) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertEqual(error as? CursorSharedAPIError, .cancelled) }
    }
}

private final class SharedRPCURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((SharedRPCURLProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() {}

    func respond(_ text: String, status: Int = 200, headers: [String: String] = [:]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
