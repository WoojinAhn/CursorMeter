import Foundation
import SQLite3

/// Credential synthesized from the Cursor IDE's own auth state (#54).
struct IDECredential: Sendable, Equatable {
    let cookieHeader: String   // "WorkosCursorSessionToken=<id>%3A%3A<jwt>"
    let expiresAt: Date
    /// From `cursorAuth/cachedEmail` or `cursorAuth/email` — used when
    /// `/api/auth/me` 404s for GitHub-numeric identities.
    let email: String?
    /// From `cursorAuth/cachedScopedProfile.displayName`.
    let name: String?

    init(
        cookieHeader: String,
        expiresAt: Date,
        email: String? = nil,
        name: String? = nil
    ) {
        self.cookieHeader = cookieHeader
        self.expiresAt = expiresAt
        self.email = email
        self.name = name
    }
}

/// Reads the Cursor IDE's access token from its local state DB and synthesizes
/// the dashboard cookie header (CodexBar's production-proven pattern). The IDE
/// refreshes this token itself, so re-reading per refresh yields a credential
/// that tracks the IDE's live session. Read-only; never touches refreshToken.
///
/// Concurrency: no stored sqlite3 handle — open/query/close within a single
/// read() call, so plain Sendable holds. busy_timeout can block ~250ms;
/// callers invoke off the MainActor.
struct CursorAppAuthReader: Sendable {
    let dbPath: String

    init(dbPath: String = NSHomeDirectory()
        + "/Library/Application Support/Cursor/User/globalStorage/state.vscdb") {
        self.dbPath = dbPath
    }

    func read(now: Date = Date()) -> IDECredential? {
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT value FROM ItemTable WHERE key = 'cursorAuth/accessToken'",
            -1, &stmt, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cString = sqlite3_column_text(stmt, 0)
        else { return nil }
        // Value may be stored as a bare string or JSON-quoted.
        let jwt = String(cString: cString).trimmingCharacters(in: CharacterSet(charactersIn: "\""))

        guard let claims = Self.parseJWTClaims(jwt),
              claims.exp > now.addingTimeInterval(60),
              let userID = Self.userID(fromSub: claims.sub)
        else { return nil }

        let email = Self.readString(db: db, key: "cursorAuth/cachedEmail")
            ?? Self.readString(db: db, key: "cursorAuth/email")
        let name = Self.displayName(
            fromProfileJSON: Self.readString(db: db, key: "cursorAuth/cachedScopedProfile"))

        return IDECredential(
            cookieHeader: Self.makeCookieHeader(userID: userID, jwt: jwt),
            expiresAt: claims.exp,
            email: email,
            name: name
        )
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

    /// Single-key string read on an already-open handle. Returns nil on
    /// missing key or empty value. Never logs the value.
    nonisolated static func readString(db: OpaquePointer?, key: String) -> String? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db, "SELECT value FROM ItemTable WHERE key = ?",
            -1, &stmt, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cString = sqlite3_column_text(stmt, 0)
        else { return nil }
        let value = String(cString: cString).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return value.isEmpty ? nil : value
    }

    nonisolated static func displayName(fromProfileJSON json: String?) -> String? {
        guard let json, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["displayName"] as? String
        else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
