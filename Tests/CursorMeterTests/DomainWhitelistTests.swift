import XCTest
@testable import CursorMeter

final class DomainWhitelistTests: XCTestCase {

    // MARK: - Exact Matches

    @MainActor
    func testExactMatchCursorDotCom() {
        XCTAssertTrue(LoginWindow.isAllowedHost("cursor.com"))
    }

    @MainActor
    func testExactMatchWwwCursorDotCom() {
        XCTAssertTrue(LoginWindow.isAllowedHost("www.cursor.com"))
    }

    @MainActor
    func testExactMatchAuthenticatorCursorSh() {
        XCTAssertTrue(LoginWindow.isAllowedHost("authenticator.cursor.sh"))
    }

    @MainActor
    func testExactMatchAuthenticateCursorSh() {
        XCTAssertTrue(LoginWindow.isAllowedHost("authenticate.cursor.sh"))
    }

    @MainActor
    func testExactMatchApiWorkos() {
        XCTAssertTrue(LoginWindow.isAllowedHost("api.workos.com"))
    }

    @MainActor
    func testExactMatchAccountsGoogle() {
        XCTAssertTrue(LoginWindow.isAllowedHost("accounts.google.com"))
    }

    @MainActor
    func testExactMatchGithub() {
        XCTAssertTrue(LoginWindow.isAllowedHost("github.com"))
    }

    @MainActor
    func testExactMatchMicrosoftonline() {
        XCTAssertTrue(LoginWindow.isAllowedHost("login.microsoftonline.com"))
    }

    @MainActor
    func testExactMatchStripeJs() {
        XCTAssertTrue(LoginWindow.isAllowedHost("js.stripe.com"))
    }

    @MainActor
    func testExactMatchStripeNetwork() {
        XCTAssertTrue(LoginWindow.isAllowedHost("m.stripe.network"))
    }

    // MARK: - Subdomain Matches

    @MainActor
    func testSubdomainCursorCom() {
        XCTAssertTrue(LoginWindow.isAllowedHost("api.cursor.com"))
        XCTAssertTrue(LoginWindow.isAllowedHost("deep.sub.cursor.com"))
    }

    @MainActor
    func testSubdomainCursorSh() {
        XCTAssertTrue(LoginWindow.isAllowedHost("auth2.cursor.sh"))
    }

    @MainActor
    func testSubdomainWorkos() {
        XCTAssertTrue(LoginWindow.isAllowedHost("auth.workos.com"))
    }

    @MainActor
    func testSubdomainGoogle() {
        XCTAssertTrue(LoginWindow.isAllowedHost("oauth2.google.com"))
    }

    @MainActor
    func testSubdomainGithub() {
        XCTAssertTrue(LoginWindow.isAllowedHost("api.github.com"))
    }

    @MainActor
    func testSubdomainMicrosoftonline() {
        XCTAssertTrue(LoginWindow.isAllowedHost("tenant.login.microsoftonline.com"))
    }

    @MainActor
    func testSubdomainStripe() {
        XCTAssertTrue(LoginWindow.isAllowedHost("api.stripe.com"))
    }

    @MainActor
    func testSubdomainStripeNetwork() {
        XCTAssertTrue(LoginWindow.isAllowedHost("r.stripe.network"))
    }

    // MARK: - Blocked Domains

    @MainActor
    func testBlocksRandomDomain() {
        XCTAssertFalse(LoginWindow.isAllowedHost("evil.com"))
    }

    @MainActor
    func testBlocksGoogleDotCom() {
        // google.com itself is NOT in the allowed set (only accounts.google.com)
        XCTAssertFalse(LoginWindow.isAllowedHost("google.com"))
    }

    @MainActor
    func testBlocksPhishing() {
        XCTAssertFalse(LoginWindow.isAllowedHost("cursor.com.evil.com"))
    }

    @MainActor
    func testBlocksSimilarDomain() {
        XCTAssertFalse(LoginWindow.isAllowedHost("notcursor.com"))
        XCTAssertFalse(LoginWindow.isAllowedHost("fakegithub.com"))
    }

    @MainActor
    func testBlocksPartialSuffix() {
        // "xcursor.com" ends with "cursor.com" but NOT ".cursor.com"
        XCTAssertFalse(LoginWindow.isAllowedHost("xcursor.com"))
    }

    // MARK: - Edge Cases

    @MainActor
    func testEmptyString() {
        XCTAssertFalse(LoginWindow.isAllowedHost(""))
    }

    @MainActor
    func testWorkosComNotAllowed() {
        // "workos.com" is NOT in the exact set (only api.workos.com)
        XCTAssertFalse(LoginWindow.isAllowedHost("workos.com"))
    }

    @MainActor
    func testStripeDotComNotAllowed() {
        // "stripe.com" is NOT in the exact set
        XCTAssertFalse(LoginWindow.isAllowedHost("stripe.com"))
    }
}
