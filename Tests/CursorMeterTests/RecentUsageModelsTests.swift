import XCTest
@testable import CursorMeter

final class RecentUsageModelsTests: XCTestCase {
    private func decodeEvent(_ fields: String) throws -> UsageEvent {
        try JSONDecoder().decode(
            UsageEvent.self,
            from: Data("{\"timestamp\":\"1780402687672\",\(fields)}".utf8)
        )
    }

    private func encodedObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    func testListFieldsSurviveDecoding() throws {
        let event = try decodeEvent("""
        "model":"test-model","customSubscriptionName":"free",
        "tokenUsage":{"inputTokens":"100","outputTokens":20,"cacheReadTokens":3,"cacheWriteTokens":"4"}
        """)
        let encoded = try encodedObject(event)
        XCTAssertEqual(encoded["model"] as? String, "test-model")
        XCTAssertEqual(encoded["customSubscriptionName"] as? String, "free")
        let tokens = try XCTUnwrap(encoded["tokenUsage"] as? [String: Any])
        XCTAssertEqual(tokens["inputTokens"] as? Int, 100)
        XCTAssertEqual(tokens["outputTokens"] as? Int, 20)
        XCTAssertEqual(tokens["cacheReadTokens"] as? Int, 3)
        XCTAssertEqual(tokens["cacheWriteTokens"] as? Int, 4)
    }

