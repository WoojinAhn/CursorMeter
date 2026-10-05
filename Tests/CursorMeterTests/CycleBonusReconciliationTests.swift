import XCTest
@testable import CursorMeter

final class CycleBonusReconciliationTests: XCTestCase, @unchecked Sendable {
    private let instant = UsageCycle.parse("2026-10-06T03:00:00Z")!
    private let cycle = UsageCycle(start: "2026-10-01T00:00:00Z", end: "2026-11-01T00:00:00Z")!

    func testCappedBonusCostsReconcileAndAllocateToday() async throws {
        let summary = try summary()
        let period = try period()
        let result = await collect(summary: summary, period: period)

        XCTAssertEqual(result.status, .complete)
        let amounts = try XCTUnwrap(result.snapshot)
        XCTAssertEqual(amounts.status, .estimatedAttribution)
        XCTAssertEqual(amounts.cursorCents, 100)
        XCTAssertEqual(amounts.otherCents, Decimal(string: "5.5"))
        XCTAssertEqual(amounts.botCents, 7)
        XCTAssertEqual(amounts.residualCents, Decimal(string: "0.5"))
        let today = try XCTUnwrap(TodayUsageAllocation.percentagePoints(
            snapshot: snapshot(), amounts: amounts, primaryIsStale: false,
            currentSessionAndDemandEligible: true, now: instant))
        XCTAssertEqual(today[.cursor], 10)
        XCTAssertEqual(today[.other], 20)
        XCTAssertEqual(amounts.todayUsage?.sourceIncludedTotalCents, 100)
    }

    func testPeriodEpochMillisecondsMatchesSummaryCycle() throws {
        XCTAssertEqual(try period().cycle, cycle)
        XCTAssertTrue(try period().isCoherent(with: summary()))
    }

    func testPeriodDatesAcceptISOAndOnlyWholeEpochMilliseconds() throws {
        XCTAssertEqual(try period(start: "2026-10-01T00:00:00Z", end: "2026-11-01T00:00:00Z").cycle, cycle)
        let milliseconds = String(Int(cycle.start.timeIntervalSince1970 * 1000))
        for invalid in [milliseconds + "suffix", milliseconds + ".5", " " + milliseconds, "-" + milliseconds,
                        "1.8e12", "NaN", "Infinity", "99999999999999999999", String(Int(cycle.start.timeIntervalSince1970))] {
            XCTAssertNil(try period(start: invalid).cycle, invalid)
        }
        XCTAssertNil(UsageCycle(start: milliseconds, end: String(Int(cycle.end.timeIntervalSince1970 * 1000))),
                     "The primary ISO date contract must not change")
    }

    func testBonusAuthorityRequiresCappedMatchingAndCompleteBreakdown() throws {
        let summary = try summary()
        for invalid in [try period(included: "98"), try period(total: "108"), try period(total: "null"),
                        try period(total: "-1"), try period(bonus: "null"), try period(bonus: "0"),
                        try period(bonus: "-1"), try period(limit: "null"), try period(limit: "101"),
                        try period(cursor: "11"), try period(other: "21"),
                        try period(included: "101", total: "100.5", bonus: "0.1"),
                        try period(start: "2026-10-02T00:00:00Z")] {
            XCTAssertNil(invalid.bonusReconciliation(with: summary))
        }
        XCTAssertNil(try period(included: "90", total: "95").bonusReconciliation(with: self.summary(used: 90)))
        let totalOnly = try period(included: "null", bonus: "null")
        XCTAssertNil(totalOnly.bonusReconciliation(with: summary))
        XCTAssertFalse(totalOnly.isCoherent(with: summary))
    }

    func testRoundedPeriodIncludedAmountKeepsExactPrimaryBinding() throws {
        let evidence = try XCTUnwrap(period(included: "100.75", bonus: "4.25").bonusReconciliation(with: summary()))
        XCTAssertEqual(evidence.sourceIncludedCents, 100)
        XCTAssertEqual(evidence.totalCents, 105)
    }

    func testBelowCapContinuesReconcilingAgainstPrimarySummary() async throws {
        let result = try await collect(summary: summary(used: 90), period: period(included: "90", total: "500", bonus: "410"),
                                   cursorCost: 85, otherCost: Decimal(string: "5.5")!)
        XCTAssertEqual(result.status, .complete)
        XCTAssertNil(result.snapshot?.bonusReconciliation)
        XCTAssertEqual(result.snapshot?.residualCents, Decimal(string: "0.5"))
    }

