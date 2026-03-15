import XCTest
@testable import CursorMeter

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
            "gpt-4": { "numRequests": 42, "numRequestsTotal": 42, "numTokens": 1000, "maxRequestUsage": 500, "maxTokenUsage": null },
            "startOfMonth": "2026-02-01T00:00:00.000Z"
        }
        """
        setMockResponse(statusCode: 200, json: json)

        let result = try await client.fetchUsage(cookieHeader: "session=test")

        XCTAssertEqual(result.primaryModel?.numRequests, 42)
        XCTAssertEqual(result.primaryModel?.maxRequestUsage, 500)
        XCTAssertEqual(result.startOfMonth, "2026-02-01T00:00:00.000Z")
        XCTAssertEqual(result.models.count, 1)
        XCTAssertNotNil(result.models["gpt-4"])
    }

    func testFetchUsageDynamicKeys() async throws {
        let json = """
        {
            "gpt-4o": { "numRequests": 10, "maxRequestUsage": 500 },
            "claude-sonnet": { "numRequests": 5, "maxRequestUsage": null },
            "startOfMonth": "2026-03-01T00:00:00.000Z"
        }
        """
        setMockResponse(statusCode: 200, json: json)

        let result = try await client.fetchUsage(cookieHeader: "session=test")

        XCTAssertEqual(result.models.count, 2)
        XCTAssertNotNil(result.models["gpt-4o"])
        XCTAssertNotNil(result.models["claude-sonnet"])
        XCTAssertEqual(result.primaryModel?.maxRequestUsage, 500, "Should prefer model with maxRequestUsage")
    }

    func testFetchUsageNoModels() async throws {
        let json = """
        { "startOfMonth": "2026-03-01T00:00:00.000Z" }
        """
        setMockResponse(statusCode: 200, json: json)

        let result = try await client.fetchUsage(cookieHeader: "session=test")

        XCTAssertTrue(result.models.isEmpty)
        XCTAssertNil(result.primaryModel)
        XCTAssertEqual(result.startOfMonth, "2026-03-01T00:00:00.000Z")
    }

    func testFetchUsageSummarySuccess() async throws {
        let json = """
        {
            "billingCycleStart": "2026-03-01T07:29:44.000Z",
            "billingCycleEnd": "2026-04-01T07:29:44.000Z",
            "membershipType": "enterprise",
            "limitType": "team",
            "isUnlimited": false,
            "individualUsage": {
                "plan": { "enabled": true, "used": 8, "limit": 2000, "remaining": 1992, "totalPercentUsed": 0.1 },
                "onDemand": { "enabled": true, "used": 0, "limit": 2000, "remaining": 2000 }
            },
            "teamUsage": {
                "onDemand": { "enabled": true, "used": 0, "limit": 120000, "remaining": 120000 }
            }
        }
        """
        setMockResponse(statusCode: 200, json: json)

        let result = try await client.fetchUsageSummary(cookieHeader: "session=test")

        XCTAssertEqual(result.membershipType, "enterprise")
        XCTAssertEqual(result.billingCycleEnd, "2026-04-01T07:29:44.000Z")
        XCTAssertEqual(result.isUnlimited, false)
        XCTAssertEqual(result.individualUsage?.plan?.used, 8)
        XCTAssertEqual(result.individualUsage?.plan?.limit, 2000)
        XCTAssertEqual(result.individualUsage?.onDemand?.limit, 2000)
        XCTAssertEqual(result.teamUsage?.onDemand?.limit, 120000)
    }

    func testFetchUsageSummaryFreePlan() async throws {
        let json = """
        {
            "billingCycleStart": "2026-03-15T03:23:58.561Z",
            "billingCycleEnd": "2026-04-15T03:23:58.561Z",
            "membershipType": "free",
            "limitType": "user",
            "isUnlimited": false,
            "individualUsage": {
                "plan": {
                    "enabled": true,
                    "used": 0,
                    "limit": 0,
                    "remaining": 0,
                    "breakdown": { "included": 0, "bonus": 2, "total": 2 },
                    "totalPercentUsed": 1
                },
                "onDemand": { "enabled": false, "used": 0, "limit": null, "remaining": null }
            },
            "teamUsage": {}
        }
        """
        setMockResponse(statusCode: 200, json: json)

        let result = try await client.fetchUsageSummary(cookieHeader: "session=test")

        XCTAssertEqual(result.membershipType, "free")
        XCTAssertEqual(result.individualUsage?.plan?.limit, 0)
        XCTAssertEqual(result.individualUsage?.plan?.totalPercentUsed, 1)
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
