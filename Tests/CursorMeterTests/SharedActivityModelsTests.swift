import XCTest
@testable import CursorMeter

final class SharedActivityModelsTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-19T00:30:00Z")!
    private func decode<T: Decodable>(_ json: String, _ type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testRecentPreservesProductKindAndExactSignedAmountsWithoutPersonalMetadata() throws {
        let response: SharedBillingItemsResponse = try decode(#"{"data":[{"eventTime":"2026-11-19T08:59:00+09:00","billingItemId":"demo-1","product":"cursor","chargeCategory":"usage","usageType":"on_demand","totalTokens":"12345","pricing":{"currency":"USD","contracted":"0.1234567891"},"displayExtras":{"model":"demo-model","userEmail":"unused@example.invalid"}},{"eventTime":"2026-11-18T22:00:00Z","product":"grok-chat","chargeCategory":"credit","usageType":"credits","totalTokens":"0","pricing":{"currency":"USD","contracted":"-10.0000000000"}},{"eventTime":"2026-11-18T21:00:00Z","chargeCategory":"adjustment","usageType":"included","pricing":{"currency":"USD","contracted":"-0.0010000000"}}],"pagination":{"hasMore":true,"nextCursor":"opaque"}}"#)
        let candidate = try response.candidate(start: now.addingTimeInterval(-30 * 86400), end: now)
        XCTAssertEqual(candidate.entries.map(\.kind), [.additionalUsage, .creditGrant, .adjustment])
        XCTAssertEqual(candidate.entries[0].model, "cursor · demo-model")
        XCTAssertEqual(candidate.entries[0].tokens, 12345)
        XCTAssertEqual(candidate.entries[0].exactChargedCents, Decimal(string: "12.34567891"))
        XCTAssertEqual(candidate.entries[1].exactChargedCents, -1000)
        XCTAssertEqual(RecentUsageFormatter.amount(entry: candidate.entries[1]), "−$10.00")
        XCTAssertEqual(RecentUsageFormatter.amount(entry: candidate.entries[2]), "−$0.0010")
        XCTAssertFalse(String(describing: candidate).contains("unused@example.invalid"))
    }

    func testRecentMalformedOptionalValuesRemainUnknownAndInvalidWindowsAreRejected() throws {
        let response: SharedBillingItemsResponse = try decode(#"{"data":[{"eventTime":"2026-11-18T00:00:00Z","chargeCategory":"usage","usageType":"included","totalTokens":"-1","pricing":{"currency":"EUR","contracted":"9"},"displayExtras":{"model":42}}],"pagination":{"hasMore":false}}"#)
        let entry = try XCTUnwrap(response.candidate(start: now.addingTimeInterval(-30 * 86400), end: now).entries.first)
        XCTAssertNil(entry.model)
        XCTAssertNil(entry.tokens)
        XCTAssertNil(entry.exactChargedCents)
        XCTAssertEqual(RecentUsageFormatter.amount(entry: entry), "—")
        XCTAssertThrowsError(try response.candidate(start: now, end: now.addingTimeInterval(1)))
        let unavailable: SharedBillingItemsResponse = try decode(#"{"availability":"identity_unlinked"}"#)
        XCTAssertThrowsError(try unavailable.candidate(start: now.addingTimeInterval(-86400), end: now))
        XCTAssertThrowsError(try decode("{}", SharedBillingItemsResponse.self))
    }

    func testOnlySharedIncludedKnownZeroUsesIncludedAmountLabel() {
        for (kind, cents, expected): (RecentUsageKind, Decimal?, String) in [
            (.included, 0, "Included"), (.included, nil, "—"), (.included, 125, "$1.25"),
            (.additionalUsage, 0, "$0.00"), (.creditGrant, -125, "−$1.25"),
            (.adjustment, Decimal(string: "-0.00000001"), "−<$0.0001"),
            (.included, Decimal(string: "0.00000001"), "<$0.0001"),
        ] {
            let entry = RecentUsageEntry(date: now, model: nil, kind: kind, tokens: nil,
                                         chargedCents: nil, exactChargedCents: cents)
            XCTAssertEqual(RecentUsageFormatter.amount(entry: entry), expected)
        }
        let legacy = RecentUsageEntry(date: now, model: nil, kind: .included, tokens: nil, chargedCents: 0)
        XCTAssertEqual(RecentUsageFormatter.amount(entry: legacy), "$0.00")
    }

    func testRecentNeverStoresDisplayLabelOrPrincipalAsModelContext() throws {
        let response: SharedBillingItemsResponse = try decode(#"{"data":[{"eventTime":"2026-11-18T00:00:00Z","product":"cursor","chargeCategory":"usage","usageType":"included","displayExtras":{"displayLabel":"Synthetic Account Holder","principal":"private@example.invalid"}},{"eventTime":"2026-11-18T00:00:00Z","chargeCategory":"credit","displayExtras":{"displayLabel":"Synthetic Account Holder"}}],"pagination":{"hasMore":false}}"#)
        let candidate = try response.candidate(start: now.addingTimeInterval(-30 * 86400), end: now)
        XCTAssertEqual(candidate.entries[0].model, "cursor")
        XCTAssertNil(candidate.entries[1].model)
        XCTAssertEqual(candidate.entries[1].kind, .creditGrant)
        for value in ["Synthetic Account Holder", "private@example.invalid"] {
            XCTAssertFalse(String(describing: response).contains(value))
            XCTAssertFalse(String(describing: candidate).contains(value))
        }
    }

    func testReportedUSDUsesExactDecimalsForSmallSignedAndLargeValues() throws {
        for usd in ["0.00", "12.30", "0.1234567891", "0.0000000001", "-0.0000000001", "-123.4567890123", "9999999999999.1234567891"] {
            let cents = try XCTUnwrap(SharedActivityValue.cents(usd, signed: true))
            let entry = RecentUsageEntry(date: now, model: nil, kind: .adjustment, tokens: nil,
                                         chargedCents: nil, exactChargedCents: cents)
            let expected = usd.hasPrefix("-") ? "−$" + usd.dropFirst() : "$" + usd
            XCTAssertEqual(RecentUsageFormatter.reportedAmount(entry: entry), "Reported amount: \(expected) USD")
        }
        let unknown = RecentUsageEntry(date: now, model: nil, kind: .included, tokens: nil, chargedCents: nil)
        let legacy = RecentUsageEntry(date: now, model: nil, kind: .included, tokens: nil, chargedCents: 12.34)
        XCTAssertNil(RecentUsageFormatter.reportedAmount(entry: unknown))
        XCTAssertNil(RecentUsageFormatter.reportedAmount(entry: legacy))
    }

    func testDailyRanksDoNotDoubleCountUnionAndUseSevenUTCDateBuckets() throws {
        let response: SharedDailyUsageResponse = try decode(daily(series: [series(type: "included", costRank: 1, tokenRank: 21, cost: "1.25", tokens: 900), series(type: "on_demand", costRank: 21, tokenRank: 1, cost: "8", tokens: 100)], otherCost: "0.01", otherTokens: 5))
        let days = try response.days(start: start, end: now)
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.last?.date, date("2026-11-19T00:00:00Z"))
        XCTAssertEqual(days.last?.amountCents, 126)
        XCTAssertEqual(days.last?.tokens, 105)
        XCTAssertEqual(days.filter(\.isToday).count, 1)
        XCTAssertTrue(days.last?.isToday == true)
        XCTAssertEqual(days.first?.amountCents, 0)
        XCTAssertEqual(days.first?.tokens, 0)
        XCTAssertEqual(days.effectiveMetric(preferred: .tokens), .tokens)
        XCTAssertEqual(WeeklyUsageChartView.tooltipText(for: days.last!, metric: .tokens), "105 tokens")
    }

    func testDailyMissingCostKeepsTokensAndOverflowNeverBecomesZero() throws {
        let unknown: SharedDailyUsageResponse = try decode(daily(series: [series(cost: "bad", tokens: 20)]))
        let unknownDays = try unknown.days(start: start, end: now)
        XCTAssertNil(unknownDays.last?.amountCents)
        XCTAssertEqual(unknownDays.last?.tokens, 20)
        let overflow: SharedDailyUsageResponse = try decode(daily(series: [series(tokens: 9_007_199_254_740_991)], otherTokens: 1))
        XCTAssertNil(try overflow.days(start: start, end: now).last?.tokens)
    }

    func testDailyRejectsUnlinkedDuplicatesMalformedDatesAndOutOfWindowBuckets() throws {
        let unavailable: SharedDailyUsageResponse = try decode(#"{"availability":"identity_unlinked"}"#)
        XCTAssertThrowsError(try unavailable.days(start: start, end: now))
        for day in ["2026-11-19T00:00:01Z", "2026-11-12T00:00:00Z", "invalid"] {
            let response: SharedDailyUsageResponse = try decode(daily(series: [series(day: day)]))
            XCTAssertThrowsError(try response.days(start: start, end: now))
        }
        let duplicate: SharedDailyUsageResponse = try decode(daily(series: [series(), series()]))
        XCTAssertThrowsError(try duplicate.days(start: start, end: now))
        let mismatched: SharedDailyUsageResponse = try decode(daily(series: []).replacingOccurrences(of: "2026-11-13T00:00:00Z", with: "2026-11-14T00:00:00Z"))
        XCTAssertThrowsError(try mismatched.days(start: start, end: now))
    }

    func testMissingRootCostTotalPreservesKnownTokens() throws {
        let days = try daysRemovingRootTotal("totalContractedCost")
        XCTAssertTrue(days.allSatisfy { $0.amountCents == nil })
        XCTAssertEqual(days.last?.tokens, 10)
    }

    func testMissingRootTokenTotalPreservesKnownAmount() throws {
        let days = try daysRemovingRootTotal("totalTokens")
        XCTAssertTrue(days.allSatisfy { $0.tokens == nil })
        XCTAssertEqual(days.last?.amountCents, 100)
    }

    func testMissingRootIncludedTokenTotalPreservesKnownAmount() throws {
        let days = try daysRemovingRootTotal("totalIncludedTokens")
        XCTAssertTrue(days.allSatisfy { $0.tokens == nil })
        XCTAssertEqual(days.last?.amountCents, 100)
    }

    private func daysRemovingRootTotal(_ key: String) throws -> [DayUsage] {
        var object = try JSONSerialization.jsonObject(with: Data(daily(series: [series()]).utf8)) as! [String: Any]
        object.removeValue(forKey: key)
        let response = try JSONDecoder().decode(SharedDailyUsageResponse.self, from: JSONSerialization.data(withJSONObject: object))
        return try response.days(start: start, end: now)
    }

    func testDailyMalformedAggregatesCannotFabricateKnownZero() throws {
        let missing = daily(series: []).replacingOccurrences(of: "\"totalContractedCost\":\"0\",", with: "")
        let missingDays = try decode(missing, SharedDailyUsageResponse.self).days(start: start, end: now)
        XCTAssertTrue(missingDays.allSatisfy { $0.amountCents == nil && $0.tokens == 0 })
        let inconsistent: SharedDailyUsageResponse = try decode(daily(series: [series()]).replacingOccurrences(of: "\"totalTokens\":10", with: "\"totalTokens\":-1"))
        let days = try inconsistent.days(start: start, end: now)
        XCTAssertTrue(days.allSatisfy { $0.tokens == nil })
        let incomplete: SharedDailyUsageResponse = try decode(daily(series: []).replacingOccurrences(of: "\"totalTokens\":0", with: "\"totalTokens\":20"))
        XCTAssertTrue(try incomplete.days(start: start, end: now).allSatisfy { $0.tokens == nil })
    }

    func testExpiredPaidResetAndUnavailableTokensRemainExplicit() throws {
        let response: SharedUsageStatusResponse = try decode(#"{"availability":"available","monthlyUsage":{"periodStart":"2026-11-01T00:00:00Z","resetsAt":"2026-12-01T00:00:00Z"}}"#)
        let period = try XCTUnwrap(response.paidPeriod(at: now))
        let reading = SharedUsageReading<SharedPaidPeriod>.empty.received(period, at: now)
        let current = SharedUsagePresentation(mode: .sharedWeekly, snapshot: nil, paidReset: reading, at: now)
        XCTAssertTrue(current.detailLines.joined().contains("Paid resets"))
        XCTAssertFalse(current.detailLines.joined().contains("(stale)"))
        let expired = SharedUsagePresentation(mode: .sharedWeekly, snapshot: nil, paidReset: reading, at: period.end)
        XCTAssertTrue(expired.detailLines.joined().contains("(stale)"))
        let days = try decode(daily(series: [series(tokens: -1)]), SharedDailyUsageResponse.self).days(start: start, end: now)
        XCTAssertEqual(WeeklyUsageChartView.tooltipText(for: days.last!, metric: .tokens), "Tokens unavailable")
    }

    func testRootTotalsMustReconcileIndependentlyWithRankedSeriesAndOther() throws {
        let raw = daily(series: [series()])
        for key in ["totalContractedCost", "totalTokens"] {
            var object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as! [String: Any]
            object[key] = key == "totalTokens" ? 99 : "9"
            let response = try JSONDecoder().decode(SharedDailyUsageResponse.self, from: JSONSerialization.data(withJSONObject: object))
            let days = try response.days(start: start, end: now)
            if key == "totalTokens" {
                XCTAssertTrue(days.allSatisfy { $0.tokens == nil })
                XCTAssertEqual(days.last?.amountCents, 100)
            } else {
                XCTAssertTrue(days.allSatisfy { $0.amountCents == nil })
                XCTAssertEqual(days.last?.tokens, 10)
            }
        }
    }

    func testPaidResetRequiresCurrentCoherentServerPeriod() throws {
        let response: SharedUsageStatusResponse = try decode(#"{"availability":"available","monthlyUsage":{"usedCents":12,"limitCents":null,"creditsUsedCents":5,"periodStart":"2026-11-01T09:00:00+09:00","resetsAt":"2026-12-01T09:00:00+09:00"}}"#)
        XCTAssertEqual(response.paidPeriod(at: now)?.end, date("2026-12-01T00:00:00Z"))
        XCTAssertNil(response.paidPeriod(at: date("2026-12-01T00:00:00Z")))
        let unavailable: SharedUsageStatusResponse = try decode(#"{"availability":"identity_unlinked"}"#)
        XCTAssertNil(unavailable.paidPeriod(at: now))
    }

    private var start: Date { date("2026-11-13T00:00:00Z") }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private func series(type: String = "included", costRank: Int = 1, tokenRank: Int = 1, cost: String = "1", tokens: Int = 10, day: String = "2026-11-19T00:00:00Z") -> String {
        "{\"dimensions\":{\"usageType\":\"\(type)\"},\"costRank\":\(costRank),\"tokenRank\":\(tokenRank),\"totalContractedCost\":\"\(cost)\",\"totalTokens\":\(tokens),\"totalIncludedTokens\":0,\"points\":[{\"dayStartTime\":\"\(day)\",\"contractedCost\":\"\(cost)\",\"tokens\":\(tokens),\"includedTokens\":0}]}"
    }
    private func daily(series: [String], otherCost: String = "0", otherTokens: Int = 0) -> String {
        let objects = series.map { try! JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        var totalCost = Decimal(string: otherCost) ?? 0
        var totalTokens = otherTokens
        for object in objects {
            if (object["costRank"] as! Int) <= 20 { totalCost += Decimal(string: object["totalContractedCost"] as! String) ?? 0 }
            if (object["tokenRank"] as! Int) <= 20 { totalTokens += object["totalTokens"] as! Int }
        }
        return "{\"startTime\":\"2026-11-13T00:00:00Z\",\"endTime\":\"2026-11-19T00:30:00Z\",\"totalContractedCost\":\"\(totalCost)\",\"totalTokens\":\(totalTokens),\"totalIncludedTokens\":0,\"series\":[\(series.joined(separator: ","))],\"other\":{\"totalContractedCost\":\"\(otherCost)\",\"totalTokens\":\(otherTokens),\"totalIncludedTokens\":0,\"points\":[{\"dayStartTime\":\"2026-11-19T00:00:00Z\",\"contractedCost\":\"\(otherCost)\",\"tokens\":\(otherTokens),\"includedTokens\":0}]}}"
    }
}
