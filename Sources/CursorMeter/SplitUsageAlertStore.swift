import Foundation

/// Lifecycle leases reject obsolete receipts; authority epochs independently fence
/// disk access while preserving successful same-owner receipts in session memory.
actor SplitUsageAlertStore {
    struct Authority: Sendable, Equatable {
        fileprivate var epoch: UInt64
    }
    struct Lease: Sendable {
        fileprivate var lifecycle: UInt64
        fileprivate var authority: Authority
    }
    struct State: Sendable {
        var identities: Set<String>
        var lease: Lease
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
    private var authorityRevision: UInt64 = 0
    private var authorityEpoch: UInt64 = 0
    private var freshSubjectDigest: String?
    private var lifecycleRevision: UInt64 = 0
    private var ownership: SplitAlertOwnership?
    private var accountFiles: [String: Set<String>] = [:]
    private var memoryOnly: Set<String> = []

    init(directory: URL? = nil) { self.directory = directory }

    static var applicationDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CursorMeter/SplitAlerts", isDirectory: true)
    }

    func prepareProfileAuthority(freshSubjectDigest: String?, revision: UInt64) -> Authority? {
        guard revision > authorityRevision else { return nil }
        if authorityRevision == 0 || self.freshSubjectDigest != freshSubjectDigest {
            authorityEpoch &+= 1
        }
        authorityRevision = revision
        self.freshSubjectDigest = freshSubjectDigest
        return Authority(epoch: authorityEpoch)
    }

    func activate(for ownership: SplitAlertOwnership, revision: UInt64, authority: Authority) -> Lease? {
        guard authority.epoch == authorityEpoch, authorityRevision > 0,
              revision >= lifecycleRevision else { return nil }
        if revision == lifecycleRevision {
            guard let current = self.ownership, sameLifecycle(current, ownership) else { return nil }
        }
        lifecycleRevision = revision
        self.ownership = ownership
        return Lease(lifecycle: revision, authority: authority)
    }

    func invalidate(lifecycle: UInt64, authorityRevision: UInt64) {
        if lifecycle > lifecycleRevision {
            lifecycleRevision = lifecycle
            ownership = nil
        }
        if authorityRevision > self.authorityRevision {
            self.authorityRevision = authorityRevision
            authorityEpoch &+= 1
            freshSubjectDigest = nil
        }
    }

    func load(for ownership: SplitAlertOwnership, lease: Lease, now: Date) -> State {
        guard isCurrent(ownership, lease: lease) else { return State(identities: [], lease: lease) }
        let sessionKey = sessionKey(ownership)
        guard canPersist(ownership, lease: lease), let key = ownership.persistenceKey,
              let cycle = ownership.cycleKey, directory != nil else {
            return State(identities: session[sessionKey, default: []], lease: lease)
        }
        accountFiles[ownership.accountDigest, default: []].insert(key)
        if records[key] == nil { records[key] = read(key) }
        let previousCount = records[key]?.count
        records[key]?.removeAll { $0.cycle != cycle && now.timeIntervalSince($0.cycleEnd) > 7 * 86400 }
        if previousCount != records[key]?.count { write(key) }
        let persisted = records[key, default: []].filter { $0.cycle == cycle }.map(\.identity)
        session[sessionKey, default: []].formUnion(persisted)
        return State(identities: session[sessionKey, default: []], lease: lease)
    }

    func recordSuccessful(_ identities: Set<String>, ownership: SplitAlertOwnership, lease: Lease, now: Date) {
        guard isCurrent(ownership, lease: lease), !identities.isEmpty else { return }
        session[sessionKey(ownership), default: []].formUnion(identities)
        guard canPersist(ownership, lease: lease), let key = ownership.persistenceKey,
              let cycle = ownership.cycleKey, let end = ownership.cycleEnd, directory != nil else { return }
        _ = load(for: ownership, lease: lease, now: now)
        let existing = Set(records[key, default: []].map(\.identity))
        records[key, default: []].append(contentsOf: identities.subtracting(existing).map {
            Record(identity: $0, cycle: cycle, cycleEnd: end)
        })
        write(key)
    }

    func logout(accountDigest: String, persistentSubjectDigest: String? = nil) {
        if ownership?.accountDigest == accountDigest {
            lifecycleRevision &+= 1
            ownership = nil
            authorityEpoch &+= 1
            freshSubjectDigest = nil
        }
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

    private func sameLifecycle(_ lhs: SplitAlertOwnership, _ rhs: SplitAlertOwnership) -> Bool {
        lhs.hasSameSignalScope(as: rhs) && lhs.generation == rhs.generation
    }

    private func isCurrent(_ ownership: SplitAlertOwnership, lease: Lease) -> Bool {
        lease.lifecycle == lifecycleRevision
            && self.ownership.map { sameLifecycle($0, ownership) } == true
    }

    private func canPersist(_ ownership: SplitAlertOwnership, lease: Lease) -> Bool {
        lease.authority.epoch == authorityEpoch && freshSubjectDigest != nil
            && ownership.persistentSubjectDigest == freshSubjectDigest
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
