import XCTest
@testable import CursorBar

final class CursorAPIClientTests: XCTestCase {
    private var client: CursorAPIClient!

    override func setUp() {
        super.setUp()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        client = CursorAPIClient(configuration: config)
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        client = nil
        super.tearDown()
    }

    // MARK: - fetchUsage

    func testFetchUsageSuccess() async throws {
        let json = """
        {
            "gpt-4": { "numRequests": 42, "maxRequestUsage": 500 },
            "startOfMonth": "2026-02-01T00:00:00.000Z"
        }
        """
        setMockResponse(statusCode: 200, json: json)

        let result = try await client.fetchUsage(cookieHeader: "session=test")

        XCTAssertEqual(result.gpt4?.numRequests, 42)
        XCTAssertEqual(result.gpt4?.maxRequestUsage, 500)
        XCTAssertEqual(result.startOfMonth, "2026-02-01T00:00:00.000Z")
    }

    // MARK: - fetchUserInfo

    func testFetchUserInfoSuccess() async throws {
        let json = """
        { "email": "alice@example.com", "name": "Alice" }
        """
        setMockResponse(statusCode: 200, json: json)

        let result = try await client.fetchUserInfo(cookieHeader: "session=test")

        XCTAssertEqual(result.email, "alice@example.com")
        XCTAssertEqual(result.name, "Alice")
    }

    // MARK: - HTTP Errors

    func testUnauthorizedThrows() async {
        setMockResponse(statusCode: 401, json: "{}")

        do {
            _ = try await client.fetchUsage(cookieHeader: "bad")
            XCTFail("Expected APIError.unauthorized")
        } catch {
            guard case APIError.unauthorized = error else {
                return XCTFail("Expected .unauthorized, got \(error)")
            }
        }
    }

    func testForbiddenThrows() async {
        setMockResponse(statusCode: 403, json: "{}")

        do {
            _ = try await client.fetchUsage(cookieHeader: "bad")
            XCTFail("Expected APIError.forbidden")
        } catch {
            guard case APIError.forbidden = error else {
                return XCTFail("Expected .forbidden, got \(error)")
            }
        }
    }

    func testServerErrorThrowsHTTPError() async {
        setMockResponse(statusCode: 500, json: "{}")

        do {
            _ = try await client.fetchUsage(cookieHeader: "bad")
            XCTFail("Expected APIError.httpError")
        } catch {
            guard case APIError.httpError(let code) = error else {
                return XCTFail("Expected .httpError, got \(error)")
            }
            XCTAssertEqual(code, 500)
        }
    }

    // MARK: - Decoding Error

    func testInvalidJSONThrowsDecodingError() async {
        setMockResponse(statusCode: 200, json: "NOT_JSON")

        do {
            _ = try await client.fetchUsage(cookieHeader: "session=test")
            XCTFail("Expected DecodingError")
        } catch is DecodingError {
            // expected
        } catch {
            XCTFail("Expected DecodingError, got \(error)")
        }
    }

    // MARK: - Helpers

    private func setMockResponse(statusCode: Int, json: String) {
        MockURLProtocol.requestHandler = { request in
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: nil,
                headerFields: nil
            )!
            return (response, Data(json.utf8))
        }
    }
}
