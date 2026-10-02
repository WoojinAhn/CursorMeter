import XCTest
@testable import CursorMeter

final class CycleUsageStoreTests: XCTestCase, @unchecked Sendable {
    let now = Date(timeIntervalSince1970: 2000)
    func snapshot(account: String = String(repeating: "a", count: 64)) -> CycleAmountSnapshot {
        .init(identity: .init(localID: 1, credentialGeneration: 1, accountDigest: account, scopeDigest: "scope", cycle: .init(start: Date(timeIntervalSince1970: 1000), end: Date(timeIntervalSince1970: 3000)), planIdentity: "pro:100"), capturedAt: now, cursorCents: 10, coverage: .init(complete: true), status: .estimatedAttribution, estimatedCursorLimitCents: 100)
    }
    private func activate(_ store: CycleUsageStore, snapshot: CycleAmountSnapshot,
                          subject: String?, epoch: UInt64) async throws -> UInt64 {
        let acknowledged = await store.prepareAuthority(epoch: epoch, subjectDigest: subject)
        XCTAssertTrue(acknowledged)
        let operation = await store.activate(identity: snapshot.identity, authority: epoch)
        return try XCTUnwrap(operation)
    }

    func testMemoryStoreLabelsCacheAndRejectsStaleOperation() async throws {
        let store = CycleUsageStore()
        let sample = snapshot()
        let operation = try await activate(store, snapshot: sample, subject: nil, epoch: 1)
        try await store.save(sample, operation: operation)
        let cached = await store.load(operation: operation, now: now)
        XCTAssertEqual(cached?.isCached, true)
        try await store.invalidate(authority: 2)
        try await store.save(sample, operation: operation)
        let invalid = await store.load(operation: operation, now: now)
        XCTAssertNil(invalid)
    }

