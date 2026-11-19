import XCTest
@testable import CursorMeter

final class SharedAllowanceAggregateTests: XCTestCase {
    private let start = ISO8601DateFormatter().date(from: "2026-11-12T12:00:00Z")!
    private let end = ISO8601DateFormatter().date(from: "2026-11-19T11:59:00Z")!

    func testExactPeriodAcceptsEightPartialUTCDatesAndExcludesPaidTokensAndCostRankUnion() throws {
        let response = try decode(fixture())
        XCTAssertEqual(try response.includedTokens(start: start, end: end), 85)
        XCTAssertThrowsError(try response.days(start: start, end: end))
    }

    func testCostOnlyUnionCannotExceedTokenOtherInAnyTokenCategory() throws {
        for (tokens, included) in [(0, 0), (8, 4), (10, 3), (10, 9)] {
            var object = fixture()
            object["totalTokens"] = 100 + tokens
            object["totalIncludedTokens"] = 80 + included
            object["other"] = ["totalTokens": tokens, "totalIncludedTokens": included,
                "points": [["dayStartTime": "2026-11-19T00:00:00Z", "tokens": tokens, "includedTokens": included]]]
            XCTAssertThrowsError(try decode(object).includedTokens(start: start, end: end), "other \(tokens)/\(included)")
        }
    }

    func testCostOnlyUnionMustFitOtherOnEachUTCDate() throws {
        var object = fixture()
        object["other"] = ["totalTokens": 10, "totalIncludedTokens": 5,
            "points": [["dayStartTime": "2026-11-18T00:00:00Z", "tokens": 10, "includedTokens": 5]]]
        XCTAssertThrowsError(try decode(object).includedTokens(start: start, end: end))
    }

    func testCombinedCostOnlySeriesMustFitOtherWithoutDoubleCounting() throws {
        var object = fixture()
        var series = object["series"] as! [[String: Any]]
        var extra = series[2]
        extra["dimensions"] = ["usageType": "another_cost_only"]
        extra["costRank"] = 3
        extra["tokenRank"] = 22
        series.append(extra)
        object["series"] = series
        XCTAssertThrowsError(try decode(object).includedTokens(start: start, end: end))
    }

    func testOtherMayContainUndisplayedGroupsInAdditionToCostOnlyUnion() throws {
        var object = fixture()
        object["totalTokens"] = 120
        object["totalIncludedTokens"] = 90
        object["other"] = ["totalTokens": 20, "totalIncludedTokens": 10,
            "points": [["dayStartTime": "2026-11-19T00:00:00Z", "tokens": 20, "includedTokens": 10]]]
        XCTAssertEqual(try decode(object).includedTokens(start: start, end: end), 90)
    }

    func testRangeEchoAndUTCPointsMustMatchRequestedPeriod() throws {
        for key in ["startTime", "endTime"] {
            var object = fixture(); object[key] = "2026-11-12T12:00:00.002Z"
            XCTAssertThrowsError(try decode(object).includedTokens(start: start, end: end))
        }
        for day in ["2026-11-11T00:00:00Z", "2026-11-20T00:00:00Z", "2026-11-12T12:00:00Z", "bad"] {
            var object = fixture()
            var series = object["series"] as! [[String: Any]]
            var points = series[0]["points"] as! [[String: Any]]
            points[0]["dayStartTime"] = day; series[0]["points"] = points; object["series"] = series
            XCTAssertThrowsError(try decode(object).includedTokens(start: start, end: end), day)
        }
    }

