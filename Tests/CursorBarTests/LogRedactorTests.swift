import XCTest
@testable import CursorBar

final class LogRedactorTests: XCTestCase {

    // MARK: - Email

    func testRedactsEmail() {
        let input = "User login: alice@example.com succeeded"
        let result = LogRedactor.redact(input)
        XCTAssertEqual(result, "User login: <redacted-email> succeeded")
    }

    func testRedactsEmailCaseInsensitive() {
        let input = "Contact: Alice.O'Brien+tag@Sub.EXAMPLE.COM"
        let result = LogRedactor.redact(input)
        XCTAssertFalse(result.contains("@"), "Email should be redacted")
        XCTAssertTrue(result.contains("<redacted-email>"))
    }

    // MARK: - Cookie Header

    func testRedactsCookieHeader() {
        let input = "Cookie: session=abc123; token=xyz"
        let result = LogRedactor.redact(input)
        XCTAssertEqual(result, "Cookie: <redacted>")
    }

    func testRedactsCookieHeaderCaseInsensitive() {
        let input = "COOKIE : sid=secret_value"
        let result = LogRedactor.redact(input)
        XCTAssertEqual(result, "COOKIE : <redacted>")
    }

    // MARK: - Authorization Header

    func testRedactsAuthorizationHeader() {
        let input = "Authorization: Basic dXNlcjpwYXNz"
        let result = LogRedactor.redact(input)
        XCTAssertEqual(result, "Authorization: <redacted>")
    }

    func testRedactsAuthorizationHeaderCaseInsensitive() {
        let input = "authorization:token_value_here"
        let result = LogRedactor.redact(input)
        XCTAssertEqual(result, "authorization:<redacted>")
    }

    // MARK: - Bearer Token

    func testRedactsBearerTokenStandalone() {
        let input = "Token is Bearer eyJhbGciOiJSUzI1NiJ9 in header"
        let result = LogRedactor.redact(input)
        XCTAssertEqual(result, "Token is Bearer <redacted> in header")
    }

    func testRedactsBearerTokenWithSpecialChars() {
        let input = "bearer abc+def/ghi.jkl-mno_pqr=="
        let result = LogRedactor.redact(input)
        XCTAssertEqual(result, "Bearer <redacted>")
    }

    // MARK: - Composite

    func testRedactsMultipleSensitiveItems() {
        let input = """
            User: admin@corp.io
            Cookie: session=abc
            Authorization: Bearer tok123
            """
        let result = LogRedactor.redact(input)
        XCTAssertFalse(result.contains("admin@corp.io"))
        XCTAssertFalse(result.contains("session=abc"))
        XCTAssertFalse(result.contains("tok123"))
        XCTAssertTrue(result.contains("<redacted-email>"))
    }

    // MARK: - No Sensitive Data

    func testNoSensitiveDataUnchanged() {
        let input = "GET /api/health → 200 OK (12ms)"
        let result = LogRedactor.redact(input)
        XCTAssertEqual(result, input)
    }

    func testEmptyStringUnchanged() {
        XCTAssertEqual(LogRedactor.redact(""), "")
    }
}
