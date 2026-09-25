import Darwin
import Foundation

actor CycleUsageStore {
    private struct Envelope: Codable { let version: Int; let subjectDigest: String; let snapshot: CycleAmountSnapshot }
    private let fileURL: URL?
    private var generation: UInt64 = 0
    private var identity: UsageRevisionIdentity?
    private var persistentSubject: String?
    private var memory: CycleAmountSnapshot?
    private let maximumBytes = 1024 * 1024

    init(fileURL: URL? = nil) { self.fileURL = fileURL }

    @discardableResult
    func activate(identity: UsageRevisionIdentity, subjectDigest: String?) -> UInt64 {
        generation &+= 1
        self.identity = identity
        memory = nil
        persistentSubject = subjectDigest.flatMap { digest in
            digest == identity.accountDigest && Self.validSubjectDigest(digest) ? digest : nil
        }
        return generation
    }

    func load(operation: UInt64, now: Date = Date()) -> CycleAmountSnapshot? {
        guard operation == generation, let identity else { return nil }
        var candidate = memory
        if candidate == nil, let persistentSubject, let envelope = readEnvelope(), envelope.subjectDigest == persistentSubject {
            candidate = envelope.snapshot
        }
        guard var snapshot = candidate, Self.valid(snapshot), snapshot.identity.sameScope(as: identity),
              let cycle = identity.cycle, cycle.start <= now, now < cycle.end,
              now.timeIntervalSince(snapshot.capturedAt) >= 0, now.timeIntervalSince(snapshot.capturedAt) <= 86400 else { return nil }
        snapshot.isCached = true
        if snapshot.classifierVersion != CycleModelClassifier.version {
            snapshot.estimatedCursorLimitCents = nil; snapshot.estimatedOtherLimitCents = nil
            snapshot.status = .unavailable
        }
        return snapshot
    }

    func save(_ snapshot: CycleAmountSnapshot, operation: UInt64) throws {
        guard operation == generation, snapshot.identity == identity, Self.valid(snapshot) else { return }
        memory = snapshot
        guard let fileURL, let persistentSubject, snapshot.identity.cycle != nil else { return }
        let data = try JSONEncoder().encode(Envelope(version: 1, subjectDigest: persistentSubject, snapshot: snapshot))
        guard data.count <= maximumBytes else { return }
        let manager = FileManager.default
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = fileURL.deletingLastPathComponent().appendingPathComponent(".cycle-\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? manager.removeItem(at: temporary) }
        // rename replaces atomically while retaining the already-private mode.
        guard rename(temporary.path, fileURL.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    func invalidate(removePersisted: Bool = false, subjectDigest: String? = nil) throws {
        generation &+= 1
        identity = nil; memory = nil
        let account = subjectDigest ?? persistentSubject
        persistentSubject = nil
        if removePersisted, let account, Self.validSubjectDigest(account), readEnvelope()?.subjectDigest == account,
           let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }

    private static func validSubjectDigest(_ digest: String) -> Bool {
        digest.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func readEnvelope() -> Envelope? {
        guard let fileURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes,
              let handle = try? FileHandle(forReadingFrom: fileURL) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maximumBytes + 1), data.count <= maximumBytes,
              let envelope = try? JSONDecoder().decode(Envelope.self, from: data), envelope.version == 1 else { return nil }
        return envelope
    }

    private static func valid(_ value: CycleAmountSnapshot) -> Bool {
        let money = [value.cursorCents, value.otherCents, value.botCents, value.paidCents, value.unknownCents]
        let limits = [value.estimatedCursorLimitCents, value.estimatedOtherLimitCents].compactMap { $0 }
        guard (money + limits).allSatisfy({ !$0.isNaN && $0 >= 0 }),
              value.residualCents?.isNaN != true, value.unknownCount >= 0,
              value.coverage.pageCount >= 0, value.coverage.pageCount <= 100,
              value.coverage.eventCount >= 0, value.coverage.eventCount <= 10000,
              value.coverage.byteCount >= 0, value.coverage.byteCount <= 16 * 1024 * 1024,
              value.capturedAt.timeIntervalSince1970.isFinite,
              value.coverage.oldest?.timeIntervalSince1970.isFinite != false,
              value.coverage.newest?.timeIntervalSince1970.isFinite != false,
              value.cursorObservedPlaces >= 0, value.cursorObservedPlaces <= 3,
              value.otherObservedPlaces >= 0, value.otherObservedPlaces <= 3,
              value.sourceCursorPercent.map({ SplitUsageSnapshot.validPercent($0) != nil }) != false,
              value.sourceOtherPercent.map({ SplitUsageSnapshot.validPercent($0) != nil }) != false,
              let cycle = value.identity.cycle, UsageCycle(start: cycle.start, end: cycle.end) != nil else { return false }
        return true
    }
}
