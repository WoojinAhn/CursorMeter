import CoreFoundation
import XCTest
@testable import CursorMeter

private actor RecentUsageReadGate {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var arrivalContinuation: CheckedContinuation<Void, Never>?
    private var arrived = false

    func suspend() async {
        arrived = true
        arrivalContinuation?.resume()
        arrivalContinuation = nil
        await withCheckedContinuation { releaseContinuation = $0 }
    }

    func waitForArrival() async {
        if !arrived { await withCheckedContinuation { arrivalContinuation = $0 } }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private final class RecentUsageTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

private final class RecentUsageWriteGate: @unchecked Sendable {
    let arrival: XCTestExpectation
    private let semaphore = DispatchSemaphore(value: 0)

    init(arrival: XCTestExpectation) { self.arrival = arrival }

    func suspend() throws {
        arrival.fulfill()
        guard semaphore.wait(timeout: .now() + 5) == .success else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    func release() { semaphore.signal() }
}

@MainActor
private final class RecentUsageTestValidity {
    var token: String? = UUID().uuidString
    var reads = 0
    var commits: [String] = []
    var failCommit = false

    var persistence: RecentUsageValidityPersistence {
        RecentUsageValidityPersistence(read: {
            self.reads += 1
            return self.token
        }, commit: { value in
            self.commits.append(value)
            guard !self.failCommit else { return false }
            self.token = value
            return true
        })
    }
}

@MainActor
final class RecentUsageControllerTests: XCTestCase {
    private func location() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("cache/snapshot.json")
    }

    private func cookie(_ value: String = "original") -> String { "WorkosCursorSessionToken=\(value)" }

    private func saved(credential: String = "original", subject: String? = "subject", scope: RecentUsageRequestScope = .personal, time: TimeInterval = 100) -> RecentUsageSnapshot {
        RecentUsageSnapshot(candidate: candidate(time: time), binding: RecentUsageBinding(cookieHeader: cookie(credential), subject: subject, scope: scope)!)
    }

    private func candidate(time: TimeInterval = 200) -> RecentUsageCandidate {
        RecentUsageCandidate(entries: [RecentUsageEntry(date: Date(timeIntervalSince1970: time - 1), model: "test-model", kind: .included, tokens: 100, chargedCents: 0.5)], cachedAt: Date(timeIntervalSince1970: time))
    }

    private func seed(_ snapshot: RecentUsageSnapshot, at url: URL, validity: RecentUsageTestValidity) async throws {
        try await RecentUsageStore(fileURL: url).save(snapshot, validityToken: validity.token!, operation: 1)
    }

    private func eventually(file: StaticString = #filePath, line: UInt = #line, _ condition: @MainActor () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        repeat {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        } while ContinuousClock.now < deadline
        XCTFail("Condition was not reached", file: file, line: line)
    }

    func testNoStorePerformsNoPreferencesIOAndFreshMemoryWorks() throws {
        let validity = RecentUsageTestValidity()
        let controller = RecentUsageController(validityPersistence: validity.persistence)
        controller.beginSession(generation: 1)
        let context = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie(), generation: 1, attemptID: 1))
        XCTAssertTrue(controller.validateIdentity(subject: nil, scope: .personal, context: context))
        XCTAssertTrue(controller.publish(candidate: candidate(), context: context))
        XCTAssertEqual(controller.snapshot?.candidate, candidate())
        XCTAssertEqual(controller.status, .current)
        controller.invalidate(generation: 2, revokePersisted: true)
        XCTAssertEqual(validity.reads, 0)
        XCTAssertTrue(validity.commits.isEmpty)
    }

    func testRestoreOnlyStartsAfterActualCredentialSelection() async throws {
        let url = try location()
        let validity = RecentUsageTestValidity()
        let expected = saved()
        try await seed(expected, at: url, validity: validity)
        let controller = RecentUsageController(store: RecentUsageStore(fileURL: url), validityPersistence: validity.persistence)
        controller.beginSession(generation: 1)
        XCTAssertNil(controller.snapshot)
        XCTAssertEqual(validity.reads, 0)
        _ = controller.selectCredential(cookieHeader: cookie(), generation: 1, attemptID: 1)
        await eventually { controller.snapshot == expected }
        XCTAssertEqual(controller.status, .cached)
        XCTAssertEqual(controller.snapshot?.candidate.cachedAt, Date(timeIntervalSince1970: 100))
    }

    func testRotatedCredentialStaysPrivateUntilSubjectAndScopeMatch() async throws {
        let url = try location()
        let validity = RecentUsageTestValidity()
        let expected = saved(scope: .enterprise(teamID: 1, userID: 2))
        try await seed(expected, at: url, validity: validity)
        let gate = RecentUsageReadGate()
        let controller = RecentUsageController(store: RecentUsageStore(fileURL: url, hooks: .init(afterRead: { await gate.suspend() })), validityPersistence: validity.persistence)
        controller.beginSession(generation: 1)
        let context = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie("rotated"), generation: 1, attemptID: 1))
        await gate.waitForArrival()
        await gate.release()
        await Task.yield()
        XCTAssertNil(controller.snapshot)
        controller.recordFailure(context: context)
        XCTAssertEqual(controller.status, .failed)
        XCTAssertTrue(controller.validateIdentity(subject: "subject", scope: nil, context: context))
        XCTAssertNil(controller.snapshot)
        XCTAssertTrue(controller.validateIdentity(subject: "subject", scope: .enterprise(teamID: 1, userID: 2), context: context))
        await eventually { controller.snapshot == expected }
        XCTAssertEqual(controller.snapshot?.binding, expected.binding)
        XCTAssertEqual(controller.snapshot?.candidate.cachedAt, expected.candidate.cachedAt)
        let onDisk = await RecentUsageStore(fileURL: url).load(validityToken: validity.token!)
        XCTAssertEqual(onDisk, expected)
        _ = controller.selectCredential(cookieHeader: cookie("rotated"), generation: 1, attemptID: 2)
        XCTAssertEqual(controller.snapshot, expected, "Validated in-memory reuse must not require rewriting the original binding")
    }

    func testNilSubjectCannotPromoteRotatedCredential() async throws {
        for storedSubject: String? in [nil, "subject"] {
            let url = try location()
            let validity = RecentUsageTestValidity()
            try await seed(saved(subject: storedSubject), at: url, validity: validity)
            let gate = RecentUsageReadGate()
            let controller = RecentUsageController(store: RecentUsageStore(fileURL: url, hooks: .init(afterRead: { await gate.suspend() })), validityPersistence: validity.persistence)
            controller.beginSession(generation: 1)
            let context = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie("rotated"), generation: 1, attemptID: 1))
            await gate.waitForArrival()
            await gate.release()
            _ = controller.validateIdentity(subject: nil, scope: .personal, context: context)
            await Task.yield()
            XCTAssertNil(controller.snapshot)
            XCTAssertTrue(controller.publish(candidate: candidate(), context: context))
            XCTAssertEqual(controller.snapshot?.candidate, candidate())
        }
    }

    func testEstablishedDifferentAccountOrTeamRevokesSavedCache() async throws {
        for (subject, scope) in [("different", RecentUsageRequestScope.personal), ("subject", .enterprise(teamID: 99, userID: 2))] {
            let url = try location()
            let validity = RecentUsageTestValidity()
            let oldToken = validity.token!
            try await seed(saved(), at: url, validity: validity)
            let controller = RecentUsageController(store: RecentUsageStore(fileURL: url), validityPersistence: validity.persistence)
            controller.beginSession(generation: 1)
            let context = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie(), generation: 1, attemptID: 1))
            await eventually { controller.snapshot != nil }
            XCTAssertTrue(controller.validateIdentity(subject: subject, scope: scope, context: context))
            XCTAssertNil(controller.snapshot)
            XCTAssertNotEqual(validity.token, oldToken)
            XCTAssertTrue(controller.publish(candidate: candidate(), context: context), "Authenticated new identity may publish fresh data")
            XCTAssertEqual(controller.snapshot?.binding, RecentUsageBinding(cookieHeader: cookie(), subject: subject, scope: scope))
        }
    }

    func testReconnectClearsVisibleDataAndRequiresCredentialRevalidationWithoutRevocation() async throws {
        let url = try location()
        let validity = RecentUsageTestValidity()
        let expected = saved()
        try await seed(expected, at: url, validity: validity)
        let controller = RecentUsageController(store: RecentUsageStore(fileURL: url), validityPersistence: validity.persistence)
        controller.beginSession(generation: 1)
        let old = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie(), generation: 1, attemptID: 1))
        await eventually { controller.snapshot == expected }
        let token = validity.token
        controller.beginSession(generation: 2)
        XCTAssertNil(controller.snapshot)
        XCTAssertFalse(controller.publish(candidate: candidate(), context: old))
        XCTAssertEqual(validity.token, token)
        _ = controller.selectCredential(cookieHeader: cookie(), generation: 2, attemptID: 2)
        await eventually { controller.snapshot == expected }
    }

    func testLateHeldLoadCannotReplaceFreshNetworkSnapshot() async throws {
        let url = try location()
        let validity = RecentUsageTestValidity()
        try await seed(saved(), at: url, validity: validity)
        let gate = RecentUsageReadGate()
        let controller = RecentUsageController(store: RecentUsageStore(fileURL: url, hooks: .init(afterRead: { await gate.suspend() })), validityPersistence: validity.persistence)
        controller.beginSession(generation: 1)
        let context = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie("rotated"), generation: 1, attemptID: 1))
        await gate.waitForArrival()
        _ = controller.validateIdentity(subject: "subject", scope: .personal, context: context)
        XCTAssertTrue(controller.publish(candidate: candidate(), context: context))
        await gate.release()
        await Task.yield()
        XCTAssertEqual(controller.snapshot?.candidate, candidate())
        XCTAssertEqual(controller.status, .current)
        controller.recordFailure(context: context)
        XCTAssertEqual(controller.status, .current, "A later failure from another consumer cannot overwrite recent success")
    }

    func testSameAttemptIDEFallbackRejectsLateOldCredentialLoad() async throws {
        let url = try location()
        let validity = RecentUsageTestValidity()
        try await seed(saved(credential: "ide"), at: url, validity: validity)
        let gate = RecentUsageReadGate()
        let controller = RecentUsageController(store: RecentUsageStore(fileURL: url, hooks: .init(afterRead: { await gate.suspend() })), validityPersistence: validity.persistence)
        controller.beginSession(generation: 1)
        let ide = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie("ide"), generation: 1, attemptID: 42))
        await gate.waitForArrival()
        controller.rejectCredential(context: ide)
        let fallback = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie("fallback"), generation: 1, attemptID: 42))
        XCTAssertNotEqual(ide, fallback)
        XCTAssertFalse(controller.validateIdentity(subject: "subject", scope: .personal, context: ide))
        await gate.release()
        await Task.yield()
        XCTAssertNil(controller.snapshot)
        XCTAssertEqual(controller.status, .idle)
        _ = controller.validateIdentity(subject: "new-subject", scope: .personal, context: fallback)
        XCTAssertTrue(controller.publish(candidate: candidate(), context: fallback))
    }

    func testUnrelatedIDERejectionPreservesKnownBrowserCacheForOfflineFallback() async throws {
        let url = try location()
        let validity = RecentUsageTestValidity()
        let originalToken = validity.token
        let expected = saved(credential: "browser")
        try await seed(expected, at: url, validity: validity)
        let controller = RecentUsageController(store: RecentUsageStore(fileURL: url), validityPersistence: validity.persistence)
        controller.beginSession(generation: 1)
        _ = controller.selectCredential(cookieHeader: cookie("browser"), generation: 1, attemptID: 1)
        await eventually { controller.snapshot == expected }

        let ide = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie("ide"), generation: 1, attemptID: 2))
        XCTAssertNil(controller.snapshot)
        controller.rejectCredential(context: ide)
        XCTAssertNil(controller.snapshot)
        XCTAssertEqual(validity.token, originalToken)
        XCTAssertTrue(validity.commits.isEmpty)
        XCTAssertFalse(controller.validateIdentity(subject: "subject", scope: .personal, context: ide))

        let fallback = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie("browser"), generation: 1, attemptID: 2))
        controller.recordFailure(context: fallback)
        XCTAssertEqual(controller.snapshot, expected)
        XCTAssertEqual(controller.snapshot?.candidate.cachedAt, expected.candidate.cachedAt)
        XCTAssertEqual(controller.status, .failed)
        let onDisk = await RecentUsageStore(fileURL: url).load(validityToken: originalToken!)
        XCTAssertEqual(onDisk, expected)
    }

    func testRejectedIDESaveCannotSurviveWhenBrowserSaveIsPendingOrSkipped() async throws {
        for rejectDuringWrite in [true, false] {
            let url = try location()
            let validity = RecentUsageTestValidity()
            let originalToken = validity.token!
            let gate = RecentUsageWriteGate(arrival: expectation(description: "IDE save started"))
            defer { gate.release() }
            let writes = RecentUsageTestCounter()
            let browserWrite = expectation(description: "Retired browser publication must not be saved")
            browserWrite.isInverted = true
            let store = RecentUsageStore(fileURL: url, hooks: .init(beforeWrite: {
                if writes.increment() == 1 { try gate.suspend() } else { browserWrite.fulfill() }
            }, beforeRemove: { throw CocoaError(.fileWriteNoPermission) }))
            let controller = RecentUsageController(store: store, validityPersistence: validity.persistence)
            controller.beginSession(generation: 1)
            let initialIDE = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie("ide"), generation: 1, attemptID: 1))
            _ = controller.validateIdentity(subject: "subject", scope: .personal, context: initialIDE)
            XCTAssertTrue(controller.publish(candidate: candidate(time: 100), context: initialIDE))
            await fulfillment(of: [gate.arrival], timeout: 1)

            let browser = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie("browser"), generation: 1, attemptID: 2))
            _ = controller.validateIdentity(subject: "subject", scope: .personal, context: browser)
            XCTAssertTrue(controller.publish(candidate: candidate(time: 200), context: browser))
            let expected = try XCTUnwrap(controller.snapshot)
            let rejectedIDE = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie("ide"), generation: 1, attemptID: 3))
            let probe = RecentUsageStore(fileURL: url)
            if !rejectDuringWrite {
                gate.release()
                await controller.testHook_waitForPersistence()
                await eventually { await probe.load(validityToken: originalToken) == self.saved(credential: "ide") }
                await fulfillment(of: [browserWrite], timeout: 0.05)
            }

            controller.rejectCredential(context: rejectedIDE)
            XCTAssertNotEqual(validity.token, originalToken)
            XCTAssertEqual(validity.commits.count, 1)
            let fallback = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie("browser"), generation: 1, attemptID: 3))
            controller.recordFailure(context: fallback)
            XCTAssertEqual(controller.snapshot, expected)
            XCTAssertEqual(controller.snapshot?.candidate.cachedAt, Date(timeIntervalSince1970: 200))
            XCTAssertEqual(controller.status, .failed)
            if rejectDuringWrite {
                gate.release()
                await controller.testHook_waitForPersistence()
                await eventually { await probe.load(validityToken: originalToken) == self.saved(credential: "ide") }
                await fulfillment(of: [browserWrite], timeout: 0.05)
            }

            let rejectedRestore = expectation(description: "Rejected IDE file must not restore on restart")
            rejectedRestore.isInverted = true
            let restarted = RecentUsageController(store: RecentUsageStore(fileURL: url, hooks: .init(afterRead: {
                rejectedRestore.fulfill()
            })), validityPersistence: validity.persistence)
            restarted.beginSession(generation: 1)
            _ = restarted.selectCredential(cookieHeader: cookie("ide"), generation: 1, attemptID: 1)
            await fulfillment(of: [rejectedRestore], timeout: 0.05)
            XCTAssertNil(restarted.snapshot)
        }
    }

    func testCompletedBrowserSaveSurvivesUnrelatedIDERejection() async throws {
        let url = try location()
        let validity = RecentUsageTestValidity()
        let originalToken = validity.token!
        let controller = RecentUsageController(store: RecentUsageStore(fileURL: url), validityPersistence: validity.persistence)
        controller.beginSession(generation: 1)
        let browser = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie("browser"), generation: 1, attemptID: 1))
        _ = controller.validateIdentity(subject: "subject", scope: .personal, context: browser)
        XCTAssertTrue(controller.publish(candidate: candidate(), context: browser))
        let expected = try XCTUnwrap(controller.snapshot)
        let probe = RecentUsageStore(fileURL: url)
        await controller.testHook_waitForPersistence()
        let persisted = await probe.load(validityToken: originalToken)
        XCTAssertEqual(persisted, expected)

        let rejectedIDE = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie("ide"), generation: 1, attemptID: 2))
        controller.rejectCredential(context: rejectedIDE)
        XCTAssertEqual(validity.token, originalToken)
        XCTAssertTrue(validity.commits.isEmpty)
        let fallback = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie("browser"), generation: 1, attemptID: 2))
        controller.recordFailure(context: fallback)
        XCTAssertEqual(controller.snapshot, expected)
        let onDisk = await probe.load(validityToken: originalToken)
        XCTAssertEqual(onDisk, expected)
    }

    func testRejectedExactOrIdentityEligibleCredentialRevokesKnownCache() async throws {
        for rejectedCredential in ["original", "rotated"] {
            let url = try location()
            let validity = RecentUsageTestValidity()
            let originalToken = validity.token
            let expected = saved()
            try await seed(expected, at: url, validity: validity)
            let controller = RecentUsageController(store: RecentUsageStore(fileURL: url), validityPersistence: validity.persistence)
            controller.beginSession(generation: 1)
            _ = controller.selectCredential(cookieHeader: cookie(), generation: 1, attemptID: 1)
            await eventually { controller.snapshot == expected }
            let rejected = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie(rejectedCredential), generation: 1, attemptID: 2))
            _ = controller.validateIdentity(subject: "subject", scope: .personal, context: rejected)
            XCTAssertEqual(controller.snapshot, expected)

            controller.rejectCredential(context: rejected)
            XCTAssertNil(controller.snapshot)
            XCTAssertNotEqual(validity.token, originalToken)
            XCTAssertEqual(validity.commits.count, 1)
            XCTAssertFalse(controller.publish(candidate: candidate(), context: rejected))
            let onDisk = await RecentUsageStore(fileURL: url).load(validityToken: validity.token!)
            XCTAssertNil(onDisk)
        }
    }

    func testCredentialSelectionWithoutRejectionAlsoInvalidatesOldLoad() async throws {
        let url = try location()
        let validity = RecentUsageTestValidity()
        try await seed(saved(credential: "ide"), at: url, validity: validity)
        let gate = RecentUsageReadGate()
        let controller = RecentUsageController(store: RecentUsageStore(fileURL: url, hooks: .init(afterRead: { await gate.suspend() })), validityPersistence: validity.persistence)
        controller.beginSession(generation: 1)
        let first = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie("ide"), generation: 1, attemptID: 1))
        await gate.waitForArrival()
        let second = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie("rotated"), generation: 1, attemptID: 1))
        _ = controller.validateIdentity(subject: "subject", scope: .personal, context: second)
        XCTAssertTrue(controller.publish(candidate: candidate(), context: second))
        await gate.release()
        await Task.yield()
        XCTAssertFalse(controller.publish(candidate: candidate(time: 300), context: first))
        XCTAssertEqual(controller.snapshot?.candidate, candidate())
    }

    func testFailureRetainsEligibleRowsAndOriginalTime() async throws {
        let url = try location()
        let validity = RecentUsageTestValidity()
        let expected = saved()
        try await seed(expected, at: url, validity: validity)
        let controller = RecentUsageController(store: RecentUsageStore(fileURL: url), validityPersistence: validity.persistence)
        controller.beginSession(generation: 1)
        let context = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie(), generation: 1, attemptID: 1))
        await eventually { controller.snapshot == expected }
        controller.recordFailure(context: context)
        XCTAssertEqual(controller.snapshot, expected)
        XCTAssertEqual(controller.status, .failed)
    }

    func testRevocationCommitsBeforeQueuedDeleteAndFailedDeleteCannotRestoreOnRestart() async throws {
        let url = try location()
        let validity = RecentUsageTestValidity()
        let oldToken = validity.token!
        try await seed(saved(), at: url, validity: validity)
        let failingStore = RecentUsageStore(fileURL: url, hooks: .init(beforeRemove: { throw CocoaError(.fileWriteNoPermission) }))
        let controller = RecentUsageController(store: failingStore, validityPersistence: validity.persistence)
        controller.beginSession(generation: 1)
        _ = controller.selectCredential(cookieHeader: cookie(), generation: 1, attemptID: 1)
        await eventually { controller.snapshot != nil }
        controller.invalidate(generation: 2, revokePersisted: true)
        XCTAssertNotEqual(validity.token, oldToken, "Revocation is durably acknowledged before invalidate returns")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Deletion has not run while MainActor remains synchronous")
        XCTAssertNil(controller.snapshot)
        XCTAssertEqual(controller.status, .idle)
        let restarted = RecentUsageController(store: RecentUsageStore(fileURL: url), validityPersistence: validity.persistence)
        restarted.beginSession(generation: 1)
        _ = restarted.selectCredential(cookieHeader: cookie(), generation: 1, attemptID: 1)
        let stale = await RecentUsageStore(fileURL: url).load(validityToken: validity.token!)
        XCTAssertNil(stale)
        await Task.yield()
        XCTAssertNil(restarted.snapshot)
    }

    func testRepeatedRevocationWithoutNewSaveDoesNotRepeatDurableOrDiskWrites() async throws {
        let url = try location()
        let validity = RecentUsageTestValidity()
        let originalToken = validity.token
        try await seed(saved(), at: url, validity: validity)
        let removals = RecentUsageTestCounter()
        let repeatedRemoval = expectation(description: "An already revoked cache must not be removed again")
        repeatedRemoval.isInverted = true
        let store = RecentUsageStore(fileURL: url, hooks: .init(beforeRemove: {
            if removals.increment() > 1 { repeatedRemoval.fulfill() }
        }))
        let controller = RecentUsageController(store: store, validityPersistence: validity.persistence)

        controller.invalidate(generation: 1, revokePersisted: true)
        XCTAssertNotEqual(validity.token, originalToken, "Initial disk contents are unknown and require revocation")
        XCTAssertEqual(validity.commits.count, 1)
        await eventually { removals.value == 1 && !FileManager.default.fileExists(atPath: url.path) }
        let revokedToken = validity.token

        controller.invalidate(generation: 2, revokePersisted: true)
        XCTAssertNil(controller.selectCredential(cookieHeader: "other=value", generation: 2, attemptID: 1))
        controller.invalidate(generation: 3, revokePersisted: true)
        XCTAssertEqual(validity.token, revokedToken)
        XCTAssertEqual(validity.commits.count, 1)
        await fulfillment(of: [repeatedRemoval], timeout: 0.05)
        XCTAssertEqual(removals.value, 1)
    }

    func testEnqueuedOrCompletedSaveAfterRevocationRequiresAnotherDurableRevocation() async throws {
        for completeSave in [false, true] {
            let url = try location()
            let validity = RecentUsageTestValidity()
            let removals = RecentUsageTestCounter()
            let repeatedRemoval = expectation(description: "Each possible saved snapshot needs only one removal")
            repeatedRemoval.isInverted = true
            let store = RecentUsageStore(fileURL: url, hooks: .init(beforeRemove: {
                if removals.increment() > 2 { repeatedRemoval.fulfill() }
            }))
            let controller = RecentUsageController(store: store, validityPersistence: validity.persistence)
            controller.invalidate(generation: 1, revokePersisted: true)
            await eventually { removals.value == 1 }
            let firstRevokedToken = validity.token
            let context = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie(), generation: 1, attemptID: 1))
            _ = controller.validateIdentity(subject: "subject", scope: .personal, context: context)
            XCTAssertTrue(controller.publish(candidate: candidate(), context: context))
            let probe = RecentUsageStore(fileURL: url)
            if completeSave {
                await eventually { await probe.load(validityToken: validity.token!) == controller.snapshot }
            }

            controller.invalidate(generation: 2, revokePersisted: true)
            XCTAssertNotEqual(validity.token, firstRevokedToken)
            XCTAssertEqual(validity.commits.count, 2, "Even an enqueued save must re-arm durable revocation")
            await eventually { removals.value == 2 && !FileManager.default.fileExists(atPath: url.path) }
            controller.invalidate(generation: 3, revokePersisted: true)
            XCTAssertEqual(validity.commits.count, 2)
            await fulfillment(of: [repeatedRemoval], timeout: 0.05)
            XCTAssertEqual(removals.value, 2)
        }
    }

    func testMissingValidityTokenCommitsBeforeRestoringAndDoesNotAdoptOldFile() async throws {
        let url = try location()
        let validity = RecentUsageTestValidity()
        try await seed(saved(), at: url, validity: validity)
        validity.token = nil
        let controller = RecentUsageController(store: RecentUsageStore(fileURL: url), validityPersistence: validity.persistence)
        controller.beginSession(generation: 1)
        _ = controller.selectCredential(cookieHeader: cookie(), generation: 1, attemptID: 1)
        XCTAssertNotNil(validity.token)
        XCTAssertEqual(validity.commits.count, 1)
        let old = await RecentUsageStore(fileURL: url).load(validityToken: validity.token!)
        XCTAssertNil(old)
        XCTAssertNil(controller.snapshot)
    }

    func testFailedTokenCommitDisablesDiskButKeepsFreshMemoryUsable() async throws {
        let url = try location()
        let validity = RecentUsageTestValidity()
        try await seed(saved(), at: url, validity: validity)
        validity.token = nil
        validity.failCommit = true
        let controller = RecentUsageController(store: RecentUsageStore(fileURL: url), validityPersistence: validity.persistence)
        controller.beginSession(generation: 1)
        let context = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie(), generation: 1, attemptID: 1))
        XCTAssertNil(controller.snapshot)
        _ = controller.validateIdentity(subject: "subject", scope: .personal, context: context)
        XCTAssertTrue(controller.publish(candidate: candidate(), context: context))
        await eventually { !FileManager.default.fileExists(atPath: url.path) }
        XCTAssertEqual(controller.snapshot?.candidate, candidate())
        XCTAssertEqual(controller.status, .current)
        validity.failCommit = false
        let next = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie(), generation: 1, attemptID: 2))
        _ = controller.validateIdentity(subject: "subject", scope: .personal, context: next)
        _ = controller.publish(candidate: candidate(time: 300), context: next)
        await Task.yield()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "A failed durable boundary disables persistence for this controller's lifetime")
        XCTAssertEqual(validity.commits.count, 1)
    }

    func testFailedRevocationCommitClearsCacheAndStillPermitsFreshMemory() async throws {
        let url = try location()
        let validity = RecentUsageTestValidity()
        try await seed(saved(), at: url, validity: validity)
        let controller = RecentUsageController(store: RecentUsageStore(fileURL: url), validityPersistence: validity.persistence)
        controller.beginSession(generation: 1)
        _ = controller.selectCredential(cookieHeader: cookie(), generation: 1, attemptID: 1)
        await eventually { controller.snapshot != nil }
        validity.failCommit = true
        controller.invalidate(generation: 2, revokePersisted: true)
        XCTAssertNil(controller.snapshot)
        let next = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie("new"), generation: 2, attemptID: 2))
        _ = controller.validateIdentity(subject: "new-subject", scope: .personal, context: next)
        XCTAssertTrue(controller.publish(candidate: candidate(), context: next))
        await eventually { !FileManager.default.fileExists(atPath: url.path) }
        XCTAssertEqual(controller.snapshot?.candidate, candidate())
    }

    func testFailedWriteRetainsFreshMemoryAndSuccessStatus() async throws {
        let url = try location()
        let validity = RecentUsageTestValidity()
        let controller = RecentUsageController(store: RecentUsageStore(fileURL: url, hooks: .init(beforeWrite: { throw CocoaError(.fileWriteNoPermission) })), validityPersistence: validity.persistence)
        controller.beginSession(generation: 1)
        let context = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie(), generation: 1, attemptID: 1))
        _ = controller.validateIdentity(subject: "subject", scope: .personal, context: context)
        _ = controller.publish(candidate: candidate(), context: context)
        await Task.yield()
        XCTAssertEqual(controller.snapshot?.candidate, candidate())
        XCTAssertEqual(controller.status, .current)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testQueuedSaveCannotSurviveImmediateInvalidationOrReplaceNextSession() async throws {
        let url = try location()
        let validity = RecentUsageTestValidity()
        let controller = RecentUsageController(store: RecentUsageStore(fileURL: url), validityPersistence: validity.persistence)
        controller.beginSession(generation: 1)
        let old = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie(), generation: 1, attemptID: 1))
        _ = controller.validateIdentity(subject: "subject", scope: .personal, context: old)
        _ = controller.publish(candidate: candidate(), context: old)
        controller.invalidate(generation: 2, revokePersisted: true)
        let next = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie("new"), generation: 2, attemptID: 2))
        _ = controller.validateIdentity(subject: "new-subject", scope: .personal, context: next)
        _ = controller.publish(candidate: candidate(time: 300), context: next)
        controller.recordFailure(context: old)
        XCTAssertEqual(controller.status, .current)
        let probe = RecentUsageStore(fileURL: url)
        await eventually { await probe.load(validityToken: validity.token!) == controller.snapshot }
        XCTAssertEqual(controller.snapshot?.candidate, candidate(time: 300))
    }

    func testMissingInvalidOrAmbiguousCredentialFailsAndRevokesVisibleCache() async throws {
        for invalidHeader in ["other=value", cookie(""), cookie("invalid token"), "\(cookie()); \(cookie("different"))"] {
            let url = try location()
            let validity = RecentUsageTestValidity()
            let originalToken = validity.token
            let expected = saved()
            try await seed(expected, at: url, validity: validity)
            let controller = RecentUsageController(store: RecentUsageStore(fileURL: url), validityPersistence: validity.persistence)
            controller.beginSession(generation: 1)
            let valid = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie(), generation: 1, attemptID: 1))
            await eventually { controller.snapshot == expected }

            XCTAssertNil(controller.selectCredential(cookieHeader: invalidHeader, generation: 1, attemptID: 2))
            XCTAssertNil(controller.snapshot)
            XCTAssertEqual(controller.status, .failed)
            XCTAssertNotEqual(validity.token, originalToken)
            XCTAssertEqual(validity.commits.count, 1)
            XCTAssertFalse(controller.publish(candidate: candidate(), context: valid))
            let onDisk = await RecentUsageStore(fileURL: url).load(validityToken: validity.token!)
            XCTAssertNil(onDisk)
        }
    }

    func testFreshPublicationRequiresResolvedAuthenticatedScope() throws {
        let controller = RecentUsageController()
        controller.beginSession(generation: 1)
        let context = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie(), generation: 1, attemptID: 1))
        XCTAssertFalse(controller.publish(candidate: candidate(), context: context))
        _ = controller.validateIdentity(subject: "subject", scope: nil, context: context)
        XCTAssertFalse(controller.publish(candidate: candidate(), context: context))
        _ = controller.validateIdentity(subject: "subject", scope: .personal, context: context)
        XCTAssertTrue(controller.publish(candidate: candidate(), context: context))
    }

    func testOlderAttemptCannotReplaceTheCurrentCredentialSelection() throws {
        let controller = RecentUsageController()
        controller.beginSession(generation: 1)
        let current = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie(), generation: 1, attemptID: 2))
        _ = controller.validateIdentity(subject: "subject", scope: .personal, context: current)
        _ = controller.publish(candidate: candidate(), context: current)
        XCTAssertNil(controller.selectCredential(cookieHeader: cookie("old"), generation: 1, attemptID: 1))
        XCTAssertEqual(controller.snapshot?.candidate, candidate())
        XCTAssertTrue(controller.validateIdentity(subject: "subject", scope: .personal, context: current))
        controller.rejectCredential(context: current)
        XCTAssertNil(controller.selectCredential(cookieHeader: cookie("old"), generation: 1, attemptID: 1))
        XCTAssertNotNil(controller.selectCredential(cookieHeader: cookie("fallback"), generation: 1, attemptID: 2))
    }

    func testIdentityResolvedBeforeLateCacheLoadRejectsOldScopeButAllowsFreshData() async throws {
        let url = try location()
        let validity = RecentUsageTestValidity()
        let token = validity.token
        try await seed(saved(), at: url, validity: validity)
        let gate = RecentUsageReadGate()
        let controller = RecentUsageController(store: RecentUsageStore(fileURL: url, hooks: .init(afterRead: { await gate.suspend() })), validityPersistence: validity.persistence)
        controller.beginSession(generation: 1)
        let context = try XCTUnwrap(controller.selectCredential(cookieHeader: cookie(), generation: 1, attemptID: 1))
        await gate.waitForArrival()
        let scope = RecentUsageRequestScope.enterprise(teamID: 7, userID: 8)
        _ = controller.validateIdentity(subject: "subject", scope: scope, context: context)
        await gate.release()
        await eventually { validity.token != token }
        XCTAssertNil(controller.snapshot)
        XCTAssertTrue(controller.publish(candidate: candidate(), context: context))
        XCTAssertEqual(controller.snapshot?.binding.scopeDigest, scope.digest)
    }

    func testFailedDurableRevocationDisablesRecreatedControllersForTheSameCacheFile() async throws {
        let url = try location()
        let validity = RecentUsageTestValidity()
        let original = saved()
        try await seed(original, at: url, validity: validity)
        let failedStore = RecentUsageStore(fileURL: url, hooks: .init(beforeRemove: { throw CocoaError(.fileWriteNoPermission) }))
        let first = RecentUsageController(store: failedStore, validityPersistence: validity.persistence)
        first.beginSession(generation: 1)
        _ = first.selectCredential(cookieHeader: cookie(), generation: 1, attemptID: 1)
        await eventually { first.snapshot != nil }
        validity.failCommit = true
        first.invalidate(generation: 2, revokePersisted: true)
        validity.failCommit = false

        let read = expectation(description: "Disabled cache must not be restored by a recreated controller")
        read.isInverted = true
        let write = expectation(description: "Disabled cache must not be saved by a recreated controller")
        write.isInverted = true
        let recreated = RecentUsageController(store: RecentUsageStore(fileURL: url, hooks: .init(
            afterRead: { read.fulfill() }, beforeWrite: { write.fulfill() }
        )), validityPersistence: validity.persistence)
        recreated.beginSession(generation: 1)
        let context = try XCTUnwrap(recreated.selectCredential(cookieHeader: cookie(), generation: 1, attemptID: 1))
        await fulfillment(of: [read], timeout: 0.05)
        XCTAssertNil(recreated.snapshot)
        _ = recreated.validateIdentity(subject: "subject", scope: .personal, context: context)
        XCTAssertTrue(recreated.publish(candidate: candidate(), context: context))
        await fulfillment(of: [write], timeout: 0.05)
        XCTAssertEqual(recreated.snapshot?.candidate, candidate())
        let disk = await RecentUsageStore(fileURL: url).load(validityToken: validity.token!)
        XCTAssertEqual(disk, original)

        let otherURL = try location()
        let otherValidity = RecentUsageTestValidity()
        let other = RecentUsageController(store: RecentUsageStore(fileURL: otherURL), validityPersistence: otherValidity.persistence)
        other.beginSession(generation: 1)
        let otherContext = try XCTUnwrap(other.selectCredential(cookieHeader: cookie(), generation: 1, attemptID: 1))
        _ = other.validateIdentity(subject: "subject", scope: .personal, context: otherContext)
        _ = other.publish(candidate: candidate(), context: otherContext)
        await eventually { FileManager.default.fileExists(atPath: otherURL.path) }
    }

    func testProductionValidityAdapterUsesExplicitIsolatedDomain() throws {
        let domain = "com.cursormeter.tests.\(UUID().uuidString)"
        let key = "cache-validity"
        defer {
            CFPreferencesSetAppValue(key as CFString, nil, domain as CFString)
            CFPreferencesAppSynchronize(domain as CFString)
        }
        let persistence = RecentUsageValidityPersistence.preferences(domain: domain, key: key)
        XCTAssertNil(persistence.read())
        let token = UUID().uuidString
        XCTAssertTrue(persistence.commit(token))
        XCTAssertEqual(persistence.read(), token)
    }
}
