import Foundation
import SQLite3

/// Credential synthesized from the Cursor IDE's own auth state (#54).
struct IDECredential: Sendable, Equatable {
    let cookieHeader: String   // "WorkosCursorSessionToken=<id>%3A%3A<jwt>"
    let expiresAt: Date
}

enum IDECredentialReadResult: Equatable, Sendable {
    case available(IDECredential), authorizationRequired, encryptedUnavailable, unavailable

    var credential: IDECredential? {
        if case .available(let credential) = self { return credential }
        return nil
    }
}

/// Reads the Cursor IDE's access token from its local state DB and synthesizes
/// the dashboard cookie header (CodexBar's production-proven pattern). The IDE
/// refreshes this token itself, so re-reading per refresh yields a credential
/// that tracks the IDE's live session. Read-only; never touches refreshToken.
///
/// Concurrency: no stored sqlite3 handle — open/query/close within a single
/// read() call. Safe Storage serializes key access; manual authorization can
/// wait for system UI. Callers perform all reads off the MainActor.
struct CursorAppAuthReader: Sendable {
    let dbPath: String
    private let safeStorage: CursorSafeStorage

    init(dbPath: String = NSHomeDirectory()
        + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb",
         safeStorage: CursorSafeStorage = CursorSafeStorage()) {
        self.dbPath = dbPath
        self.safeStorage = safeStorage
    }

    func read(now: Date = Date()) -> IDECredential? {
        readResult(now: now).credential
    }

    func readResult(now: Date = Date(), allowInteraction: Bool = false) -> IDECredentialReadResult {
        guard let stored = storedToken() else { return .unavailable }
        let jwt: String
        if stored.hasPrefix("cursor-safe-storage:") {
            let prefix = "cursor-safe-storage:v1:"
            guard stored.hasPrefix(prefix), stored.utf8.count <= 65_536,
                  let payload = Data(base64Encoded: String(stored.dropFirst(prefix.count))),
                  payload.starts(with: Data("v10".utf8)), payload.count > 3,
                  (payload.count - 3).isMultiple(of: 16) else { return .encryptedUnavailable }
            switch safeStorage.decrypt(Data(payload.dropFirst(3)), allowInteraction: allowInteraction) {
            case .plaintext(let value): jwt = value
            case .authorizationRequired: return .authorizationRequired
            case .unavailable: return .encryptedUnavailable
            }
        } else { jwt = stored }
        guard let claims = Self.parseJWTClaims(jwt),
              claims.exp > now.addingTimeInterval(60),
              let userID = Self.userID(fromSub: claims.sub) else { return .unavailable }
        return .available(IDECredential(
            cookieHeader: Self.makeCookieHeader(userID: userID, jwt: jwt), expiresAt: claims.exp))
    }

    private func storedToken() -> String? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'",
                                -1, &statement, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_bytes(statement, 0) <= 65_536,
              let text = sqlite3_column_text(statement, 0) else { return nil }
        let stored = String(cString: text)
        if stored.hasPrefix("\""), let data = stored.data(using: .utf8) {
            return try? JSONDecoder().decode(String.self, from: data)
        }
        return stored
    }

    // MARK: - Pure helpers

    nonisolated static func parseJWTClaims(_ jwt: String) -> (sub: String, exp: Date)? {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        b64 += String(repeating: "=", count: (4 - b64.count % 4) % 4)
        guard let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sub = json["sub"] as? String,
              let exp = json["exp"] as? TimeInterval
        else { return nil }
        return (sub, Date(timeIntervalSince1970: exp))
    }

    /// WorkOS subs look like "auth0|user_xxx" — the dashboard cookie wants the
    /// part after the last pipe.
    nonisolated static func userID(fromSub sub: String) -> String? {
        guard let idx = sub.lastIndex(of: "|"), idx < sub.index(before: sub.endIndex)
        else { return nil }
        return String(sub[sub.index(after: idx)...])
    }

    nonisolated static func makeCookieHeader(userID: String, jwt: String) -> String {
        "WorkosCursorSessionToken=\(userID)%3A%3A\(jwt)"
    }
}
