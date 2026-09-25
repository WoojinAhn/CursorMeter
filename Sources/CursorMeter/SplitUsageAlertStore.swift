import Foundation

/// Only successful threshold identities are persisted. Actor leases prevent an old
/// submission completion from recreating an account's ledger after logout.
actor SplitUsageAlertStore {
    struct State: Sendable {
        var identities: Set<String>
        var lease: UInt64
    }
    private struct Record: Codable {
        var identity: String
        var cycle: String
        var cycleEnd: Date
    }
    private struct Envelope: Codable {
        var version = 1
        var records: [Record]
    }
    static let maximumBytes = 1_048_576
    static let maximumRecords = 4096
    private let directory: URL?
    private var records: [String: [Record]] = [:]
    private var session: [String: Set<String>] = [:]
    private var epochs: [String: UInt64] = [:]
    private var accountFiles: [String: Set<String>] = [:]
    private var memoryOnly: Set<String> = []

    init(directory: URL? = nil) { self.directory = directory }

    static var applicationDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CursorMeter/SplitAlerts", isDirectory: true)
    }

    func load(for ownership: SplitAlertOwnership, now: Date) -> State {
        let lease = epochs[ownership.accountDigest, default: 0]
        guard let key = ownership.persistenceKey, let cycle = ownership.cycleKey, directory != nil else {
            return State(identities: session[sessionKey(ownership), default: []], lease: lease)
        }
        accountFiles[ownership.accountDigest, default: []].insert(key)
        if records[key] == nil { records[key] = read(key) }
        let previousCount = records[key]?.count
        records[key]?.removeAll { $0.cycle != cycle && now.timeIntervalSince($0.cycleEnd) > 7 * 86400 }
        if previousCount != records[key]?.count { write(key) }
        return State(identities: Set(records[key, default: []].map(\.identity)), lease: lease)
    }

    func recordSuccessful(_ identities: Set<String>, ownership: SplitAlertOwnership, lease: UInt64, now: Date) {
        guard lease == epochs[ownership.accountDigest, default: 0] else { return }
        guard let key = ownership.persistenceKey, let cycle = ownership.cycleKey,
              let end = ownership.cycleEnd, directory != nil else {
            session[sessionKey(ownership), default: []].formUnion(identities)
            return
        }
        _ = load(for: ownership, now: now)
        let existing = Set(records[key, default: []].map(\.identity))
        records[key, default: []].append(contentsOf: identities.subtracting(existing).map {
            Record(identity: $0, cycle: cycle, cycleEnd: end)
        })
        write(key)
    }

    func logout(accountDigest: String, persistentSubjectDigest: String? = nil) {
        epochs[accountDigest, default: 0] &+= 1
        session = session.filter { !$0.key.hasPrefix(accountDigest + ":") }
        var keys = accountFiles.removeValue(forKey: accountDigest) ?? []
        if let subject = persistentSubjectDigest, !subject.isEmpty {
            keys.insert(SplitAlertOwnership.digest("split-alert-subject:" + subject))
        }
        for key in keys {
            records.removeValue(forKey: key)
            memoryOnly.remove(key)
            if let url = file(key) { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func sessionKey(_ ownership: SplitAlertOwnership) -> String {
        ownership.accountDigest + ":" + SplitAlertOwnership.digest(ownership.requestPlanScope + ":" + (ownership.cycleKey ?? "session"))
    }

    private func file(_ key: String) -> URL? { directory?.appendingPathComponent(key + ".json") }

    private func read(_ key: String) -> [Record] {
        guard let url = file(key), FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= Self.maximumBytes else { memoryOnly.insert(key); return [] }
            let data = try Data(contentsOf: url)
            guard data.count <= Self.maximumBytes else { memoryOnly.insert(key); return [] }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard envelope.version == 1, envelope.records.count <= Self.maximumRecords,
                  envelope.records.allSatisfy({ record in
                      record.identity.count == 64 && record.identity.allSatisfy(\.isHexDigit)
                      && record.cycle.count == 64 && record.cycle.allSatisfy(\.isHexDigit)
                      && record.cycleEnd.timeIntervalSince1970.isFinite
                  }) else { memoryOnly.insert(key); return [] }
            return envelope.records
        } catch { memoryOnly.insert(key); return [] }
    }

    private func write(_ key: String) {
        guard !memoryOnly.contains(key), let directory, let url = file(key) else { return }
        let values = records[key, default: []]
        guard values.count <= Self.maximumRecords,
              let data = try? JSONEncoder().encode(Envelope(records: values)), data.count <= Self.maximumBytes else {
            memoryOnly.insert(key)
            return
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                  attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { memoryOnly.insert(key) }
    }
}
