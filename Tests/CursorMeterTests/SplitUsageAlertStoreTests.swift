import XCTest
@testable import CursorMeter

@MainActor
final class SplitUsageAlertStoreTests: XCTestCase {
    private var revision: UInt64 = 0

    private func prepare(_ store: SplitUsageAlertStore, subject: String?) async throws -> SplitUsageAlertStore.Authority {
        revision += 1
        let authority = await store.prepareProfileAuthority(freshSubjectDigest: subject, revision: revision)
        return try XCTUnwrap(authority)
    }

    private func activate(_ store: SplitUsageAlertStore, for owner: SplitAlertOwnership,
                          authority: SplitUsageAlertStore.Authority) async throws -> SplitUsageAlertStore.Lease {
        revision += 1
        let lease = await store.activate(for: owner, revision: revision, authority: authority)
        return try XCTUnwrap(lease)
    }

    private func load(_ store: SplitUsageAlertStore, for owner: SplitAlertOwnership, now: Date) async throws -> SplitUsageAlertStore.State {
        let authority = try await prepare(store, subject: owner.persistentSubjectDigest)
        let lease = try await activate(store, for: owner, authority: authority)
        return await store.load(for: owner, lease: lease, now: now)
    }

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
        let state = try await load(store, for: old, now: Date(timeIntervalSince1970: 2900000))
        let id = old.identity(scope: .cursor, level: "warning", value: 80, budget: nil)
        await store.recordSuccessful([id], ownership: old, lease: state.lease, now: Date(timeIntervalSince1970: 2900000))
        _ = try await load(store, for: owner(cycleEnd: 5600000), now: Date(timeIntervalSince1970: 3000000 + 8 * 86400))
        let restart = try await load(SplitUsageAlertStore(directory: directory), for: old, now: Date(timeIntervalSince1970: 3000000 + 8 * 86400))
        XCTAssertTrue(restart.identities.isEmpty)
    }

    func testOversizedStoreStaysUntouchedAndUsesSessionState() async throws {
        let directory = try directory()
        let owner = owner()
        let url = directory.appendingPathComponent(try XCTUnwrap(owner.persistenceKey) + ".json")
        let oversized = Data(repeating: 0x20, count: 1_048_577)
        try oversized.write(to: url)
        let store = SplitUsageAlertStore(directory: directory)
        let state = try await load(store, for: owner, now: Date())
        XCTAssertTrue(state.identities.isEmpty)
        let id = owner.identity(scope: .cursor, level: "warning", value: 80, budget: nil)
        await store.recordSuccessful([id], ownership: owner, lease: state.lease, now: Date())
        let memory = try await load(store, for: owner, now: Date())
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
        let state = try await load(SplitUsageAlertStore(directory: directory), for: owner, now: Date())
        XCTAssertTrue(state.identities.isEmpty)
    }

    func testMissingCycleIsMemoryOnlyEvenWithVerifiedSubject() async throws {
        let directory = try directory()
        var owner = owner()
        owner.cycleStart = nil
        let store = SplitUsageAlertStore(directory: directory)
        let state = try await load(store, for: owner, now: Date())
        await store.recordSuccessful(["session-only"], ownership: owner, lease: state.lease, now: Date())
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testSuccessfulLedgerSurvivesRestartAndCurrentCycleDayEight() async throws {
        let directory = try directory()
        let owner = owner()
        let id = owner.identity(scope: .cursor, level: "critical", value: 90, budget: nil)
        let store = SplitUsageAlertStore(directory: directory)
        let state = try await load(store, for: owner, now: Date(timeIntervalSince1970: 1000000))
        await store.recordSuccessful([id], ownership: owner, lease: state.lease, now: Date(timeIntervalSince1970: 1000000))
        let restarted = SplitUsageAlertStore(directory: directory)
        let loaded = try await load(restarted, for: owner, now: Date(timeIntervalSince1970: 1000000 + 8 * 86400))
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
        let state = try await load(store, for: owner, now: Date())
        await store.recordSuccessful(["session-id"], ownership: owner, lease: state.lease, now: Date())
        let sameSession = try await load(store, for: owner, now: Date())
        XCTAssertEqual(sameSession.identities, ["session-id"])
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        let restarted = try await load(SplitUsageAlertStore(directory: directory), for: owner, now: Date())
        XCTAssertTrue(restarted.identities.isEmpty)
    }

    func testLogoutDeletesVerifiedAccountLedgerWithoutLoadingIt() async throws {
        let directory = try directory()
        let owner = owner()
        let store = SplitUsageAlertStore(directory: directory)
        let state = try await load(store, for: owner, now: Date())
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
        let state = try await load(store, for: owner, now: Date())
        await store.logout(accountDigest: owner.accountDigest)
        await store.recordSuccessful(["stale"], ownership: owner, lease: state.lease, now: Date())
        let loaded = try await load(store, for: owner, now: Date())
        XCTAssertTrue(loaded.identities.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testOldCyclePrunedOnlyAfterSevenDayGrace() async throws {
        let directory = try directory()
        let store = SplitUsageAlertStore(directory: directory)
        let old = owner(cycleEnd: 3000000)
        let current = owner(cycleEnd: 5600000)
        let state = try await load(store, for: old, now: Date(timeIntervalSince1970: 2900000))
        let id = old.identity(scope: .cursor, level: "warning", value: 80, budget: nil)
        await store.recordSuccessful([id], ownership: old, lease: state.lease, now: Date(timeIntervalSince1970: 2900000))
        _ = try await load(store, for: current, now: Date(timeIntervalSince1970: 3000000 + 6 * 86400))
        let before = try await load(store, for: old, now: Date(timeIntervalSince1970: 3000000 + 6 * 86400))
        XCTAssertEqual(before.identities, [id])
        _ = try await load(store, for: current, now: Date(timeIntervalSince1970: 3000000 + 8 * 86400))
        let after = try await load(SplitUsageAlertStore(directory: directory), for: old,
                                   now: Date(timeIntervalSince1970: 3000000 + 8 * 86400))
        XCTAssertTrue(after.identities.isEmpty)
    }

    func testRetiredAuthorityCannotActivateLoadOrAppendToDisk() async throws {
        let directory = try directory()
        let owner = owner()
        let now = Date(timeIntervalSince1970: 2900000)
        let persistedID = owner.identity(scope: .cursor, level: "warning", value: 80, budget: nil)
        let receiptID = owner.identity(scope: .other, level: "warning", value: 80, budget: nil)
        let writer = SplitUsageAlertStore(directory: directory)
        let written = try await load(writer, for: owner, now: now)
        await writer.recordSuccessful([persistedID], ownership: owner, lease: written.lease, now: now)
        let url = directory.appendingPathComponent(try XCTUnwrap(owner.persistenceKey) + ".json")
        let original = try Data(contentsOf: url)

        let store = SplitUsageAlertStore(directory: directory)
        let fresh = try await prepare(store, subject: owner.persistentSubjectDigest)
        let staleRevision = revision
        let oldLease = try await activate(store, for: owner, authority: fresh)
        let lifecycle = revision
        _ = try await prepare(store, subject: nil)

        let stalePrepare = await store.prepareProfileAuthority(freshSubjectDigest: owner.persistentSubjectDigest,
                                                               revision: staleRevision)
        let staleActivation = await store.activate(for: owner, revision: revision + 1, authority: fresh)
        XCTAssertNil(stalePrepare)
        XCTAssertNil(staleActivation)
        let beforeReceipt = await store.load(for: owner, lease: oldLease, now: now)
        XCTAssertTrue(beforeReceipt.identities.isEmpty, "Retired load must not read the existing ledger")
        await store.recordSuccessful([receiptID], ownership: owner, lease: oldLease, now: now)
        let afterReceipt = await store.load(for: owner, lease: oldLease, now: now)
        XCTAssertEqual(afterReceipt.identities, [receiptID])
        XCTAssertEqual(try Data(contentsOf: url), original)

        let recovery = try await prepare(store, subject: owner.persistentSubjectDigest)
        let recoveredLease = await store.activate(for: owner, revision: lifecycle, authority: recovery)
        let recovered = await store.load(for: owner, lease: try XCTUnwrap(recoveredLease), now: now)
        XCTAssertEqual(recovered.identities, [persistedID, receiptID])
        XCTAssertEqual(try Data(contentsOf: url), original, "Suppression union is not a new delivery")
        await store.recordSuccessful([receiptID], ownership: owner, lease: oldLease, now: now)
        XCTAssertEqual(try Data(contentsOf: url), original, "Recovery must not revive an old writer")
    }

    func testLoadedKnowledgeAndLateReceiptsSurviveDowngradeWithoutDiskIO() async throws {
        let directory = try directory()
        let owner = owner()
        let now = Date(timeIntervalSince1970: 2900000)
        let loadedID = owner.identity(scope: .cursor, level: "warning", value: 80, budget: nil)
        let lateID = owner.identity(scope: .other, level: "warning", value: 80, budget: nil)
        let newID = owner.identity(scope: .included, level: "warning", value: 80, budget: nil)
        let writer = SplitUsageAlertStore(directory: directory)
        let initial = try await load(writer, for: owner, now: now)
        await writer.recordSuccessful([loadedID], ownership: owner, lease: initial.lease, now: now)

        let store = SplitUsageAlertStore(directory: directory)
        let state = try await load(store, for: owner, now: now)
        let lifecycle = revision
        XCTAssertEqual(state.identities, [loadedID])
        let url = directory.appendingPathComponent(try XCTUnwrap(owner.persistenceKey) + ".json")
        let original = try Data(contentsOf: url)
        let degraded = try await prepare(store, subject: nil)
        var degradedOwner = owner
        degradedOwner.persistentSubjectDigest = nil
        let degradedLease = await store.activate(for: degradedOwner, revision: lifecycle, authority: degraded)
        try Data("unreadable-during-downgrade".utf8).write(to: url)
        await store.recordSuccessful([lateID], ownership: owner, lease: state.lease, now: now)
        let memory = await store.load(for: degradedOwner, lease: try XCTUnwrap(degradedLease), now: now)
        XCTAssertEqual(memory.identities, [loadedID, lateID])
        XCTAssertEqual(try Data(contentsOf: url), Data("unreadable-during-downgrade".utf8))

        try original.write(to: url)
        let recovery = try await prepare(store, subject: owner.persistentSubjectDigest)
        let recoveredLease = await store.activate(for: owner, revision: lifecycle, authority: recovery)
        let recovered = await store.load(for: owner, lease: try XCTUnwrap(recoveredLease), now: now)
        XCTAssertEqual(recovered.identities, [loadedID, lateID])
        XCTAssertEqual(try Data(contentsOf: url), original)
        await store.recordSuccessful([newID], ownership: owner, lease: recovered.lease, now: now)
        let restarted = try await load(SplitUsageAlertStore(directory: directory), for: owner, now: now)
        XCTAssertEqual(restarted.identities, [loadedID, newID], "Session-only receipt must never be promoted to disk")
    }

    func testLifecycleChangeRejectsLateReceiptEvenWithCurrentAuthority() async throws {
        for change in ["account", "scope", "cycle", "generation", "logout"] {
            let store = SplitUsageAlertStore(directory: try directory())
            let old = owner()
            let now = Date(timeIntervalSince1970: 2900000)
            let state = try await load(store, for: old, now: now)
            if change == "logout" {
                await store.logout(accountDigest: old.accountDigest)
            } else {
                var next = old
                switch change {
                case "account": next.accountDigest = "other-account"
                case "scope": next.requestPlanScope = "team"
                case "cycle": next.cycleEnd = next.cycleEnd?.addingTimeInterval(86400)
                default: next.generation += 1
                }
                _ = try await load(store, for: next, now: now)
            }
            await store.recordSuccessful(["late-receipt"], ownership: old, lease: state.lease, now: now)
            let stale = await store.load(for: old, lease: state.lease, now: now)
            XCTAssertTrue(stale.identities.isEmpty, change)
            let returned = try await load(store, for: old, now: now)
            XCTAssertTrue(returned.identities.isEmpty, change)
        }
    }

    func testRepresentationResetRetainsLoadedAndAcknowledgedIDsButRejectsLateReceipt() async throws {
        let directory = try directory()
        let owner = owner()
        let now = Date(timeIntervalSince1970: 2900000)
        let loadedID = owner.identity(scope: .cursor, level: "warning", value: 80, budget: nil)
        let acknowledgedID = owner.identity(scope: .other, level: "warning", value: 80, budget: nil)
        let lateID = owner.identity(scope: .included, level: "warning", value: 80, budget: nil)
        let writer = SplitUsageAlertStore(directory: directory)
        let written = try await load(writer, for: owner, now: now)
        await writer.recordSuccessful([loadedID], ownership: owner, lease: written.lease, now: now)

        let store = SplitUsageAlertStore(directory: directory)
        let loaded = try await load(store, for: owner, now: now)
        XCTAssertEqual(loaded.identities, [loadedID])
        _ = try await prepare(store, subject: nil)
        await store.recordSuccessful([acknowledgedID], ownership: owner, lease: loaded.lease, now: now)
        let acknowledged = await store.load(for: owner, lease: loaded.lease, now: now)
        XCTAssertEqual(acknowledged.identities, [loadedID, acknowledgedID])
        let url = directory.appendingPathComponent(try XCTUnwrap(owner.persistenceKey) + ".json")
        let original = try Data(contentsOf: url)

        revision += 1
        await store.invalidate(lifecycle: revision, authorityRevision: revision)
        var degradedOwner = owner
        degradedOwner.persistentSubjectDigest = nil
        let restored = try await load(store, for: degradedOwner, now: now)
        XCTAssertEqual(restored.identities, [loadedID, acknowledgedID])
        await store.recordSuccessful([lateID], ownership: owner, lease: loaded.lease, now: now)
        let afterLateReceipt = await store.load(for: degradedOwner, lease: restored.lease, now: now)
        XCTAssertEqual(afterLateReceipt.identities, [loadedID, acknowledgedID])
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
}
