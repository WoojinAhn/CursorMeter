import XCTest
import SQLite3
@testable import CursorMeter

final class CursorAppAuthReaderTests: XCTestCase {

    // MARK: - Fixtures

    /// Fake JWT: valid base64url payload, garbage header/signature (parse only reads payload).
    private func makeJWT(sub: String = "auth0|user_01ABC", exp: TimeInterval) -> String {
        let payload: [String: Any] = ["sub": sub, "exp": Int(exp)]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiJ9.\(b64).sig"
    }

    /// Fixture state.vscdb replica in a fresh temp dir. token == nil → row absent.
    private func makeFixtureDB(token: String?) -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vscdb-fixture-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("state.vscdb").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB)", nil, nil, nil)
        if let token {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, "INSERT INTO ItemTable (key, value) VALUES ('cursorAuth/accessToken', ?)", -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, token, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
        sqlite3_close(db)
        return path
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Pure helpers

    func testParseJWTClaimsValid() {
        let jwt = makeJWT(sub: "auth0|user_42", exp: now.timeIntervalSince1970 + 3600)
        let claims = CursorAppAuthReader.parseJWTClaims(jwt)
        XCTAssertEqual(claims?.sub, "auth0|user_42")
        XCTAssertEqual(claims?.exp.timeIntervalSince1970 ?? 0,
                       now.timeIntervalSince1970 + 3600, accuracy: 1)
    }

    func testParseJWTClaimsMalformed() {
        XCTAssertNil(CursorAppAuthReader.parseJWTClaims(""))
        XCTAssertNil(CursorAppAuthReader.parseJWTClaims("only.two"))
        XCTAssertNil(CursorAppAuthReader.parseJWTClaims("a.!!!notbase64!!!.c"))
    }

    func testUserIDFromSub() {
        XCTAssertEqual(CursorAppAuthReader.userID(fromSub: "auth0|user_42"), "user_42")
        XCTAssertEqual(CursorAppAuthReader.userID(fromSub: "a|b|user_9"), "user_9")
        XCTAssertNil(CursorAppAuthReader.userID(fromSub: "nopipe"))
    }

    func testMakeCookieHeader() {
        XCTAssertEqual(
            CursorAppAuthReader.makeCookieHeader(userID: "user_42", jwt: "J.W.T"),
            "WorkosCursorSessionToken=user_42%3A%3AJ.W.T"
        )
    }

    // MARK: - Reader

    func testReadValidToken() {
        let jwt = makeJWT(exp: now.timeIntervalSince1970 + 7200)
        let reader = CursorAppAuthReader(dbPath: makeFixtureDB(token: jwt))
        let cred = reader.read(now: now)
        XCTAssertEqual(cred?.cookieHeader, "WorkosCursorSessionToken=user_01ABC%3A%3A\(jwt)")
        XCTAssertEqual(cred?.expiresAt.timeIntervalSince1970 ?? 0,
                       now.timeIntervalSince1970 + 7200, accuracy: 1)
    }

    func testReadEncryptedTokenRegression() {
        // Independent fixture: Python hashlib PBKDF2 + OpenSSL AES-CBC.
        let stored = "cursor-safe-storage:v1:djEwLkDopNkTvjwEEL2FVrrPwqwUL8f2wSmwTL6vuTe9am9Q/5/LlO496MBtiUglOK1oxSjXI0MD6/XisxgGvaAJ4G22jw4/hgyT45iXZCW6ruE="
        let reader = CursorAppAuthReader(dbPath: makeFixtureDB(token: stored),
            safeStorage: CursorSafeStorage(readSecret: { _, _ in .found(Data("synthetic-password".utf8)) }))
        XCTAssertEqual(reader.read(now: now)?.cookieHeader,
                       "WorkosCursorSessionToken=user_synthetic%3A%3Ae30.eyJzdWIiOiJhdXRoMHx1c2VyX3N5bnRoZXRpYyIsImV4cCI6NDEwMjQ0NDgwMH0.sig")
    }

    func testReadRejectsNearExpiredToken() {
        let jwt = makeJWT(exp: now.timeIntervalSince1970 + 30)  // < 60s guard
        let reader = CursorAppAuthReader(dbPath: makeFixtureDB(token: jwt))
        XCTAssertNil(reader.read(now: now))
    }

    func testReadMissingKey() {
        XCTAssertNil(CursorAppAuthReader(dbPath: makeFixtureDB(token: nil)).read(now: now))
    }

    func testReadMissingFile() {
        XCTAssertNil(CursorAppAuthReader(dbPath: "/nonexistent/state.vscdb").read(now: now))
    }

    func testReadMalformedToken() {
        XCTAssertNil(CursorAppAuthReader(dbPath: makeFixtureDB(token: "not-a-jwt")).read(now: now))
    }
}
