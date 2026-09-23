import XCTest
@testable import CursorMeter

/// Tests for #84: session-expiry timestamps persisted to UserDefaults for
/// auditability, plus the redacted Set-Cookie rotation diagnostic.
@MainActor
final class SessionExpiryAuditTests: XCTestCase {

    // nonisolated: referenced from nonisolated setUp/tearDown overrides —
    // CI's stricter isolation inference rejects the @MainActor-inferred default.
    nonisolated private static let historyKey = "sessionExpiryHistory"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.historyKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.historyKey)
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    // MARK: - cappedExpiryHistory (pure)

    func testCappedHistoryAppendsInOrder() {
        let d1 = Date(timeIntervalSince1970: 1000)
        let d2 = Date(timeIntervalSince1970: 2000)
        let result = UsageViewModel.cappedExpiryHistory([d1], appending: d2)
        XCTAssertEqual(result, [d1, d2])
    }

    func testCappedHistoryDropsOldestBeyondCap() {
        let dates = (0..<50).map { Date(timeIntervalSince1970: Double($0)) }
        let newest = Date(timeIntervalSince1970: 9999)
        let result = UsageViewModel.cappedExpiryHistory(dates, appending: newest)
        XCTAssertEqual(result.count, 50)
        XCTAssertEqual(result.first, Date(timeIntervalSince1970: 1), "oldest entry dropped")
        XCTAssertEqual(result.last, newest)
    }

    // MARK: - expiry recording (integration, MockURLProtocol)

    private func makeExpiringViewModel() -> UsageViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let vm = UsageViewModel(
            apiClient: CursorAPIClient(configuration: config),
            refreshFeedback: RefreshFeedback(timing: .immediate)
        )
        vm.updateCheckRunner = { .upToDate }
        vm.keychainDeleteHandler = {}
        vm.sessionExpiredNotifier = {}
        vm.testHook_setCookieHeader("WorkosCursorSessionToken=test")
        vm.authState = .loggedIn
        return vm
    }

    func testUnauthorizedRefreshRecordsExpiryTimestamp() async {
        let vm = makeExpiringViewModel()
        MockURLProtocol.requestHandler = { request in
            let unauthorized = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (unauthorized, Data())
        }

        let before = Date()
        await vm.refresh()

        let history = UserDefaults.standard.object(forKey: Self.historyKey) as? [Date]
        XCTAssertEqual(history?.count, 1)
        if let recorded = history?.first {
            XCTAssertGreaterThanOrEqual(recorded, before.addingTimeInterval(-1))
            XCTAssertLessThanOrEqual(recorded, Date().addingTimeInterval(1))
        }
    }

    func testManualRefreshWhileExpiredDoesNotRecordAgain() async {
        let vm = makeExpiringViewModel()
        MockURLProtocol.requestHandler = { request in
            let unauthorized = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (unauthorized, Data())
        }

        await vm.refresh()  // loggedIn → loginRequired: records
        vm.testHook_setCookieHeader("WorkosCursorSessionToken=test")
        await vm.refresh()  // already loginRequired: must not record

        let history = UserDefaults.standard.object(forKey: Self.historyKey) as? [Date]
        XCTAssertEqual(history?.count, 1, "only the loggedIn→loginRequired transition records")
    }

    // MARK: - Set-Cookie summary (pure, redaction)

    func testSetCookieSummaryNilWhenHeaderAbsent() {
        XCTAssertNil(CursorAPIClient.setCookieSummary(fromHeaders: [:]))
        XCTAssertNil(CursorAPIClient.setCookieSummary(fromHeaders: ["Content-Type": "application/json"]))
    }

    func testSetCookieSummaryExtractsNamesOnly() {
        let headers: [AnyHashable: Any] = [
            "Set-Cookie": "WorkosCursorSessionToken=SECRETVALUE; Path=/; Expires=Tue, 15 Jul 2026 00:00:00 GMT; HttpOnly, NEXT_LOCALE=en; Path=/"
        ]
        let summary = CursorAPIClient.setCookieSummary(fromHeaders: headers)
        XCTAssertNotNil(summary)
        XCTAssertTrue(summary!.contains("WorkosCursorSessionToken"))
        XCTAssertTrue(summary!.contains("NEXT_LOCALE"))
        XCTAssertFalse(summary!.contains("SECRETVALUE"), "cookie values must never be logged")
        XCTAssertFalse(summary!.contains("Path"), "attributes are not cookie names")
    }
}
