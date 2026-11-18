import XCTest
@testable import CursorMeter

@MainActor
final class SharedActivityControllerTests: XCTestCase {
    private let owner = SharedUsageOwner(generation: 1, credentialDigest: "credential-a", subjectDigest: "subject-a")
    private let now = ISO8601DateFormatter().date(from: "2026-11-19T00:30:00Z")!

    func testReadsSucceedIndependentlyAndFailureRetainsOnlySameOwnerStaleData() async {
        let provider = SharedActivityFixture()
        let controller = SharedActivityController(provider: provider, now: { self.now })
        controller.bind(owner)
        let first = await controller.refresh(cookieHeader: "synthetic", owner: owner, isCurrent: { true })
        XCTAssertTrue(first)
        XCTAssertEqual(controller.recent.value?.entries.count, 1)
        XCTAssertEqual(controller.daily.value?.count, 7)
        XCTAssertNotNil(controller.paidReset.value)
        await provider.setFailures(recent: true, daily: false, reset: true)
        let second = await controller.refresh(cookieHeader: "synthetic", owner: owner, isCurrent: { true })
        XCTAssertFalse(second)
        XCTAssertEqual(controller.recent.availability, .stale)
        XCTAssertEqual(controller.daily.availability, .current)
        XCTAssertEqual(controller.paidReset.availability, .stale)
        await provider.setFailures(recent: false, daily: true, reset: false)
        _ = await controller.refresh(cookieHeader: "synthetic", owner: owner, isCurrent: { true })
        XCTAssertEqual(controller.recent.availability, .current)
        XCTAssertEqual(controller.daily.availability, .stale)
        XCTAssertEqual(controller.paidReset.availability, .current)
        controller.bind(.init(generation: 2, credentialDigest: "credential-b", subjectDigest: "subject-b"))
        XCTAssertNil(controller.recent.value)
        XCTAssertNil(controller.daily.value)
        XCTAssertNil(controller.paidReset.value)
    }

    func testExplicitUnlinkedIdentityClearsPreviouslyLinkedActivity() async {
        let provider = SharedActivityFixture()
        let controller = SharedActivityController(provider: provider, now: { self.now })
        controller.bind(owner)
        _ = await controller.refresh(cookieHeader: "synthetic", owner: owner, isCurrent: { true })
        XCTAssertNotNil(controller.recent.value)
        await provider.setUnlinked()
        _ = await controller.refresh(cookieHeader: "synthetic", owner: owner, isCurrent: { true })
        XCTAssertNil(controller.recent.value)
        XCTAssertNil(controller.daily.value)
        XCTAssertNil(controller.paidReset.value)
        XCTAssertEqual(controller.recent.availability, .unavailable)
    }

    func testUnlinkedStatusClearsPaidResetDespiteMalformedMonthlyDates() async {
        for monthly in [#"{"periodStart":null,"resetsAt":null}"#, #"{"periodStart":42,"resetsAt":[]}"#, #""malformed""#] {
            let provider = SharedActivityFixture()
            let controller = SharedActivityController(provider: provider, now: { self.now })
            controller.bind(owner)
            _ = await controller.refresh(cookieHeader: "synthetic", owner: owner, isCurrent: { true })
            XCTAssertNotNil(controller.paidReset.value)
            await provider.setUnlinked(monthlyUsageJSON: monthly)
            _ = await controller.refresh(cookieHeader: "synthetic", owner: owner, isCurrent: { true })
            XCTAssertNil(controller.paidReset.value, monthly)
            XCTAssertEqual(controller.paidReset.availability, .unavailable, monthly)
            XCTAssertEqual(controller.paidReset.error, .identityUnlinked, monthly)
        }
    }

    func testLateAccountAndCancelledResponsesCannotPublish() async {
        let provider = SharedActivityFixture()
        await provider.holdRecent()
        let controller = SharedActivityController(provider: provider, now: { self.now })
        controller.bind(owner)
        let task = Task { await controller.refresh(cookieHeader: "synthetic", owner: owner, isCurrent: { true }) }
        await provider.waitForRecent()
        controller.reset()
        await provider.releaseRecent()
        _ = await task.value
        XCTAssertNil(controller.recent.value)
        XCTAssertNil(controller.daily.value)
        controller.bind(owner)
        let cancelled = Task { await controller.refresh(cookieHeader: "synthetic", owner: owner, isCurrent: { false }) }
        _ = await cancelled.value
        XCTAssertNil(controller.recent.value)
    }
}

actor SharedActivityFixture: CursorSharedActivityFetching {
    private var recentFails = false
    private var dailyFails = false
    private var resetFails = false
    private var unlinked = false
    private var unlinkedMonthlyUsage: String?
    func setUnlinked(monthlyUsageJSON: String? = nil) { unlinked = true; unlinkedMonthlyUsage = monthlyUsageJSON }
    private var held = false
    private var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func setFailures(recent: Bool, daily: Bool, reset: Bool) { recentFails = recent; dailyFails = daily; resetFails = reset }
    func holdRecent() { held = true }
    func waitForRecent() async { while !waiting { await Task.yield() } }
    func releaseRecent() { held = false; continuation?.resume(); continuation = nil }
    func fetchRecent(cookieHeader: String, start: Date, end: Date) async throws -> SharedBillingItemsResponse {
        if held { waiting = true; await withCheckedContinuation { continuation = $0 } }
        if recentFails { throw CursorSharedAPIError.forbidden }
        if unlinked { return try decode(#"{"availability":"identity_unlinked"}"#) }
        return try decode("{\"data\":[{\"eventTime\":\"\(ISO8601DateFormatter().string(from: end.addingTimeInterval(-30)))\",\"product\":\"cursor\",\"chargeCategory\":\"usage\",\"usageType\":\"included\",\"totalTokens\":\"123\",\"pricing\":{\"currency\":\"USD\",\"contracted\":\"0.01\"},\"displayExtras\":{\"model\":\"fixture-model\"}}],\"pagination\":{\"hasMore\":false}}")
    }
    func fetchDaily(cookieHeader: String, start: Date, end: Date) async throws -> SharedDailyUsageResponse {
        if dailyFails { throw CursorSharedAPIError.transport }
        if unlinked { return try decode(#"{"availability":"identity_unlinked"}"#) }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return try decode("{\"startTime\":\"\(formatter.string(from: start))\",\"endTime\":\"\(formatter.string(from: end))\",\"totalContractedCost\":\"0\",\"totalTokens\":0,\"totalIncludedTokens\":0,\"series\":[],\"other\":{\"totalContractedCost\":\"0\",\"totalTokens\":0,\"totalIncludedTokens\":0,\"points\":[]}}")
    }
    func fetchStatus(cookieHeader: String) async throws -> SharedUsageStatusResponse {
        if resetFails { throw CursorSharedAPIError.unauthorized }
        if unlinked {
            let monthly = unlinkedMonthlyUsage.map { ",\"monthlyUsage\":\($0)" } ?? ""
            return try decode("{\"availability\":\"identity_unlinked\"\(monthly)}")
        }
        return try decode(#"{"availability":"available","monthlyUsage":{"periodStart":"2026-11-01T00:00:00Z","resetsAt":"2026-12-01T00:00:00Z"}}"#)
    }
    private func decode<T: Decodable>(_ json: String) throws -> T { try JSONDecoder().decode(T.self, from: Data(json.utf8)) }
}
