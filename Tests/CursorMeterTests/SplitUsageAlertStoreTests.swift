import XCTest
@testable import CursorMeter

@MainActor
final class SplitUsageAlertStoreTests: XCTestCase {
    private func owner(subject: String? = "verified-subject", cycleEnd: TimeInterval = 3000000) -> SplitAlertOwnership {
        SplitAlertOwnership(accountDigest: "opaque-account", persistentSubjectDigest: subject,
            requestPlanScope: "personal-pro", cycleStart: Date(timeIntervalSince1970: cycleEnd - 2500000),
            cycleEnd: Date(timeIntervalSince1970: cycleEnd), generation: 1)
    }
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testPruningIsPersistedAcrossRestart() async throws {
        let directory = try directory()
        let store = SplitUsageAlertStore(directory: directory)
        let old = owner(cycleEnd: 3000000)
        let state = await store.load(for: old, now: Date(timeIntervalSince1970: 2900000))
        let id = old.identity(scope: .cursor, level: "warning", value: 80, budget: nil)
        await store.recordSuccessful([id], ownership: old, lease: state.lease, now: Date(timeIntervalSince1970: 2900000))
        _ = await store.load(for: owner(cycleEnd: 5600000), now: Date(timeIntervalSince1970: 3000000 + 8 * 86400))
        let restart = await SplitUsageAlertStore(directory: directory).load(for: old, now: Date(timeIntervalSince1970: 3000000 + 8 * 86400))
        XCTAssertTrue(restart.identities.isEmpty)
    }

    func testOversizedStoreStaysUntouchedAndUsesSessionState() async throws {
        let directory = try directory()
        let owner = owner()
        let url = directory.appendingPathComponent(try XCTUnwrap(owner.persistenceKey) + ".json")
        let oversized = Data(repeating: 0x20, count: 1_048_577)
        try oversized.write(to: url)
        let store = SplitUsageAlertStore(directory: directory)
        let state = await store.load(for: owner, now: Date())
        XCTAssertTrue(state.identities.isEmpty)
        let id = owner.identity(scope: .cursor, level: "warning", value: 80, budget: nil)
        await store.recordSuccessful([id], ownership: owner, lease: state.lease, now: Date())
        let memory = await store.load(for: owner, now: Date())
        XCTAssertEqual(memory.identities, [id])
        XCTAssertEqual(try Data(contentsOf: url).count, oversized.count)
    }

    func testRecordCountLimitIgnoresOversizedLedger() async throws {
        let directory = try directory()
        let owner = owner()
        let url = directory.appendingPathComponent(try XCTUnwrap(owner.persistenceKey) + ".json")
        let entries = (0..<4097).map { index in
            ["identity": SplitAlertOwnership.digest(String(index)), "cycle": owner.cycleKey!, "cycleEnd": 1.0] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "records": entries])
        XCTAssertLessThan(data.count, 1_048_576)
        try data.write(to: url)
        let state = await SplitUsageAlertStore(directory: directory).load(for: owner, now: Date())
        XCTAssertTrue(state.identities.isEmpty)
    }

    func testMissingCycleIsMemoryOnlyEvenWithVerifiedSubject() async throws {
        let directory = try directory()
        var owner = owner()
        owner.cycleStart = nil
        let store = SplitUsageAlertStore(directory: directory)
        let state = await store.load(for: owner, now: Date())
        await store.recordSuccessful(["session-only"], ownership: owner, lease: state.lease, now: Date())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testSuccessfulLedgerSurvivesRestartAndCurrentCycleDayEight() async throws {
        let directory = try directory()
        let owner = owner()
        let id = owner.identity(scope: .cursor, level: "critical", value: 90, budget: nil)
        let store = SplitUsageAlertStore(directory: directory)
        let state = await store.load(for: owner, now: Date(timeIntervalSince1970: 1000000))
        await store.recordSuccessful([id], ownership: owner, lease: state.lease, now: Date(timeIntervalSince1970: 1000000))
        let restarted = SplitUsageAlertStore(directory: directory)
        let loaded = await restarted.load(for: owner, now: Date(timeIntervalSince1970: 1000000 + 8 * 86400))
        XCTAssertEqual(loaded.identities, [id])
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: XCTUnwrap(files.first).path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let content = try String(contentsOf: XCTUnwrap(files.first), encoding: .utf8)
        XCTAssertFalse(content.contains("opaque-account"))
        XCTAssertFalse(content.contains("verified-subject"))
        XCTAssertFalse(content.contains("personal-pro"))
    }

    func testUnknownSubjectRemainsMemoryOnlyAndDoesNotLoadPrivateFile() async throws {
        let directory = try directory()
        let store = SplitUsageAlertStore(directory: directory)
        let owner = owner(subject: nil)
        let state = await store.load(for: owner, now: Date())
        await store.recordSuccessful(["session-id"], ownership: owner, lease: state.lease, now: Date())
        let sameSession = await store.load(for: owner, now: Date())
        XCTAssertEqual(sameSession.identities, ["session-id"])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        let restarted = await SplitUsageAlertStore(directory: directory).load(for: owner, now: Date())
        XCTAssertTrue(restarted.identities.isEmpty)
    }

    func testLogoutDeletesVerifiedAccountLedgerWithoutLoadingIt() async throws {
        let directory = try directory()
        let owner = owner()
        let store = SplitUsageAlertStore(directory: directory)
        let state = await store.load(for: owner, now: Date())
        let id = owner.identity(scope: .cursor, level: "warning", value: 80, budget: nil)
        await store.recordSuccessful([id], ownership: owner, lease: state.lease, now: Date())
        let restarted = SplitUsageAlertStore(directory: directory)
        await restarted.logout(accountDigest: owner.accountDigest, persistentSubjectDigest: owner.persistentSubjectDigest)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testLogoutInvalidatesOldLeaseAndPreventsResurrection() async throws {
        let directory = try directory()
        let store = SplitUsageAlertStore(directory: directory)
        let owner = owner()
        let state = await store.load(for: owner, now: Date())
        await store.logout(accountDigest: owner.accountDigest)
        await store.recordSuccessful(["stale"], ownership: owner, lease: state.lease, now: Date())
        let loaded = await store.load(for: owner, now: Date())
        XCTAssertTrue(loaded.identities.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testOldCyclePrunedOnlyAfterSevenDayGrace() async throws {
        let directory = try directory()
        let store = SplitUsageAlertStore(directory: directory)
        let old = owner(cycleEnd: 3000000)
        let current = owner(cycleEnd: 5600000)
        let state = await store.load(for: old, now: Date(timeIntervalSince1970: 2900000))
        let id = old.identity(scope: .cursor, level: "warning", value: 80, budget: nil)
        await store.recordSuccessful([id], ownership: old, lease: state.lease, now: Date(timeIntervalSince1970: 2900000))
        _ = await store.load(for: current, now: Date(timeIntervalSince1970: 3000000 + 6 * 86400))
        let before = await store.load(for: old, now: Date(timeIntervalSince1970: 3000000 + 6 * 86400))
        XCTAssertEqual(before.identities, [id])
        _ = await store.load(for: current, now: Date(timeIntervalSince1970: 3000000 + 8 * 86400))
        let after = await store.load(for: old, now: Date(timeIntervalSince1970: 3000000 + 8 * 86400))
        XCTAssertTrue(after.identities.isEmpty)
    }
}