    func testMissingInvalidAndInconsistentIncludedTotalsAreRejected() throws {
        for value: Any in [-1, 801, "80", NSNull(), SharedActivityValue.maximumTokens + 1] {
            var object = fixture(); object["totalIncludedTokens"] = value
            XCTAssertThrowsError(try decode(object).includedTokens(start: start, end: end))
        }
        for key in ["totalTokens", "totalIncludedTokens"] {
            var object = fixture(); object.removeValue(forKey: key)
            XCTAssertThrowsError(try decode(object).includedTokens(start: start, end: end))
        }
        var object = fixture(); object["totalIncludedTokens"] = 79
        XCTAssertThrowsError(try decode(object).includedTokens(start: start, end: end))
        object = fixture(); object["totalTokens"] = 101
        XCTAssertThrowsError(try decode(object).includedTokens(start: start, end: end))
    }

    func testDuplicateSeriesPointsAndBadPerSeriesSumsAreRejected() throws {
        for mutation in 0..<5 {
            var object = fixture()
            var series = object["series"] as! [[String: Any]]
            if mutation == 0 { series.append(series[0]) }
            if mutation == 1 { var points = series[0]["points"] as! [[String: Any]]; points[1] = points[0]; series[0]["points"] = points }
            if mutation == 2 { series[0]["totalIncludedTokens"] = 79 }
            if mutation == 3 { series[0]["totalTokens"] = 79 }
            if mutation == 4 { var points = series[0]["points"] as! [[String: Any]]; points[0]["includedTokens"] = 11; series[0]["points"] = points }
            object["series"] = series
            XCTAssertThrowsError(try decode(object).includedTokens(start: start, end: end), "mutation \(mutation)")
        }
    }

    func testOtherPointSumMustReconcileAndBoundedAdditionCannotOverflow() throws {
        var object = fixture()
        object["other"] = ["totalTokens": 1, "totalIncludedTokens": 1, "points": []]
        XCTAssertThrowsError(try decode(object).includedTokens(start: start, end: end))
        object = fixture()
        var series = object["series"] as! [[String: Any]]
        for index in 0..<2 {
            series[index]["totalTokens"] = SharedActivityValue.maximumTokens
            series[index]["totalIncludedTokens"] = SharedActivityValue.maximumTokens
            series[index]["points"] = [["dayStartTime": "2026-11-12T00:00:00Z", "tokens": SharedActivityValue.maximumTokens, "includedTokens": SharedActivityValue.maximumTokens]]
        }
        object["series"] = series
        object["totalTokens"] = SharedActivityValue.maximumTokens
        object["totalIncludedTokens"] = SharedActivityValue.maximumTokens
        XCTAssertThrowsError(try decode(object).includedTokens(start: start, end: end))
    }

    private func decode(_ object: [String: Any]) throws -> SharedDailyUsageResponse {
        try JSONDecoder().decode(SharedDailyUsageResponse.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func fixture() -> [String: Any] {
        let points: [[String: Any]] = (12...19).map { ["dayStartTime": "2026-11-\($0)T00:00:00Z", "tokens": 10, "includedTokens": 10] }
        return ["startTime": "2026-11-12T12:00:00Z", "endTime": "2026-11-19T11:59:00Z", "totalTokens": 110, "totalIncludedTokens": 85,
            "series": [
                ["dimensions": ["usageType": "included"], "costRank": 21, "tokenRank": 1, "totalTokens": 80, "totalIncludedTokens": 80, "points": points],
                ["dimensions": ["usageType": "on_demand"], "costRank": 1, "tokenRank": 2, "totalTokens": 20, "totalIncludedTokens": 0,
                 "points": [["dayStartTime": "2026-11-19T00:00:00Z", "tokens": 20, "includedTokens": 0]]],
                ["dimensions": ["usageType": "cost_only"], "costRank": 2, "tokenRank": 21, "totalTokens": 9, "totalIncludedTokens": 4,
                 "points": [["dayStartTime": "2026-11-19T00:00:00Z", "tokens": 9, "includedTokens": 4]]]
            ], "other": ["totalTokens": 10, "totalIncludedTokens": 5,
                "points": [["dayStartTime": "2026-11-19T00:00:00Z", "tokens": 10, "includedTokens": 5]]]]
    }
}
