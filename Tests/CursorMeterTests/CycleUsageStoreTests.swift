import XCTest
@testable import CursorMeter

final class CycleUsageStoreTests: XCTestCase, @unchecked Sendable {
    let now = Date(timeIntervalSince1970: 2000)
    func snapshot(account: String = String(repeating: "a", count: 64)) -> CycleAmountSnapshot {
        .init(identity: .init(localID: 1, credentialGeneration: 1, accountDigest: account, scopeDigest: "scope", cycle: .init(start: Date(timeIntervalSince1970: 1000), end: Date(timeIntervalSince1970: 3000)), planIdentity: "pro:100"), capturedAt: now, cursorCents: 10, coverage: .init(complete: true), status: .estimatedAttribution, estimatedCursorLimitCents: 100)
    }
    func testMemoryStoreLabelsCacheAndRejectsStaleOperation() async throws {
        let store = CycleUsageStore()
        let sample = snapshot()
        let operation = await store.activate(identity: sample.identity, subjectDigest: nil)
        try await store.save(sample, operation: operation)
        let cached = await store.load(operation: operation, now: now)
        XCTAssertEqual(cached?.isCached, true)
        try await store.invalidate()
        try await store.save(sample, operation: operation)
        let invalid = await store.load(operation: operation, now: now)
        XCTAssertNil(invalid)
    }
    func testAtomicStoreIdentityAgePermissionsAndAggregateOnly() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("amounts.json")
        let sample = snapshot()
        let store = CycleUsageStore(fileURL: url)
        let operation = await store.activate(identity: sample.identity, subjectDigest: sample.identity.accountDigest)
        try await store.save(sample, operation: operation)
        let raw = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(raw.contains("usageEventsDisplay")); XCTAssertFalse(raw.contains("chargedCents"))
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let other = CycleUsageStore(fileURL: url)
        let different = snapshot(account: String(repeating: "b", count: 64))
        let wrong = await other.activate(identity: different.identity, subjectDigest: different.identity.accountDigest)
        let mismatch = await other.load(operation: wrong, now: now)
        XCTAssertNil(mismatch)
        let match = await other.activate(identity: sample.identity, subjectDigest: sample.identity.accountDigest)
        let restored = await other.load(operation: match, now: now)
        XCTAssertTrue(restored?.isCached == true)
        let expired = await other.load(operation: match, now: now.addingTimeInterval(86_401))
        XCTAssertNil(expired)
        try await other.invalidate(removePersisted: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testEmailOnlyIdentityNeverCreatesFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = CycleUsageStore(fileURL: url)
        let sample = snapshot()
        let op = await store.activate(identity: sample.identity, subjectDigest: nil)
        try await store.save(sample, operation: op)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testOversizedAndCorruptCacheIgnored() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CycleUsageStore(fileURL: url), sample = snapshot()
        let op = await store.activate(identity: sample.identity, subjectDigest: sample.identity.accountDigest)
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
        let op = await store.activate(identity: a.identity, subjectDigest: a.identity.accountDigest)
        try await store.save(a, operation: op)
        let b = snapshot(account: String(repeating: "b", count: 64))
        _ = await store.activate(identity: b.identity, subjectDigest: b.identity.accountDigest)
        try await store.invalidate(removePersisted: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testVerifiedLogoutAfterSuspensionDeletesCacheAndRejectsOldLease() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CycleUsageStore(fileURL: url), sample = snapshot()
        let operation = await store.activate(identity: sample.identity, subjectDigest: sample.identity.accountDigest)
        try await store.save(sample, operation: operation)
        try await store.invalidate()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        try await store.invalidate(removePersisted: true, subjectDigest: sample.identity.accountDigest)
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
        let operation = await writer.activate(identity: sample.identity, subjectDigest: sample.identity.accountDigest)
        try await writer.save(sample, operation: operation)
        let fresh = CycleUsageStore(fileURL: url)
        for digest in [nil, "unverified", String(repeating: "b", count: 64)] as [String?] {
            try await fresh.invalidate(removePersisted: true, subjectDigest: digest)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
        try await fresh.invalidate(removePersisted: true, subjectDigest: sample.identity.accountDigest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testExplicitDifferentSubjectDoesNotFallBackToActiveSubject() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let store = CycleUsageStore(fileURL: url), sample = snapshot()
        let operation = await store.activate(identity: sample.identity, subjectDigest: sample.identity.accountDigest)
        try await store.save(sample, operation: operation)
        try await store.invalidate(removePersisted: true, subjectDigest: String(repeating: "b", count: 64))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

}
