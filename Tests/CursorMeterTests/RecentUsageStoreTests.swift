import XCTest
@testable import CursorMeter

final class RecentUsageStoreTests: XCTestCase {
    private func location() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("cache/snapshot.json")
    }

    private func snapshot(model: String? = "test-model", subject: String? = "subject@example.test") -> RecentUsageSnapshot {
        RecentUsageSnapshot(
            candidate: RecentUsageCandidate(entries: [RecentUsageEntry(
                date: Date(timeIntervalSince1970: 1_700_000_000), model: model, kind: .included,
                tokens: 123, chargedCents: 0.25
            )], cachedAt: Date(timeIntervalSince1970: 1_700_000_020)),
            binding: RecentUsageBinding(cookieHeader: "other=1; WorkosCursorSessionToken=secret-token", subject: subject, scope: .personal)!
        )
    }

    func testRoundTripPreservesTimestampAndOnlyOnePrivateFile() async throws {
        let url = try location()
        let store = RecentUsageStore(fileURL: url)
        let original = snapshot()
        try await store.save(original, validityToken: "current", operation: 1)
        let restored = await store.load(validityToken: "current")
        XCTAssertEqual(restored, original)
        let raw = try String(contentsOf: url, encoding: .utf8)
        for secret in ["secret-token", "subject@example.test", "WorkosCursorSessionToken"] {
            XCTAssertFalse(raw.contains(secret))
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["snapshot.json"])
        XCTAssertEqual(try permissions(url), 0o600)
        XCTAssertEqual(try permissions(url.deletingLastPathComponent()), 0o700)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.deletingLastPathComponent().path)
        try await store.save(snapshot(model: "replacement"), validityToken: "current", operation: 2)
        XCTAssertEqual(try permissions(url), 0o600)
        XCTAssertEqual(try permissions(url.deletingLastPathComponent()), 0o700)
        let wrongToken = await store.load(validityToken: "revoked")
        XCTAssertNil(wrongToken)
    }

    private func permissions(_ url: URL) throws -> Int {
        try XCTUnwrap(FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber).intValue
    }

    func testCredentialBindingUsesOnlyExactSessionCookieValue() throws {
        let first = try XCTUnwrap(RecentUsageBinding(cookieHeader: "a=1; WorkosCursorSessionToken=abc; b=2", subject: "subject", scope: .personal))
        let reordered = RecentUsageBinding(cookieHeader: "b=changed; WorkosCursorSessionToken=abc; a=2", subject: "subject", scope: .personal)
        XCTAssertEqual(first, reordered)
        XCTAssertEqual(first.credentialDigest, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertNotEqual(first.scopeDigest, RecentUsageBinding(cookieHeader: "WorkosCursorSessionToken=abc", subject: "subject", scope: .enterprise(teamID: 1, userID: 23))?.scopeDigest)
        XCTAssertNotEqual(
            RecentUsageBinding(cookieHeader: "WorkosCursorSessionToken=abc", subject: "subject", scope: .enterprise(teamID: 1, userID: 23))?.scopeDigest,
            RecentUsageBinding(cookieHeader: "WorkosCursorSessionToken=abc", subject: "subject", scope: .enterprise(teamID: 12, userID: 3))?.scopeDigest
        )
        XCTAssertNil(RecentUsageBinding(cookieHeader: "WorkosCursorSessionToken=abc", subject: "", scope: .personal)?.subjectDigest)
        for header in ["", "a=1", "workoscursorsessiontoken=abc", "WorkosCursorSessionToken=", "WorkosCursorSessionToken=abc; WorkosCursorSessionToken=abc", "WorkosCursorSessionToken; WorkosCursorSessionToken=abc"] {
            XCTAssertNil(RecentUsageBinding(cookieHeader: header, subject: "subject", scope: .personal), header)
        }
    }

    func testAuthCookieValueWhitespaceAndControlsCannotAliasValidCredential() {
        for value in [" abc", "abc ", " abc ", "\tabc", "abc\t", "ab\tc", "ab\nc", "ab\rc", "ab\u{0}c", "ab\u{7F}c", "ab\u{A0}c"] {
            XCTAssertNil(RecentUsageBinding(
                cookieHeader: "other=value; WorkosCursorSessionToken=\(value); another=value",
                subject: "subject", scope: .personal
            ), "Invalid auth cookie values must not authorize restoration")
        }
        let valid = RecentUsageBinding(cookieHeader: "WorkosCursorSessionToken=abc", subject: "subject", scope: .personal)
        let reordered = RecentUsageBinding(cookieHeader: "\tother=changed; \tWorkosCursorSessionToken=abc; another=value\t", subject: "subject", scope: .personal)
        XCTAssertNotNil(valid)
        XCTAssertEqual(valid, reordered, "Whitespace outside the auth cookie value must not change its binding")
    }

    func testRemovalBeforeOlderSaveCannotRecreateFile() async throws {
        let url = try location()
        let store = RecentUsageStore(fileURL: url)
        try await store.remove(operation: 2)
        try await store.save(snapshot(), validityToken: "current", operation: 1)
        let restored = await store.load(validityToken: "current")
        XCTAssertNil(restored)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testFailedRemovalStillRejectsOlderAndEqualOperations() async throws {
        let url = try location()
        let store = RecentUsageStore(fileURL: url, hooks: .init(beforeRemove: { throw CocoaError(.fileWriteNoPermission) }))
        do {
            try await store.remove(operation: 2)
            XCTFail("Removal should fail")
        } catch {}
        try await store.save(snapshot(), validityToken: "current", operation: 1)
        try await store.save(snapshot(), validityToken: "current", operation: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        try await store.save(snapshot(), validityToken: "current", operation: 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testNewSaveBeforeOlderRemovalSurvives() async throws {
        let store = RecentUsageStore(fileURL: try location())
        let expected = snapshot()
        try await store.save(expected, validityToken: "new", operation: 3)
        try await store.remove(operation: 2)
        try await store.save(snapshot(model: "obsolete"), validityToken: "old", operation: 1)
        let restored = await store.load(validityToken: "new")
        XCTAssertEqual(restored, expected)
    }

    func testWriteFailureDoesNotReplaceLastSuccessfulFile() async throws {
        let url = try location()
        let original = snapshot()
        try await RecentUsageStore(fileURL: url).save(original, validityToken: "current", operation: 1)
        let failing = RecentUsageStore(fileURL: url, hooks: .init(beforeWrite: { throw CocoaError(.fileWriteNoPermission) }))
        do {
            try await failing.save(snapshot(model: "replacement"), validityToken: "current", operation: 1)
            XCTFail("Write should fail")
        } catch {}
        let restored = await failing.load(validityToken: "current")
        XCTAssertEqual(restored, original)
    }

    func testCorruptUnsupportedOversizedAndInvalidPayloadsAreMisses() async throws {
        let url = try location()
        let store = RecentUsageStore(fileURL: url)
        try await store.save(snapshot(), validityToken: "current", operation: 1)
        let valid = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var invalidDocuments: [Data] = [Data("corrupt".utf8), Data(repeating: 32, count: 256 * 1024 + 1)]
        var version = valid
        version["version"] = 2
        invalidDocuments.append(try JSONSerialization.data(withJSONObject: version))
        for mutation in ["count", "date", "cachedAt", "tokens", "cents", "credential", "subject", "scope"] {
            var document = valid
            var saved = try XCTUnwrap(document["snapshot"] as? [String: Any])
            var candidate = try XCTUnwrap(saved["candidate"] as? [String: Any])
            var binding = try XCTUnwrap(saved["binding"] as? [String: Any])
            var entries = try XCTUnwrap(candidate["entries"] as? [[String: Any]])
            switch mutation {
            case "count": entries = Array(repeating: entries[0], count: 31)
            case "date": entries[0]["date"] = 1e100
            case "cachedAt": candidate["cachedAt"] = 1e100
            case "tokens": entries[0]["tokens"] = -1
            case "cents": entries[0]["chargedCents"] = -0.1
            case "credential": binding["credentialDigest"] = "not-a-digest"
            case "subject": binding["subjectDigest"] = String(repeating: "z", count: 64)
            default: binding["scopeDigest"] = String(repeating: "a", count: 63)
            }
            candidate["entries"] = entries
            saved["candidate"] = candidate
            saved["binding"] = binding
            document["snapshot"] = saved
            invalidDocuments.append(try JSONSerialization.data(withJSONObject: document))
        }
        for document in invalidDocuments {
            try document.write(to: url)
            let result = await store.load(validityToken: "current")
            XCTAssertNil(result)
        }
    }

    func testSaveRejectsOversizedAndNonfiniteData() async throws {
        let url = try location()
        let store = RecentUsageStore(fileURL: url)
        let binding = snapshot().binding
        let invalid = [
            snapshot(model: String(repeating: "x", count: 256 * 1024)),
            RecentUsageSnapshot(candidate: RecentUsageCandidate(entries: [], cachedAt: Date(timeIntervalSince1970: .infinity)), binding: binding),
            RecentUsageSnapshot(candidate: RecentUsageCandidate(entries: [RecentUsageEntry(date: Date(), model: nil, kind: .other, tokens: 1, chargedCents: .nan)], cachedAt: Date()), binding: binding),
        ]
        for (index, value) in invalid.enumerated() {
            do {
                try await store.save(value, validityToken: "current", operation: UInt64(index + 1))
                XCTFail("Invalid data must not be saved")
            } catch {}
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testEmptyCandidateAndUnknownAmountsRoundTrip() async throws {
        let store = RecentUsageStore(fileURL: try location())
        let binding = snapshot(subject: nil).binding
        let empty = RecentUsageSnapshot(candidate: RecentUsageCandidate(entries: [], cachedAt: Date(timeIntervalSince1970: 100)), binding: binding)
        try await store.save(empty, validityToken: "current", operation: 1)
        let restored = await store.load(validityToken: "current")
        XCTAssertEqual(restored, empty)
        let unknown = RecentUsageSnapshot(candidate: RecentUsageCandidate(entries: [RecentUsageEntry(date: Date(timeIntervalSince1970: 10), model: nil, kind: .other, tokens: nil, chargedCents: nil)], cachedAt: Date(timeIntervalSince1970: 100)), binding: binding)
        try await store.save(unknown, validityToken: "current", operation: 2)
        let restoredUnknown = await store.load(validityToken: "current")
        XCTAssertEqual(restoredUnknown, unknown)
    }
}
