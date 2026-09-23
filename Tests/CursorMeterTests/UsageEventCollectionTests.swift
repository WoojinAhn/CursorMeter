import XCTest
@testable import CursorMeter

final class UsageEventCollectionTests: XCTestCase {
    private static let today = Date(timeIntervalSince1970: 1_789_603_200)
    private static let cachedAt = today.addingTimeInterval(12_345)
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storedBodies: [[String: Int]] = []
        private var storedClockCalls = 0

        func record(_ request: URLRequest) throws -> Int {
            let body = try XCTUnwrap(JSONSerialization.jsonObject(
                with: WeeklyUsageTests.bodyData(from: request)
            ) as? [String: Int])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/dashboard/get-filtered-usage-events")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "session=synthetic")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://cursor.com")
            lock.lock()
            storedBodies.append(body)
            lock.unlock()
            return try XCTUnwrap(body["page"])
        }

        var bodies: [[String: Int]] {
            lock.lock()
            defer { lock.unlock() }
            return storedBodies
        }

        var clockCalls: Int {
            lock.lock()
            defer { lock.unlock() }
            return storedClockCalls
        }

        func now() -> Date {
            lock.lock()
            defer { lock.unlock() }
            storedClockCalls += 1
            return UsageEventCollectionTests.cachedAt.addingTimeInterval(Double(storedClockCalls - 1))
        }
    }

    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func client() -> CursorAPIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return CursorAPIClient(configuration: configuration)
    }

    private static func page(_ count: Int, total: Int = 999, prefix: String = "first", age: TimeInterval = 0) -> Data {
        let events = (0..<count).map { index in
            UsageEvent(
                timestamp: String(Int(today.addingTimeInterval(-age - Double(index)).timeIntervalSince1970 * 1000)),
                requestsCosts: 1,
                model: "\(prefix)-\(index)"
            )
        }
        let encoded = try! JSONEncoder().encode(events)
        return Data("{\"totalUsageEventsCount\":\(total),\"usageEventsDisplay\":\(String(decoding: encoded, as: UTF8.self))}".utf8)
    }

    private func stub(
        _ recorder: Recorder,
        handler: @escaping (Int) throws -> (Int, Data)
    ) {
        MockURLProtocol.requestHandler = { request in
            let page = try recorder.record(request)
            let (status, data) = try handler(page)
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, data)
        }
    }

    private func collect(_ recorder: Recorder, personal: Bool = false) async -> UsageEventCollection {
        await UsageEventCollection.collect(
            apiClient: client(), cookieHeader: "session=synthetic",
            teamId: personal ? 0 : 42, userId: personal ? nil : 7,
            pageSize: 100, maxPages: 5, today: Self.today, calendar: Self.calendar,
            now: { recorder.now() }
        )
    }

    private func failure(_ collection: UsageEventCollection, file: StaticString = #filePath, line: UInt = #line) -> Error? {
        guard case .failure(let error) = collection.weekly else {
            XCTFail("Expected the original weekly error", file: file, line: line)
            return nil
        }
        return error
    }

    func testFirstPageFeedsBothResultsWithoutExtraRequest() async throws {
        let recorder = Recorder()
        stub(recorder) { page in
            if page == 2 { XCTAssertEqual(recorder.clockCalls, 1, "Timestamp captured before page 2") }
            return (200, Self.page(page == 1 ? 100 : 10, total: 110, prefix: "page\(page)"))
        }

        let result = await collect(recorder)

        XCTAssertEqual(try result.weekly.get().count, 110)
        XCTAssertEqual(result.recent?.entries.map(\.model), (0..<30).map { "page1-\($0)" })
        XCTAssertEqual(result.recent?.cachedAt, Self.cachedAt)
        XCTAssertEqual(recorder.clockCalls, 1)
        XCTAssertEqual(recorder.bodies, [
            ["teamId": 42, "userId": 7, "page": 1, "pageSize": 100],
            ["teamId": 42, "userId": 7, "page": 2, "pageSize": 100],
        ])
    }

    func testPersonalRequestStillOmitsUserId() async throws {
        let recorder = Recorder()
        stub(recorder) { _ in (200, Self.page(1, total: 1)) }
        let result = await collect(recorder, personal: true)
        XCTAssertEqual(try result.weekly.get().count, 1)
        XCTAssertEqual(recorder.bodies, [["teamId": 0, "page": 1, "pageSize": 100]])
    }

    func testRecentLimitDoesNotStopWeeklyPaginationBeforeFivePageCap() async throws {
        let recorder = Recorder()
        stub(recorder) { _ in (200, Self.page(100)) }
        let result = await collect(recorder)
        XCTAssertEqual(try result.weekly.get().count, 500)
        XCTAssertEqual(result.recent?.entries.count, 30)
        XCTAssertEqual(recorder.bodies.map { $0["page"] }, [1, 2, 3, 4, 5])
        XCTAssertTrue(recorder.bodies.allSatisfy { $0["pageSize"] == 100 })
        XCTAssertEqual(recorder.clockCalls, 1)
    }

    func testSparseFirstPageIsNotFilledFromLaterPages() async throws {
        let recorder = Recorder()
        stub(recorder) { page in (200, Self.page(page == 1 ? 2 : 3, total: 5, prefix: "page\(page)")) }
        let result = await collect(recorder)
        XCTAssertEqual(try result.weekly.get().count, 5)
        XCTAssertEqual(result.recent?.entries.map(\.model), ["page1-0", "page1-1"])
        XCTAssertEqual(recorder.bodies.count, 2)
    }

    func testSevenDayStopDoesNotFilterOldRecentEntries() async throws {
        let recorder = Recorder()
        stub(recorder) { _ in (200, Self.page(2, age: 8 * 86_400)) }
        let result = await collect(recorder)
        XCTAssertEqual(try result.weekly.get().count, 2)
        XCTAssertEqual(result.recent?.entries.count, 2)
        XCTAssertEqual(recorder.bodies.count, 1)
    }

    func testEventAtCutoffAllowsNextPage() async throws {
        let recorder = Recorder()
        stub(recorder) { page in (200, Self.page(1, age: Double(page == 1 ? 6 : 7) * 86_400)) }
        let result = await collect(recorder)
        XCTAssertEqual(try result.weekly.get().count, 2)
        XCTAssertEqual(recorder.bodies.count, 2)
    }

    func testEmptyLaterPageStopsWithoutReplacingCandidate() async throws {
        let recorder = Recorder()
        stub(recorder) { page in (200, Self.page(page == 1 ? 2 : 0)) }
        let result = await collect(recorder)
        XCTAssertEqual(try result.weekly.get().count, 2)
        XCTAssertEqual(result.recent?.entries.count, 2)
        XCTAssertEqual(result.recent?.cachedAt, Self.cachedAt)
        XCTAssertEqual(recorder.bodies.count, 2)
        XCTAssertEqual(recorder.clockCalls, 1)
    }

    func testExplicitOrOmittedZeroEmptyPagePublishesEmptyCandidate() async throws {
        for json in [
            "{\"usageEventsDisplay\":[]}",
            "{\"totalUsageEventsCount\":10,\"usageEventsDisplay\":[]}",
            "{\"totalUsageEventsCount\":0,\"usageEventsDisplay\":[]}",
            "{\"totalUsageEventsCount\":0}",
        ] {
            let recorder = Recorder()
            stub(recorder) { _ in (200, Data(json.utf8)) }
            let result = await collect(recorder)
            XCTAssertEqual(try result.weekly.get().count, 0, json)
            XCTAssertEqual(result.recent?.entries.count, 0, json)
            XCTAssertEqual(result.recent?.cachedAt, Self.cachedAt)
            XCTAssertEqual(recorder.bodies.count, 1)
            XCTAssertEqual(recorder.clockCalls, 1)
        }
    }

    func testMissingArrayWithPositiveCountStopsWeeklyWithoutCandidate() async throws {
        let recorder = Recorder()
        stub(recorder) { _ in (200, Data("{\"totalUsageEventsCount\":12}".utf8)) }
        let result = await collect(recorder)
        XCTAssertTrue(try result.weekly.get().isEmpty)
        XCTAssertNil(result.recent)
        XCTAssertEqual(recorder.bodies.count, 1)
        XCTAssertEqual(recorder.clockCalls, 1)
    }

    func testAllInvalidTimestampsPreserveWeeklyEventsButRejectCandidate() async throws {
        let recorder = Recorder()
        stub(recorder) { _ in (200, Data("{\"usageEventsDisplay\":[{\"timestamp\":\"invalid\"}]}".utf8)) }
        let result = await collect(recorder)
        XCTAssertEqual(try result.weekly.get().map(\.timestamp), ["invalid"])
        XCTAssertNil(result.recent)
        XCTAssertEqual(recorder.bodies.count, 1)
    }

    func testFirstPageHTTPFailureHasNoCandidateOrTimestamp() async {
        let recorder = Recorder()
        stub(recorder) { _ in (500, Data()) }
        let result = await collect(recorder)
        XCTAssertNil(result.recent)
        guard case APIError.httpError(statusCode: 500)? = failure(result) else { return XCTFail("Expected HTTP 500") }
        XCTAssertEqual(recorder.bodies.count, 1)
        XCTAssertEqual(recorder.clockCalls, 0)
    }

    func testLaterTransientHTTPFailurePreservesFirstCandidateAndTimestamp() async {
        for status in [408, 429, 500, 503, 599] {
            let recorder = Recorder()
            stub(recorder) { page in page == 1 ? (200, Self.page(2)) : (status, Data()) }
            let result = await collect(recorder)
            XCTAssertEqual(result.recent?.entries.count, 2)
            XCTAssertEqual(result.recent?.cachedAt, Self.cachedAt)
            guard case APIError.httpError(let actual)? = failure(result) else { return XCTFail("Expected HTTP error") }
            XCTAssertEqual(actual, status)
            XCTAssertEqual(recorder.bodies.count, 2)
            XCTAssertEqual(recorder.clockCalls, 1)
        }
    }

    func testLaterNetworkFailurePreservesFirstCandidateAndOriginalError() async {
        for code in [URLError.timedOut, .networkConnectionLost, .unknown] {
            let recorder = Recorder()
            stub(recorder) { page in
                if page == 2 { throw URLError(code) }
                return (200, Self.page(2))
            }
            let result = await collect(recorder)
            XCTAssertEqual(result.recent?.entries.count, 2)
            XCTAssertEqual(result.recent?.cachedAt, Self.cachedAt)
            guard case APIError.networkError(let underlying)? = failure(result) else { return XCTFail("Expected transport error") }
            XCTAssertEqual((underlying as? URLError)?.code, code)
            XCTAssertEqual(recorder.bodies.count, 2)
            XCTAssertEqual(recorder.clockCalls, 1)
        }
    }

    func testLaterAuthOrRequestFailureDiscardsCandidate() async {
        for status in [400, 401, 403, 404, 409, 422, 600] {
            let recorder = Recorder()
            stub(recorder) { page in page == 1 ? (200, Self.page(2)) : (status, Data()) }
            let result = await collect(recorder)
            XCTAssertNil(result.recent, "HTTP \(status)")
            switch failure(result) {
            case APIError.unauthorized?: XCTAssertEqual(status, 401)
            case APIError.forbidden?: XCTAssertEqual(status, 403)
            case APIError.httpError(let actual)?: XCTAssertEqual(actual, status)
            default: XCTFail("Expected original API error for HTTP \(status)")
            }
            XCTAssertEqual(recorder.bodies.count, 2)
        }
    }

    func testIncompletePageDecodeNeverPublishesCandidate() async {
        for failedPage in [1, 2] {
            let recorder = Recorder()
            stub(recorder) { page in
                (200, page == failedPage ? Data("{\"usageEventsDisplay\":[{\"timestamp\":123}]}".utf8) : Self.page(2))
            }
            let result = await collect(recorder)
            XCTAssertNil(result.recent)
            XCTAssertTrue(failure(result) is DecodingError)
            XCTAssertEqual(recorder.bodies.count, failedPage)
            XCTAssertEqual(recorder.clockCalls, failedPage - 1)
        }
    }

    func testWrappedCancellationDiscardsFirstCandidateAndStopsRequests() async {
        let recorder = Recorder()
        stub(recorder) { page in
            if page == 2 { throw URLError(.cancelled) }
            return (200, Self.page(2))
        }
        let result = await collect(recorder)
        XCTAssertNil(result.recent)
        guard case APIError.networkError(let underlying)? = failure(result) else { return XCTFail("Expected wrapped cancellation") }
        XCTAssertEqual((underlying as? URLError)?.code, .cancelled)
        XCTAssertEqual(recorder.bodies.count, 2)
        XCTAssertEqual(recorder.clockCalls, 1)
    }

    func testAlreadyCancelledCollectionMakesNoRequest() async {
        let recorder = Recorder()
        stub(recorder) { _ in (200, Self.page(1)) }
        let client = client()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await UsageEventCollection.collect(
                apiClient: client, cookieHeader: "session=synthetic", teamId: 0, userId: nil,
                pageSize: 100, maxPages: 5, today: Self.today, calendar: Self.calendar,
                now: { recorder.now() }
            )
        }
        let result = await task.value
        XCTAssertNil(result.recent)
        XCTAssertTrue(failure(result) is CancellationError)
        XCTAssertTrue(recorder.bodies.isEmpty)
        XCTAssertEqual(recorder.clockCalls, 0)
    }

    func testCancellationAfterFirstDecodeNeverPublishesOrRequestsNextPage() async {
        for total in [1, 999] {
            let recorder = Recorder()
            stub(recorder) { _ in (200, Self.page(1, total: total)) }
            let client = client()
            let task = Task {
                await UsageEventCollection.collect(
                    apiClient: client, cookieHeader: "session=synthetic", teamId: 0, userId: nil,
                    pageSize: 100, maxPages: 5, today: Self.today, calendar: Self.calendar,
                    now: {
                        withUnsafeCurrentTask { $0?.cancel() }
                        return recorder.now()
                    }
                )
            }
            let result = await task.value
            XCTAssertNil(result.recent)
            XCTAssertTrue(failure(result) is CancellationError)
            XCTAssertEqual(recorder.bodies.count, 1)
            XCTAssertEqual(recorder.clockCalls, 1)
        }
    }

    func testCancellationClassifierHandlesDirectAndWrappedForms() {
        XCTAssertTrue(UsageEventCollection.isCancellation(CancellationError()))
        XCTAssertTrue(UsageEventCollection.isCancellation(URLError(.cancelled)))
        XCTAssertTrue(UsageEventCollection.isCancellation(APIError.networkError(URLError(.cancelled))))
        XCTAssertTrue(UsageEventCollection.isCancellation(APIError.networkError(CancellationError())))
        XCTAssertTrue(UsageEventCollection.isCancellation(APIError.networkError(APIError.networkError(URLError(.cancelled)))))
        XCTAssertFalse(UsageEventCollection.isCancellation(URLError(.timedOut)))
        XCTAssertFalse(UsageEventCollection.isCancellation(APIError.networkError(URLError(.timedOut))))
        XCTAssertFalse(UsageEventCollection.isCancellation(APIError.unauthorized))
    }
}