    func testBonusAndLimitChangesInvalidatePeriodFingerprint() throws {
        let original = try period()
        for changed in [try period(total: "106"), try period(bonus: "6"), try period(limit: "101")] {
            XCTAssertNotEqual(CycleUsageCollector.periodFingerprint(original), CycleUsageCollector.periodFingerprint(changed))
        }
    }

    func testChangingBonusAuthorityDuringTraversalRejectsReceipt() async throws {
        let summary = try summary()
        let first = try period()
        for changed in [try period(total: "106"), try period(bonus: "6"), try period(limit: "101")] {
            let sequence = BonusPeriodSequence([first, changed])
            let page = historyPage()
            var collector = CycleUsageCollector(fetchPage: { _, _ in page }, fetchSummary: { summary }, fetchPeriod: {
                await sequence.next()
            })
            collector.now = { self.instant }
            let result = await collector.collect(snapshot: snapshot(), summary: summary)
            XCTAssertEqual(result.status, .unstable)
            XCTAssertNil(result.snapshot)
        }
    }

    func testBonusReconciliationDoesNotAcceptUnaccountedIncludedCosts() async throws {
        let result = try await collect(summary: summary(), period: period(), otherCost: 7)
        XCTAssertEqual(result.status, .unstable)
        XCTAssertNil(result.snapshot)
    }