    func testOptionalDayDetailSurvivesSnapshotCoding() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot())) as? [String: Any])
        object["todayUsage"] = [
            "day": ["start": Date(timeIntervalSince1970: -32_400).timeIntervalSinceReferenceDate,
                    "end": Date(timeIntervalSince1970: 54_000).timeIntervalSinceReferenceDate],
            "evidenceAt": now.timeIntervalSinceReferenceDate,
            "cursorCents": 2.5, "otherCents": 0, "sourceIncludedTotalCents": 10
        ]
        let decoded = try JSONDecoder().decode(CycleAmountSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        XCTAssertNotNil(encoded["todayUsage"], "Valid optional day evidence must survive coding")
        XCTAssertEqual(decoded.cursorCents, 10)
    }

    func testMissingAndMalformedOptionalDayDetailPreserveParentAmounts() throws {
        let parent = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot())) as? [String: Any])
        for detail: Any? in [nil, NSNull(), "invalid", 123, [], ["cursorCents": 2]] {
            var object = parent
            object["todayUsage"] = detail
            let decoded = try JSONDecoder().decode(CycleAmountSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(decoded.cursorCents, 10)
            XCTAssertEqual(decoded.status, .estimatedAttribution)
            XCTAssertNil(decoded.todayUsage)
        }
    }

    func testInvalidBoundedDayDetailIsDiscardedDuringDecoding() throws {
        var sample = snapshot()
        sample.todayUsage = validDayDetail()
        let parent = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sample)) as? [String: Any])
        let validDetail = try XCTUnwrap(parent["todayUsage"] as? [String: Any])
        let changes: [(String, Any)] = [
            ("cursorCents", -1), ("cursorCents", 11), ("otherCents", 1),
            ("sourceIncludedTotalCents", -1), ("evidenceAt", now.addingTimeInterval(86_400).timeIntervalSinceReferenceDate),
            ("day", ["start": now.timeIntervalSinceReferenceDate, "end": now.addingTimeInterval(86_400).timeIntervalSinceReferenceDate]),
            ("day", ["start": now.timeIntervalSinceReferenceDate, "end": now.timeIntervalSinceReferenceDate])
        ]
        for (key, value) in changes {
            var object = parent
            var detail = validDetail
            detail[key] = value
            object["todayUsage"] = detail
            let decoded = try JSONDecoder().decode(CycleAmountSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(decoded.cursorCents, 10)
            XCTAssertNil(decoded.todayUsage, key)
        }
    }

    func testOptionalDayDetailPersistsInVersionOneAndRestoresOnlyAsCache() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var sample = snapshot()
        sample.todayUsage = validDayDetail()
        let writer = CycleUsageStore(fileURL: url)
        let operation = try await activate(writer, snapshot: sample, subject: sample.identity.accountDigest, epoch: 1)
        try await writer.save(sample, operation: operation)
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(envelope["version"] as? Int, 1)
        let reader = CycleUsageStore(fileURL: url)
        let reading = try await activate(reader, snapshot: sample, subject: sample.identity.accountDigest, epoch: 1)
        let restored = await reader.load(operation: reading, now: now)
        XCTAssertEqual(restored?.todayUsage, sample.todayUsage)
        XCTAssertEqual(restored?.isCached, true)
    }

    func testInvalidOptionalDayDetailDoesNotRejectMemoryOrDiskAmounts() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        var sample = snapshot()
        sample.todayUsage = validDayDetail()
        sample.todayUsage?.cursorCents = 11
        let writer = CycleUsageStore(fileURL: url)
        let operation = try await activate(writer, snapshot: sample, subject: sample.identity.accountDigest, epoch: 1)
        try await writer.save(sample, operation: operation)
        let memory = await writer.load(operation: operation, now: now)
        XCTAssertEqual(memory?.cursorCents, 10)
        XCTAssertNil(memory?.todayUsage)
        var envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var parent = try XCTUnwrap(envelope["snapshot"] as? [String: Any])
        parent["todayUsage"] = ["day": "bad"]
        envelope["snapshot"] = parent
        try JSONSerialization.data(withJSONObject: envelope).write(to: url)
        let reader = CycleUsageStore(fileURL: url)
        let reading = try await activate(reader, snapshot: sample, subject: sample.identity.accountDigest, epoch: 1)
        let disk = await reader.load(operation: reading, now: now)
        XCTAssertEqual(disk?.cursorCents, 10)
        XCTAssertNil(disk?.todayUsage)
    }

    private func validDayDetail() -> TodayUsageAggregate {
        .init(day: TodayUsageDay(containing: now)!, evidenceAt: now, cursorCents: 2.5, sourceIncludedTotalCents: 10)
    }
    func testOutdatedClassifierCacheIsRejectedAndReplaced() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("amounts.json")
        var outdated = snapshot()
        outdated.classifierVersion = CycleModelClassifier.version - 1
        outdated.unknownCents = 123
        outdated.unknownCount = 2
        let store = CycleUsageStore(fileURL: url)
        let operation = try await activate(store, snapshot: outdated, subject: outdated.identity.accountDigest, epoch: 1)
        try await store.save(outdated, operation: operation)
        let memoryCache = await store.load(operation: operation, now: now)
        XCTAssertNil(memoryCache)

        let reader = CycleUsageStore(fileURL: url)
        let reload = try await activate(reader, snapshot: outdated, subject: outdated.identity.accountDigest, epoch: 1)
        let diskCache = await reader.load(operation: reload, now: now)
        XCTAssertNil(diskCache)

        var current = snapshot()
        current.otherCents = 123
        try await reader.save(current, operation: reload)
        let replacement = await reader.load(operation: reload, now: now)
        XCTAssertEqual(replacement?.otherCents, 123)
        XCTAssertEqual(replacement?.unknownCount, 0)
        XCTAssertEqual(replacement?.classifierVersion, CycleModelClassifier.version)
    }
    func testAtomicStoreIdentityAgePermissionsAndAggregateOnly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("amounts.json")
        let sample = snapshot()
        let store = CycleUsageStore(fileURL: url)
        let operation = try await activate(store, snapshot: sample, subject: sample.identity.accountDigest, epoch: 1)
        try await store.save(sample, operation: operation)
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("usageEventsDisplay")); XCTAssertFalse(raw.contains("chargedCents"))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let other = CycleUsageStore(fileURL: url)
        let different = snapshot(account: String(repeating: "b", count: 64))
        let wrong = try await activate(other, snapshot: different, subject: different.identity.accountDigest, epoch: 1)
        let mismatch = await other.load(operation: wrong, now: now)
        XCTAssertNil(mismatch)
        let match = try await activate(other, snapshot: sample, subject: sample.identity.accountDigest, epoch: 2)
        let restored = await other.load(operation: match, now: now)
        XCTAssertTrue(restored?.isCached == true)
        let expired = await other.load(operation: match, now: now.addingTimeInterval(86_401))
        XCTAssertNil(expired)
        try await other.invalidate(authority: 3, removePersisted: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testEmailOnlyIdentityNeverCreatesFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = CycleUsageStore(fileURL: url)
        let sample = snapshot()
        let op = try await activate(store, snapshot: sample, subject: nil, epoch: 1)
        try await store.save(sample, operation: op)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testOversizedAndCorruptCacheIgnored() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CycleUsageStore(fileURL: url), sample = snapshot()
        let op = try await activate(store, snapshot: sample, subject: sample.identity.accountDigest, epoch: 1)
        try Data(repeating: 32, count: 1024 * 1024 + 1).write(to: url)
        let oversized = await store.load(operation: op, now: now)
        XCTAssertNil(oversized)
        try Data("bad".utf8).write(to: url)
        let corrupt = await store.load(operation: op, now: now)
        XCTAssertNil(corrupt)
    }
    func testLogoutRemovesOnlyTheActiveAccountsFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CycleUsageStore(fileURL: url), a = snapshot()
        let op = try await activate(store, snapshot: a, subject: a.identity.accountDigest, epoch: 1)
        try await store.save(a, operation: op)
        let b = snapshot(account: String(repeating: "b", count: 64))
        _ = try await activate(store, snapshot: b, subject: b.identity.accountDigest, epoch: 2)
        try await store.invalidate(authority: 3, removePersisted: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testVerifiedLogoutAfterSuspensionDeletesCacheAndRejectsOldLease() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CycleUsageStore(fileURL: url), sample = snapshot()
        let operation = try await activate(store, snapshot: sample, subject: sample.identity.accountDigest, epoch: 1)
        try await store.save(sample, operation: operation)
        try await store.invalidate(authority: 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try await store.invalidate(authority: 3, removePersisted: true, subjectDigest: sample.identity.accountDigest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try await store.save(sample, operation: operation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        let stale = await store.load(operation: operation, now: now)
        XCTAssertNil(stale)
    }

    func testVerifiedLogoutBeforeActivationDeletesOnlyMatchingCache() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = CycleUsageStore(fileURL: url), sample = snapshot()
        let operation = try await activate(writer, snapshot: sample, subject: sample.identity.accountDigest, epoch: 1)
        try await writer.save(sample, operation: operation)
        let fresh = CycleUsageStore(fileURL: url)
        for (index, digest) in ([nil, "unverified", String(repeating: "b", count: 64)] as [String?]).enumerated() {
            try await fresh.invalidate(authority: UInt64(index + 1), removePersisted: true, subjectDigest: digest)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        try await fresh.invalidate(authority: 4, removePersisted: true, subjectDigest: sample.identity.accountDigest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testExplicitDifferentSubjectDoesNotFallBackToActiveSubject() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CycleUsageStore(fileURL: url), sample = snapshot()
        let operation = try await activate(store, snapshot: sample, subject: sample.identity.accountDigest, epoch: 1)
        try await store.save(sample, operation: operation)
        try await store.invalidate(authority: 2, removePersisted: true, subjectDigest: String(repeating: "b", count: 64))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testAuthorityFenceRejectsOldActivationLoadAndSaveThroughRecovery() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CycleUsageStore(fileURL: url), sample = snapshot()
        let original = try await activate(store, snapshot: sample, subject: sample.identity.accountDigest, epoch: 1)
        try await store.save(sample, operation: original)
        let originalFile = try Data(contentsOf: url)

        let downgraded = await store.prepareAuthority(epoch: 2, subjectDigest: nil)
        XCTAssertTrue(downgraded)
        let staleActivation = await store.activate(identity: sample.identity, authority: 1)
        XCTAssertNil(staleActivation)
        let staleLoad = await store.load(operation: original, now: now)
        XCTAssertNil(staleLoad)
        var changed = sample
        changed.cursorCents = 999
        try await store.save(changed, operation: original)
        XCTAssertEqual(try Data(contentsOf: url), originalFile)

        let memoryActivation = await store.activate(identity: sample.identity, authority: 2)
        let memoryOperation = try XCTUnwrap(memoryActivation)
        let unauthorizedRestore = await store.load(operation: memoryOperation, now: now)
        XCTAssertNil(unauthorizedRestore)
        try await store.save(changed, operation: memoryOperation)
        let memory = await store.load(operation: memoryOperation, now: now)
        XCTAssertEqual(memory?.cursorCents, 999)
        XCTAssertEqual(try Data(contentsOf: url), originalFile)

        let recovered = try await activate(store, snapshot: sample, subject: sample.identity.accountDigest, epoch: 3)
        let restored = await store.load(operation: recovered, now: now)
        XCTAssertEqual(restored?.cursorCents, sample.cursorCents)
        let retiredAuthority = await store.prepareAuthority(epoch: 1, subjectDigest: sample.identity.accountDigest)
        XCTAssertFalse(retiredAuthority)
        let retiredActivation = await store.activate(identity: sample.identity, authority: 2)
        XCTAssertNil(retiredActivation)
        try await store.invalidate(authority: 2, removePersisted: true, subjectDigest: sample.identity.accountDigest)
        try await store.save(changed, operation: original)
        try await store.save(changed, operation: memoryOperation)
        let retiredMemory = await store.load(operation: memoryOperation, now: now)
        XCTAssertNil(retiredMemory)
        XCTAssertEqual(try Data(contentsOf: url), originalFile)
        try await store.save(changed, operation: recovered)
        let current = await store.load(operation: recovered, now: now)
        XCTAssertEqual(current?.cursorCents, 999)
        XCTAssertNotEqual(try Data(contentsOf: url), originalFile)
    }

    func testNewerAuthorityRejectsInvalidationThatWasAlreadyWaiting() async throws {
        actor Gate {
            var continuation: CheckedContinuation<Void, Never>?
            var calls = 0
            func wait() async {
                calls += 1
                if calls == 2 { await withCheckedContinuation { continuation = $0 } }
            }
            func isWaiting() -> Bool { continuation != nil }
            func release() { continuation?.resume(); continuation = nil }
        }
        let gate = Gate()
        let store = CycleUsageStore(hooks: .init(beforeAuthorityChange: { await gate.wait() }))
        let sample = snapshot()
        _ = try await activate(store, snapshot: sample, subject: sample.identity.accountDigest, epoch: 1)
        let invalidation = Task { try await store.invalidate(authority: 2) }
        while !(await gate.isWaiting()) { await Task.yield() }
        let recovered = try await activate(store, snapshot: sample, subject: sample.identity.accountDigest, epoch: 3)
        try await store.save(sample, operation: recovered)
        await gate.release()
        try await invalidation.value
        let current = await store.load(operation: recovered, now: now)
        XCTAssertEqual(current?.cursorCents, sample.cursorCents)
    }

}
