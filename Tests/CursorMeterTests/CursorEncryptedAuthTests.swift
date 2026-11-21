import XCTest
import SQLite3
import Security
import LocalAuthentication
@testable import CursorMeter

final class CursorEncryptedAuthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    // Generated independently with Python hashlib.pbkdf2_hmac and OpenSSL enc.
    private let encrypted = "cursor-safe-storage:v1:djEwLkDopNkTvjwEEL2FVrrPwqwUL8f2wSmwTL6vuTe9am9Q/5/LlO496MBtiUglOK1oxSjXI0MD6/XisxgGvaAJ4G22jw4/hgyT45iXZCW6ruE="
    private let jwt = "e30.eyJzdWIiOiJhdXRoMHx1c2VyX3N5bnRoZXRpYyIsImV4cCI6NDEwMjQ0NDgwMH0.sig"
    private let expired = "cursor-safe-storage:v1:djEwLkDopNkTvjwEEL2FVrrPwqwUL8f2wSmwTL6vuTe9am9Q/5/LlO496MBtiUglOK1oDMvYAyqpCxz7nS4EfyMeDPocMoy983UiwJPXpbmvESQ="
    private let invalidSubject = "cursor-safe-storage:v1:djEw8512Ca8ygBIYrigTvo/2rF7lwVf5wmj/YX4BUHJAOHazt7dkbFH9yxnveTzZE+XuY1am5CDKhS+GuEEMyULSYQ=="

    final class KeychainStub: @unchecked Sendable {
        private let lock = NSLock()
        var handler: (String, Bool) -> CursorSafeStorage.SecretResult
        private var calls: [(String, Bool)] = []
        init(_ handler: @escaping (String, Bool) -> CursorSafeStorage.SecretResult) { self.handler = handler }
        func read(account: String, interaction: Bool) -> CursorSafeStorage.SecretResult {
            lock.lock(); defer { lock.unlock() }
            calls.append((account, interaction))
            return handler(account, interaction)
        }
        var snapshot: [(String, Bool)] { lock.withLock { calls } }
        var storage: CursorSafeStorage { CursorSafeStorage(readSecret: { [self] in read(account: $0, interaction: $1) }) }
    }

    private func reader(_ token: String, storage: CursorSafeStorage) throws -> CursorAppAuthReader {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("state.vscdb").path
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT)", nil, nil, nil)
        var statement: OpaquePointer?
        sqlite3_prepare_v2(db, "INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', ?)", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, token, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
        return CursorAppAuthReader(dbPath: path, safeStorage: storage)
    }

    func testEncryptedAndQuotedValuesUseIndependentVector() throws {
        for token in [encrypted, "\"" + encrypted + "\""] {
            let stub = KeychainStub { _, _ in .found(Data("synthetic-password".utf8)) }
            let reader = try reader(token, storage: stub.storage)
            let result = reader.readResult(now: now)
            XCTAssertEqual(result.credential?.cookieHeader, "WorkosCursorSessionToken=user_synthetic%3A%3A" + jwt)
            XCTAssertEqual(stub.snapshot.map(\.0), ["Cursor Key"])
            XCTAssertFalse(stub.snapshot.contains { $0.1 })
        }
    }

    func testPlaintextAndQuotedJWTNeverReadKeychain() throws {
        for token in [jwt, "\"" + jwt + "\""] {
            let stub = KeychainStub { _, _ in XCTFail("Plaintext must not access Safe Storage"); return .unavailable }
            XCTAssertNotNil(try reader(token, storage: stub.storage).read(now: now))
        }
    }

    func testMalformedEnvelopeRejectedBeforeAnySecretRead() throws {
        let payloads = ["cursor-safe-storage:v2:abcd", "cursor-safe-storage:v1:", "cursor-safe-storage:v1:!bad",
                        "cursor-safe-storage:v1:" + Data("v10".utf8).base64EncodedString(),
                        "cursor-safe-storage:v1:" + (Data("v11".utf8) + Data(repeating: 0, count: 16)).base64EncodedString(),
                        "cursor-safe-storage:v1:" + (Data("v10".utf8) + Data(repeating: 0, count: 17)).base64EncodedString(),
                        "cursor-safe-storage:v1:" + String(repeating: "A", count: 100_000)]
        for token in payloads {
            let stub = KeychainStub { _, _ in XCTFail("Malformed envelope accessed Safe Storage"); return .unavailable }
            XCTAssertNil(try reader(token, storage: stub.storage).readResult(now: now, allowInteraction: true).credential)
        }
    }

    func testWrongKeyInvalidPaddingExpiryAndSubjectNeverProduceCredential() throws {
        let wrong = KeychainStub { _, _ in .found(Data("wrong-password".utf8)) }
        XCTAssertNil(try reader(encrypted, storage: wrong.storage).read(now: now))
        for token in [expired, invalidSubject, "cursor-safe-storage:v1:" + (Data("v10".utf8) + Data(repeating: 0, count: 16)).base64EncodedString()] {
            let stub = KeychainStub { _, _ in .found(Data("synthetic-password".utf8)) }
            XCTAssertNil(try reader(token, storage: stub.storage).read(now: now))
        }
    }

    func testBackgroundCannotPromptAndManualAttemptIsBoundedOnDenial() throws {
        let stub = KeychainStub { _, _ in .authorizationRequired }
        let reader = try reader(encrypted, storage: stub.storage)
        XCTAssertEqual(reader.readResult(now: now), .authorizationRequired)
        XCTAssertEqual(stub.snapshot.map(\.1), [false])
        XCTAssertEqual(reader.readResult(now: now, allowInteraction: true), .authorizationRequired)
        XCTAssertEqual(stub.snapshot.map(\.0), ["Cursor Key", "Cursor Key", "Cursor Key"])
        XCTAssertEqual(stub.snapshot.map(\.1), [false, false, true])
    }

    func testCurrentAccountMissingUsesLegacyWithoutAdditionalPrompt() throws {
        let stub = KeychainStub { account, interactive in
            if account == "Cursor Key" { return .missing }
            return interactive ? .found(Data("synthetic-password".utf8)) : .authorizationRequired
        }
        let reader = try reader(encrypted, storage: stub.storage)
        XCTAssertNotNil(reader.readResult(now: now, allowInteraction: true).credential)
        XCTAssertEqual(stub.snapshot.map(\.0), ["Cursor Key", "Cursor", "Cursor"])
        XCTAssertEqual(stub.snapshot.map(\.1), [false, false, true])
        XCTAssertNotNil(reader.read(now: now))
        XCTAssertEqual(stub.snapshot.count, 3, "Only the derived key is reused in memory")
    }

    func testMissingSafeStorageKeyIsNotMisreportedAsMissingIDECredential() throws {
        let stub = KeychainStub { _, _ in .missing }
        XCTAssertEqual(try reader(encrypted, storage: stub.storage).readResult(now: now), .encryptedUnavailable)
        XCTAssertEqual(stub.snapshot.map(\.0), ["Cursor Key", "Cursor"])
        XCTAssertEqual(stub.snapshot.map(\.1), [false, false])
    }

    func testNonMissingFailureDoesNotQueryAnotherAccount() throws {
        for result: CursorSafeStorage.SecretResult in [.unavailable, .authorizationRequired] {
            let stub = KeychainStub { _, _ in result }
            _ = try reader(encrypted, storage: stub.storage).readResult(now: now)
            XCTAssertEqual(stub.snapshot.map(\.0), ["Cursor Key"])
        }
    }

    func testCachedKeyCannotResurrectRemovedOrReplacedCurrentToken() throws {
        let stub = KeychainStub { _, _ in .found(Data("synthetic-password".utf8)) }
        let reader = try reader(encrypted, storage: stub.storage)
        XCTAssertNotNil(reader.read(now: now))
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(reader.dbPath, &db), SQLITE_OK)
        sqlite3_exec(db, "UPDATE ItemTable SET value = 'invalid-token'", nil, nil, nil)
        XCTAssertNil(reader.read(now: now))
        sqlite3_exec(db, "DELETE FROM ItemTable", nil, nil, nil)
        sqlite3_close(db)
        XCTAssertNil(reader.read(now: now))
    }

    func testProductionQueryUsesExactAccountAndNoninteractivePolicy() throws {
        let query = try XCTUnwrap(CursorSafeStorage.query(account: "Cursor Key", allowInteraction: false))
        XCTAssertEqual(query[kSecAttrService as String] as? String, "Cursor Safe Storage")
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, "Cursor Key")
        XCTAssertEqual((query[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed, true)
        XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String, kSecUseAuthenticationUIFail as String)
        let interactive = try XCTUnwrap(CursorSafeStorage.query(account: "Cursor Key", allowInteraction: true))
        XCTAssertEqual((interactive[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed, false)
        XCTAssertNil(interactive[kSecUseAuthenticationUI as String])
        XCTAssertEqual(query[kSecReturnData as String] as? Bool, true)
    }
    func testMissingLegacyPolicyCannotProduceNoninteractiveKeychainQuery() {
        XCTAssertNil(CursorSafeStorage.query(account: "Cursor Key", allowInteraction: false, uiFailPolicy: nil))
        XCTAssertNotNil(CursorSafeStorage.query(account: "Cursor Key", allowInteraction: true, uiFailPolicy: nil))
    }

}
