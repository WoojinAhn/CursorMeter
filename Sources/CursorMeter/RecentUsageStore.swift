import CryptoKit
import Foundation

enum RecentUsageRequestScope: Equatable, Sendable {
    case personal
    case enterprise(teamID: Int, userID: Int)

    var digest: String? {
        switch self {
        case .personal:
            RecentUsageBinding.digest("scope:personal:team:0:user:none")
        case let .enterprise(teamID, userID):
            teamID > 0 && userID > 0
                ? RecentUsageBinding.digest("scope:enterprise:team:\(teamID):user:\(userID)")
                : nil
        }
    }
}

struct RecentUsageBinding: Codable, Equatable, Sendable {
    let credentialDigest: String
    let subjectDigest: String?
    let scopeDigest: String
}

extension RecentUsageBinding {
    init?(cookieHeader: String, subject: String?, scope: RecentUsageRequestScope) {
        guard let credential = Self.credentialDigest(cookieHeader: cookieHeader),
              let scopeDigest = scope.digest else { return nil }
        self.init(credentialDigest: credential, subjectDigest: Self.subjectDigest(subject), scopeDigest: scopeDigest)
    }

    static func credentialDigest(cookieHeader: String) -> String? {
        let matches = cookieHeader.split(separator: ";", omittingEmptySubsequences: false).compactMap { field -> String? in
            let parts = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts[0].trimmingCharacters(in: .whitespaces) == "WorkosCursorSessionToken" else { return nil }
            return parts.count == 2 ? String(parts[1]) : ""
        }
        guard matches.count == 1, let value = matches.first, !value.isEmpty,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.controlCharacters.contains($0)
              }) else { return nil }
        return digest(value)
    }

    static func subjectDigest(_ subject: String?) -> String? {
        guard let subject, !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return digest("subject:\(subject)")
    }

    fileprivate static func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    fileprivate var isValid: Bool {
        func validDigest(_ value: String) -> Bool {
            value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
        }
        return validDigest(credentialDigest) && validDigest(scopeDigest) && subjectDigest.map(validDigest) != false
    }
}

struct RecentUsageSnapshot: Codable, Equatable, Sendable {
    let candidate: RecentUsageCandidate
    let binding: RecentUsageBinding

    var isValid: Bool {
        guard binding.isValid, candidate.entries.count <= RecentUsageCandidate.limit,
              Self.validDate(candidate.cachedAt) else { return false }
        return candidate.entries.allSatisfy { entry in
            Self.validDate(entry.date) && (entry.tokens.map { $0 >= 0 } ?? true)
                && (entry.chargedCents.map { $0.isFinite && $0 >= 0 } ?? true)
        }
    }

    private static func validDate(_ date: Date) -> Bool {
        guard date.timeIntervalSinceReferenceDate.isFinite else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let second = calendar.dateInterval(of: .second, for: date) else { return false }
        return second.contains(date)
    }
}

actor RecentUsageStore {
    struct Hooks: Sendable {
        var afterRead: (@Sendable () async -> Void)? = nil
        var beforeWrite: (@Sendable () throws -> Void)? = nil
        var beforeRemove: (@Sendable () throws -> Void)? = nil
    }

    private struct Envelope: Codable {
        let version: Int
        let snapshot: RecentUsageSnapshot
        let validityToken: String
    }

    private enum StoreError: Error {
        case invalidSnapshot
        case oversized
    }

    private static let maximumBytes = 256 * 1024
    private let fileURL: URL
    private let hooks: Hooks
    private var greatestOperation: UInt64 = 0

    init(fileURL: URL, hooks: Hooks = Hooks()) {
        self.fileURL = fileURL.standardizedFileURL
        self.hooks = hooks
    }

    nonisolated var cacheIdentity: URL { fileURL }

    func load(validityToken: String) async -> RecentUsageSnapshot? {
        let snapshot: RecentUsageSnapshot?
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
            guard let size = attributes[.size] as? NSNumber, size.intValue <= Self.maximumBytes else { return nil }
            let file = try FileHandle(forReadingFrom: fileURL)
            defer { try? file.close() }
            let data = try file.read(upToCount: Self.maximumBytes + 1) ?? Data()
            guard data.count <= Self.maximumBytes else { return nil }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == 1, envelope.validityToken == validityToken,
                  envelope.snapshot.isValid else { return nil }
            snapshot = envelope.snapshot
        } catch {
            return nil
        }
        await hooks.afterRead?()
        return snapshot
    }

    func save(_ snapshot: RecentUsageSnapshot, validityToken: String, operation: UInt64) throws {
        guard operation > greatestOperation else { return }
        greatestOperation = operation
        do {
            guard snapshot.isValid else { throw StoreError.invalidSnapshot }
            let data = try JSONEncoder().encode(Envelope(version: 1, snapshot: snapshot, validityToken: validityToken))
            guard data.count <= Self.maximumBytes else { throw StoreError.oversized }
            try hooks.beforeWrite?()
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            // Atomic writes create a sibling temporary file, so protect the directory first.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            Log.error("Recent usage cache save failed")
            throw error
        }
    }

    func remove(operation: UInt64) throws {
        guard operation > greatestOperation else { return }
        // A failed deletion must still retire all older writes.
        greatestOperation = operation
        do {
            try hooks.beforeRemove?()
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            Log.error("Recent usage cache removal failed")
            throw error
        }
    }
}