    func testBonusReceiptRoundTripsAndMissingEvidenceUsesLegacyRules() async throws {
        let result = try await collect(summary: summary(), period: period())
        let amounts = try XCTUnwrap(result.snapshot)
        let encoded = try JSONEncoder().encode(amounts)
        let decoded = try JSONDecoder().decode(CycleAmountSnapshot.self, from: encoded)
        XCTAssertEqual(decoded.bonusReconciliation, amounts.bonusReconciliation)
        XCTAssertNotNil(allocate(decoded))
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "bonusReconciliation")
        let restored = try JSONDecoder().decode(CycleAmountSnapshot.self, from: JSONSerialization.data(withJSONObject: legacy))
        XCTAssertNil(restored.bonusReconciliation)
        XCTAssertNil(allocate(restored), "Older receipts cannot invent bonus authority")
    }

    func testMalformedAndMismatchedBonusEvidenceFailsClosed() async throws {
        let result = try await collect(summary: summary(), period: period())
        let original = try XCTUnwrap(result.snapshot)
        for evidence in [CycleBonusReconciliation(sourceIncludedCents: 101, totalCents: 105),
                         .init(sourceIncludedCents: -1, totalCents: 105),
                         .init(sourceIncludedCents: 100, totalCents: 99),
                         .init(sourceIncludedCents: 100, totalCents: .nan)] {
            var invalid = original
            invalid.bonusReconciliation = evidence
            XCTAssertNil(allocate(invalid))
            if !evidence.totalCents.isNaN {
                let decoded = try JSONDecoder().decode(CycleAmountSnapshot.self, from: JSONEncoder().encode(invalid))
                XCTAssertNil(decoded.todayUsage)
                XCTAssertNil(allocate(decoded))
            }
        }
        var malformed = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any])
        malformed["bonusReconciliation"] = "invalid"
        XCTAssertThrowsError(try JSONDecoder().decode(CycleAmountSnapshot.self, from: JSONSerialization.data(withJSONObject: malformed)))
    }

    func testBonusEvidenceKeepsFreshnessAndAttributionGuards() async throws {
        let result = try await collect(summary: summary(), period: period())
        let original = try XCTUnwrap(result.snapshot)
        let changes: [(inout CycleAmountSnapshot) -> Void] = [
            { $0.coverage.complete = false }, { $0.status = .unavailable }, { $0.isCached = true },
            { $0.unknownCount = 1 }, { $0.unknownCents = 1 }, { $0.sourceCursorPercent = 11 },
            { $0.sourceOtherPercent = 21 }, { $0.residualCents = 2 },
            { $0.todayUsage = .init(day: $0.todayUsage!.day, evidenceAt: $0.todayUsage!.evidenceAt,
                                   cursorCents: 100, otherCents: 5, sourceIncludedTotalCents: 101) }
        ]
        for change in changes {
            var invalid = original
            change(&invalid)
            XCTAssertNil(allocate(invalid))
        }
        XCTAssertNil(allocate(original, primary: snapshot(used: 101)))
        var cappedPool = snapshot()
        cappedPool.cursorPercent = 100
        var amounts = original
        amounts.sourceCursorPercent = 100
        XCTAssertNil(allocate(amounts, primary: cappedPool))
    }

    private func allocate(_ amounts: CycleAmountSnapshot, primary: SplitUsageSnapshot? = nil) -> [UsagePoolID: Double]? {
        TodayUsageAllocation.percentagePoints(snapshot: primary ?? snapshot(), amounts: amounts,
            primaryIsStale: false, currentSessionAndDemandEligible: true, now: instant)
    }

    private func collect(summary: UsageSummaryResponse, period: CurrentPeriodUsageResponse,
                         cursorCost: Decimal = 100, otherCost: Decimal = Decimal(string: "5.5")!) async -> CycleCollectionResult {
        let page = historyPage(cursorCost: cursorCost, otherCost: otherCost)
        var collector = CycleUsageCollector(fetchPage: { _, _ in page }, fetchSummary: { summary }, fetchPeriod: { period })
        collector.now = { self.instant }
        return await collector.collect(snapshot: snapshot(used: Decimal(summary.individualUsage!.plan!.used!)), summary: summary)
    }

    private func historyPage(cursorCost: Decimal = 100, otherCost: Decimal = Decimal(string: "5.5")!) -> CycleHistoryPage {
        let rows = [
            CycleUsageEvent(timestamp: String(Int(instant.timeIntervalSince1970 * 1000)), model: "composer-2.5",
                            kind: "USAGE_EVENT_KIND_INCLUDED_IN_ULTRA", chargedCents: cursorCost),
            CycleUsageEvent(timestamp: String(Int(instant.timeIntervalSince1970 * 1000) - 1), model: "other-model",
                            kind: "USAGE_EVENT_KIND_INCLUDED_IN_ULTRA", chargedCents: otherCost),
            CycleUsageEvent(timestamp: String(Int(instant.timeIntervalSince1970 * 1000) - 2), model: "grok-bot-4.7",
                            kind: "USAGE_EVENT_KIND_INCLUDED_IN_ULTRA", chargedCents: 7)
        ]
        return CycleHistoryPage(page: .init(events: rows, total: rows.count, hasEvents: true), byteCount: 100)
    }

    private func snapshot(used: Decimal = 100) -> SplitUsageSnapshot {
        .init(identity: .init(localID: 1, credentialGeneration: 1, accountDigest: "account", scopeDigest: "personal",
                              cycle: cycle, planIdentity: "ultra:100"), capturedAt: instant,
              cursorPercent: 10, otherPercent: 20, includedUsedCents: used)
    }

    private func summary(used: Int = 100) throws -> UsageSummaryResponse {
        try JSONDecoder().decode(UsageSummaryResponse.self, from: Data(#"{"billingCycleStart":"2026-10-01T00:00:00Z","billingCycleEnd":"2026-11-01T00:00:00Z","membershipType":"ultra","individualUsage":{"plan":{"used":\#(used),"limit":100,"autoPercentUsed":10,"apiPercentUsed":20}}}"#.utf8))
    }

    private func period(included: String = "100", total: String = "105", bonus: String = "5", limit: String = "100",
                        cursor: String = "10", other: String = "20", start: String? = nil, end: String? = nil) throws -> CurrentPeriodUsageResponse {
        let start = start ?? String(Int(cycle.start.timeIntervalSince1970 * 1000))
        let end = end ?? String(Int(cycle.end.timeIntervalSince1970 * 1000))
        return try JSONDecoder().decode(CurrentPeriodUsageResponse.self, from: Data(#"{"billingCycleStart":"\#(start)","billingCycleEnd":"\#(end)","planUsage":{"includedSpend":\#(included),"totalSpend":\#(total),"bonusSpend":\#(bonus),"limit":\#(limit),"autoPercentUsed":\#(cursor),"apiPercentUsed":\#(other)},"autoBucketModels":["composer-2.5"]}"#.utf8))
    }
}

private actor BonusPeriodSequence {
    let responses: [CurrentPeriodUsageResponse]
    var index = 0
    init(_ responses: [CurrentPeriodUsageResponse]) { self.responses = responses }
    func next() -> CurrentPeriodUsageResponse {
        defer { index += 1 }
        return responses[index % responses.count]
    }
}