    func testOmittedEventArrayStaysOmittedAfterCodableRoundTrip() throws {
        let response = try JSONDecoder().decode(
            FilteredUsageEventsResponse.self,
            from: Data(#"{"totalUsageEventsCount":5}"#.utf8)
        )
        XCTAssertNil(try encodedObject(response)["usageEventsDisplay"])
    }

    private func response(_ json: String) throws -> FilteredUsageEventsResponse {
        try JSONDecoder().decode(FilteredUsageEventsResponse.self, from: Data(json.utf8))
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    func testMalformedListFieldsDoNotBreakChartOrRow() throws {
        let event = try decodeEvent(#""requestsCosts":2,"chargedCents":8,"model":{"bad":true},"tokenUsage":"bad","customSubscriptionName":[]"#)
        XCTAssertEqual(event.requestsCosts, 2)
        XCTAssertNil(event.model)
        XCTAssertNil(event.tokenUsage)
        XCTAssertNil(event.customSubscriptionName)
        let entry = try XCTUnwrap(RecentUsageEntry(event: event))
        XCTAssertNil(entry.model)
        XCTAssertNil(entry.tokens)
        XCTAssertEqual(entry.chargedCents, 8)
    }

    func testCoreFieldTypesRemainStrict() {
        for json in [
            #"{}"#, #"{"timestamp":null}"#, #"{"timestamp":123}"#,
            #"{"timestamp":{}}"#, #"{"timestamp":"1","requestsCosts":"2"}"#,
            #"{"timestamp":"1","kind":7}"#, #"{"timestamp":"1","chargedCents":"8"}"#,
        ] {
            XCTAssertThrowsError(try response("{\"usageEventsDisplay\":[\(json)]}"), json)
        }
    }

    func testTokenTotalAcceptsIntegralNumbersAndIntegerStrings() throws {
        let event = try decodeEvent(#""tokenUsage":{"inputTokens":"100","outputTokens":20.0,"cacheReadTokens":3,"cacheWriteTokens":"4","totalCents":987}"#)
        XCTAssertEqual(RecentUsageEntry(event: event)?.tokens, 127)
        XCTAssertNil(RecentUsageEntry(event: event)?.chargedCents)
    }

    func testMissingAndNullCacheCountersAreZero() throws {
        for extras in ["", #", "cacheReadTokens":null,"cacheWriteTokens":null"#] {
            let event = try decodeEvent("\"tokenUsage\":{\"inputTokens\":10,\"outputTokens\":20\(extras)}")
            XCTAssertEqual(RecentUsageEntry(event: event)?.tokens, 30)
        }
    }

    func testMissingRequiredTokenCountersMakeTotalUnknown() throws {
        for counters in [#"{}"#, #"{"inputTokens":10}"#, #"{"outputTokens":10}"#,
                         #"{"inputTokens":null,"outputTokens":10}"#] {
            let event = try decodeEvent("\"tokenUsage\":\(counters)")
            XCTAssertNil(RecentUsageEntry(event: event)?.tokens)
        }
    }

    func testInvalidTokenCounterValuesMakeTotalUnknown() throws {
        let badValues = ["-1", #""-1""#, "1.2", #""1.2""#, #""1e3""#, "true", "{}", "[]", #""invalid""#, "9223372036854775808", #""9223372036854775808""#]
        for key in ["inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens"] {
            for value in badValues {
                let fields = ["inputTokens", "outputTokens", "cacheReadTokens", "cacheWriteTokens"].map {
                    "\"\($0)\":\($0 == key ? value : "1")"
                }.joined(separator: ",")
                let event = try decodeEvent("\"tokenUsage\":{\(fields)}")
                XCTAssertNil(RecentUsageEntry(event: event)?.tokens, "\(key)=\(value)")
            }
        }
    }

    func testTokenSumRejectsOverflowButPreservesExactMaximum() throws {
        let valid = try decodeEvent("\"tokenUsage\":{\"inputTokens\":\(Int.max),\"outputTokens\":0}")
        XCTAssertEqual(RecentUsageEntry(event: valid)?.tokens, Int.max)
        let overflowing = try decodeEvent("\"tokenUsage\":{\"inputTokens\":\(Int.max),\"outputTokens\":1}")
        XCTAssertNil(RecentUsageEntry(event: overflowing)?.tokens)
    }

    func testInvalidCacheCounterRemainsUnknownAfterCodableRoundTrip() throws {
        let event = try decodeEvent(#""tokenUsage":{"inputTokens":10,"outputTokens":20,"cacheReadTokens":"bad"}"#)
        let restored = try JSONDecoder().decode(UsageEvent.self, from: JSONEncoder().encode(event))
        XCTAssertNil(RecentUsageEntry(event: restored)?.tokens)
    }

    func testKindsMatchDocumentedClassification() throws {
        let cases: [(String?, String?, RecentUsageKind)] = [
            ("USAGE_EVENT_KIND_INCLUDED_IN_BUSINESS", nil, .included),
            ("USAGE_EVENT_KIND_INCLUDED_IN_PRO", nil, .included),
            ("USAGE_EVENT_KIND_INCLUDED_IN_ULTRA", nil, .included),
            ("USAGE_EVENT_KIND_USAGE_BASED", nil, .onDemand),
            ("USAGE_EVENT_KIND_FREE_CREDIT", nil, .free),
            ("USAGE_EVENT_KIND_CUSTOM_SUBSCRIPTION", "free", .free),
            ("USAGE_EVENT_KIND_CUSTOM_SUBSCRIPTION", "Free", .other),
            ("USAGE_EVENT_KIND_CUSTOM_SUBSCRIPTION", nil, .other),
            ("USAGE_EVENT_KIND_ERRORED_NOT_CHARGED", nil, .other),
            ("USAGE_EVENT_KIND_USAGE_BASED_UNKNOWN", nil, .other),
            ("FUTURE_KIND", "free", .other), (nil, nil, .other),
        ]
        for (kind, customName, expected) in cases {
            let event = UsageEvent(timestamp: "1780402687672", kind: kind, customSubscriptionName: customName)
            XCTAssertEqual(RecentUsageEntry(event: event)?.kind, expected, "\(kind ?? "nil")")
        }
    }

    func testCandidateTakesNewestThirtyWithStableTiesAndDuplicates() throws {
        let events = (0..<35).map {
            "{\"timestamp\":\"\(1_780_402_600_000 + ($0 / 2) * 1000)\",\"model\":\"model-\($0)\"}"
        }
        let page = try response("{\"totalUsageEventsCount\":100,\"usageEventsDisplay\":[\(events.joined(separator: ","))]}")
        let cachedAt = date("2026-09-24T00:00:00Z")
        let candidate = try XCTUnwrap(RecentUsageCandidate(response: page, cachedAt: cachedAt))
        XCTAssertEqual(candidate.entries.count, RecentUsageCandidate.limit)
        XCTAssertEqual(candidate.entries.prefix(5).compactMap(\.model), ["model-34", "model-32", "model-33", "model-30", "model-31"])
        XCTAssertEqual(candidate.entries.last?.model, "model-4")
        XCTAssertEqual(candidate.cachedAt, cachedAt)

        let duplicate = #"{"timestamp":"1780402687672","model":"same"}"#
        let duplicates = try response("{\"usageEventsDisplay\":[\(duplicate),\(duplicate)]}")
        XCTAssertEqual(RecentUsageCandidate(response: duplicates, cachedAt: cachedAt)?.entries.count, 2)
    }

    func testCandidateKeepsSparseFirstPageAndOldEvents() throws {
        let page = try response(#"{"totalUsageEventsCount":1000,"usageEventsDisplay":[{"timestamp":"1780402687672"},{"timestamp":"invalid"}]}"#)
        let candidate = try XCTUnwrap(RecentUsageCandidate(response: page, cachedAt: date("2026-09-24T00:00:00Z")))
        XCTAssertEqual(candidate.entries.count, 1)
        XCTAssertEqual(candidate.entries[0].date.timeIntervalSince1970, 1780402687.672)
    }

    func testInvalidDatesDoNotConsumeCandidateLimit() throws {
        let events = Array(repeating: #"{"timestamp":"invalid"}"#, count: 30)
            + [#"{"timestamp":"1780402687672"}"#]
        let page = try response("{\"usageEventsDisplay\":[\(events.joined(separator: ","))]}")
        XCTAssertEqual(RecentUsageCandidate(response: page, cachedAt: .distantPast)?.entries.count, 1)
    }

    func testCandidateDistinguishesKnownEmptyFromUnavailablePage() throws {
        for json in [#"{"usageEventsDisplay":[]}"#, #"{"totalUsageEventsCount":100,"usageEventsDisplay":[]}"#, #"{"totalUsageEventsCount":0}"#] {
            let candidate = try XCTUnwrap(RecentUsageCandidate(response: response(json), cachedAt: .distantPast), json)
            XCTAssertEqual(candidate.entries, [])
        }
        for json in [#"{"totalUsageEventsCount":100}"#, #"{"usageEventsDisplay":[{"timestamp":"invalid"}]}"#] {
            XCTAssertNil(RecentUsageCandidate(response: try response(json), cachedAt: .distantPast), json)
        }
    }

    func testCandidateRejectsNonfiniteAndUnrepresentableDates() {
        for timestamp in ["invalid", "NaN", "nan", "inf", "-inf", "1e100", "-1e100"] {
            XCTAssertNil(RecentUsageEntry(event: UsageEvent(timestamp: timestamp)), timestamp)
        }
    }

    func testEntryKeepsOriginalChargedCentsWithoutUsingPricingEstimates() throws {
        for cents in [0, 0.72, 156] {
            let entry = try XCTUnwrap(RecentUsageEntry(event: UsageEvent(timestamp: "1", chargedCents: cents)))
            XCTAssertEqual(entry.chargedCents, cents)
        }
        let estimated = try decodeEvent(#""tokenUsage":{"inputTokens":1,"outputTokens":2,"totalCents":50},"requestsCosts":999"#)
        XCTAssertNil(RecentUsageEntry(event: estimated)?.chargedCents)
    }

    func testInvalidChargesBecomeUnavailableWithoutBreakingCandidateEncoding() throws {
        for cents in [-1, Double.infinity, -Double.infinity, Double.nan] {
            let event = UsageEvent(timestamp: "1780402687672", chargedCents: cents)
            let entry = try XCTUnwrap(RecentUsageEntry(event: event))
            XCTAssertNil(entry.chargedCents)
            let candidate = RecentUsageCandidate(entries: [entry], cachedAt: .distantPast)
            XCTAssertNoThrow(try JSONEncoder().encode(candidate))
        }
    }

    func testCandidateAndEntryCodableRoundTrip() throws {
        let entry = RecentUsageEntry(date: date("2026-09-24T00:00:00Z"), model: "test", kind: .onDemand, tokens: 42, chargedCents: 0.72)
        let candidate = RecentUsageCandidate(entries: [entry], cachedAt: date("2026-09-24T00:10:00Z"))
        XCTAssertEqual(try JSONDecoder().decode(RecentUsageCandidate.self, from: JSONEncoder().encode(candidate)), candidate)
        XCTAssertEqual(RecentUsageCandidate(entries: Array(repeating: entry, count: 35), cachedAt: .distantPast).entries.count, 30)
    }

    func testAmountUsesOriginalUSDPrecisionAndHalfAwayRounding() {
        let cases: [(Double?, String)] = [
            (156, "$1.56"), (0.72, "$0.0072"), (0, "$0.00"),
            (0.009, "<$0.0001"), (0.01, "$0.0001"), (nil, "—"),
            (-1, "—"), (.infinity, "—"), (.nan, "—"),
            (1.5, "$0.02"), (0.995, "$0.0100"), (267.5, "$2.68"),
            (1, "$0.01"), (Double.leastNonzeroMagnitude, "<$0.0001"),
        ]
        for (cents, expected) in cases {
            XCTAssertEqual(RecentUsageFormatter.amount(cents: cents), expected, "\(String(describing: cents))")
        }
    }

    func testCompactTokensRoundsAndPromotesWithoutOverflow() {
        let cases: [(Int?, String)] = [
            (nil, "—"), (-1, "—"), (0, "0"), (1, "1"), (999, "999"),
            (1000, "1K"), (1050, "1.1K"), (999_949, "999.9K"),
            (999_950, "1M"), (1_000_000, "1M"), (1_235_000, "1.24M"),
            (1_200_000, "1.2M"), (1_000_000_000, "1000M"),
            (Int.max, "9223372036854.78M"),
        ]
        for (tokens, expected) in cases {
            XCTAssertEqual(RecentUsageFormatter.tokens(tokens), expected)
        }
    }

    func testEventTimeUsesSelectedZoneForDayAndCurrentYear() {
        let seoul = TimeZone(identifier: "Asia/Seoul")!
        let event = date("2025-12-31T16:00:00Z")
        let now = date("2026-01-01T01:00:00Z")
        XCTAssertEqual(RecentUsageFormatter.eventTime(event, mode: .local, now: now, localTimeZone: seoul), "Jan 1, 01:00")
        XCTAssertEqual(RecentUsageFormatter.eventTime(event, mode: .utc, now: now, localTimeZone: seoul), "Dec 31, 2025, 16:00")
        XCTAssertEqual(RecentUsageFormatter.cachedTime(event, mode: .local, localTimeZone: seoul), "2026-01-01 01:00")
        XCTAssertEqual(RecentUsageFormatter.cachedTime(event, mode: .utc, localTimeZone: seoul), "2025-12-31 16:00")
    }

    func testEventTimeHonorsLosAngelesDST() {
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let now = date("2026-09-24T00:00:00Z")
        XCTAssertEqual(RecentUsageFormatter.eventTime(date("2026-03-08T09:30:00Z"), mode: .local, now: now, localTimeZone: la), "Mar 8, 01:30")
        XCTAssertEqual(RecentUsageFormatter.eventTime(date("2026-03-08T10:30:00Z"), mode: .local, now: now, localTimeZone: la), "Mar 8, 03:30")
    }

    func testZoneHelpersAndStoredDefaults() {
        let seoul = TimeZone(identifier: "Asia/Seoul")!
        XCTAssertEqual(RecentUsageTimeZone(storedValue: nil), .local)
        XCTAssertEqual(RecentUsageTimeZone(storedValue: "unknown"), .local)
        XCTAssertEqual(RecentUsageTimeZone(storedValue: "utc"), .utc)
        XCTAssertEqual(RecentUsageFormatter.zoneLabel(mode: .utc, localTimeZone: seoul), "UTC")
        XCTAssertFalse(RecentUsageFormatter.zoneLabel(mode: .local, localTimeZone: seoul).isEmpty)
        XCTAssertEqual(RecentUsageFormatter.zoneIdentifier(mode: .local, localTimeZone: seoul), "Asia/Seoul")
        XCTAssertEqual(RecentUsageFormatter.zoneIdentifier(mode: .utc, localTimeZone: seoul), "UTC")
        let offset = TimeZone(secondsFromGMT: 20_700)!
        XCTAssertFalse(RecentUsageFormatter.zoneLabel(mode: .local, localTimeZone: offset).isEmpty)
    }
}
