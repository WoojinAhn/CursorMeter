import XCTest
@testable import CursorMeter

final class CycleUsageSupplementTests: XCTestCase, @unchecked Sendable {
    func testOptionalPeriodFailureStillCollectsFallbackAmountsWithoutCap() async throws {
        let collector = makeCollector(fetchPeriod: { throw CycleEnrichmentError.http(status: 401, retryAfter: nil) })
        let result = await collector.collect(snapshot: snapshot(), summary: summary())
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.snapshot?.cursorCents, 1)
        XCTAssertEqual(result.snapshot?.status, .estimatedAttribution)
        XCTAssertNil(result.snapshot?.estimatedCursorLimitCents)
    }
    func testEmptyOrBlankModelListNeverEnablesEstimates() async throws {
        for models in ["[]", "[\"\"]", "[\" \"]"] {
            let collector = makeCollector(fetchPeriod: { try self.period(models: models) })
            let result = await collector.collect(snapshot: snapshot(), summary: summary())
            XCTAssertEqual(result.status, .complete)
            XCTAssertEqual(result.snapshot?.cursorCents, 1)
            XCTAssertNil(result.snapshot?.estimatedCursorLimitCents)
        }
    }
    func testCanonicalSummaryIdentityIgnoresCaseAndOuterWhitespace() throws {
        let other = try JSONDecoder().decode(UsageSummaryResponse.self, from: Data(#"{"billingCycleStart":"1970-01-01T00:00:01.000Z","billingCycleEnd":"1970-01-01T00:00:10.000Z","membershipType":" PRO ","limitType":" NONE ","individualUsage":{"plan":{"used":1,"limit":100,"autoPercentUsed":10,"apiPercentUsed":10}}}"#.utf8))
        XCTAssertEqual(CycleUsageCollector.summaryFingerprint(summary()), CycleUsageCollector.summaryFingerprint(other))
    }
    func testSupplementUsesOnlyPrecisionHistoryOfItsOwnSource() throws {
        var raw = snapshot(missingOther: true)
        raw.cursorObservedPlaces = 0
        raw.otherObservedPlaces = 3
        raw.periodCursorObservedPlaces = 3
        raw.periodOtherObservedPlaces = 0
        let date = Date(timeIntervalSince1970: 7)
        let resolved = raw.supplemented(by: try period(otherPercent: "1"), summary: summary(missingOther: true), at: date)
        XCTAssertEqual(resolved.cursorPercent, 10)
        XCTAssertEqual(resolved.cursorSource, .summary)
        XCTAssertEqual(resolved.cursorObservedPlaces, 0, "Period precision must not upgrade primary precision")
        XCTAssertEqual(resolved.otherSource, .period)
        XCTAssertEqual(resolved.otherObservedPlaces, 0, "Primary history must not upgrade period precision")
        XCTAssertEqual(resolved.periodCapturedAt, date)
        XCTAssertEqual(resolved.capturedAt, raw.capturedAt)
        raw.periodOtherObservedPlaces = 2
        let historical = raw.supplemented(by: try period(otherPercent: "1"), summary: summary(missingOther: true), at: date)
        XCTAssertEqual(historical.otherObservedPlaces, 2)
        XCTAssertEqual(raw.supplemented(by: nil, summary: summary(missingOther: true), at: date), raw)
    }
    func testPeriodSourceIsSetOnlyForActualMissingMeasurement() throws {
        let raw = snapshot()
        let resolved = raw.supplemented(by: try period(), summary: summary(), at: Date())
        XCTAssertEqual(resolved.cursorSource, .summary)
        XCTAssertEqual(resolved.otherSource, .summary)
        XCTAssertNil(resolved.periodCapturedAt)
        XCTAssertEqual(resolved.cursorPercent, raw.cursorPercent)
        XCTAssertEqual(resolved.otherPercent, raw.otherPercent)
    }
    func testSupplementArrivesBeforeHeldHistoryAndSurvivesHistoryFailure() async throws {
        let record = SupplementRecord()
        let history = SupplementHistoryGate()
        let received = expectation(description: "Early supplement")
        let collector = CycleUsageCollector(fetchPage: { _, _ in
            await history.wait()
            throw CycleEnrichmentError.transport
        }, fetchSummary: { self.summary(missingOther: true) }, fetchPeriod: { try self.period() }, onSupplement: { value in
            await record.set(value)
            received.fulfill()
        })
        let task = Task { await collector.collect(snapshot: self.snapshot(missingOther: true), summary: self.summary(missingOther: true)) }
        await fulfillment(of: [received], timeout: 1)
        let early = await record.value
        XCTAssertEqual(early?.otherPercent, 20)
        XCTAssertEqual(early?.otherSource, .period)
        await history.release()
        let result = await task.value
        XCTAssertEqual(result.status, .transportFailure)
        XCTAssertNil(result.snapshot)
    }
    func testOptionalPeriodFailureAllowsCurrentAttemptPartialAmounts() async throws {
        let collector = CycleUsageCollector(budget: .init(maxPages: 1), fetchPage: { _, _ in self.page() }, fetchSummary: { self.summary() }, fetchPeriod: { throw CycleEnrichmentError.transport })
        let result = await collector.collect(snapshot: snapshot(), summary: summary())
        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.snapshot?.cursorCents, 1)
        XCTAssertEqual(result.snapshot?.coverage.complete, false)
        XCTAssertNil(result.snapshot?.estimatedCursorLimitCents)
    }
    func testPeriod429CancellationAndBudgetAreNeverSwallowed() async throws {
        let rate = makeCollector(fetchPeriod: { throw CycleEnrichmentError.http(status: 429, retryAfter: 120) })
        let rateResult = await rate.collect(snapshot: snapshot(), summary: summary())
        XCTAssertEqual(rateResult.status, .rateLimited(retryAfter: 120))
        XCTAssertEqual(rateResult.pageCount, 0)
        let cancelled = makeCollector(fetchPeriod: { throw CancellationError() })
        let cancelledResult = await cancelled.collect(snapshot: snapshot(), summary: summary())
        XCTAssertEqual(cancelledResult.status, .cancelled)
        let budget = makeCollector(fetchPeriod: { throw CycleEnrichmentError.payloadBudget })
        let budgetResult = await budget.collect(snapshot: snapshot(), summary: summary())
        XCTAssertEqual(budgetResult.status, .partial)
        XCTAssertEqual(budgetResult.pageCount, 0)
    }
    func testChangingPeriodAvailabilityInvalidatesAttribution() async throws {
        let sequence = SupplementSequence()
        let collector = makeCollector(fetchPeriod: {
            if await sequence.next().isMultiple(of: 2) { throw CycleEnrichmentError.transport }
            return try self.period()
        })
        let result = await collector.collect(snapshot: snapshot(), summary: summary())
        XCTAssertEqual(result.status, .unstable)
        XCTAssertNil(result.snapshot)
        XCTAssertEqual(result.pageCount, 2)
    }
    func testPrimaryPrecisionCannotFabricatePeriodBasedCap() async throws {
        var raw = snapshot(missingOther: true)
        raw.otherObservedPlaces = 3
        let collector = CycleUsageCollector(fetchPage: { _, _ in self.page(model: "gpt-4.1") }, fetchSummary: { self.summary(missingOther: true) }, fetchPeriod: { try self.period(otherPercent: "1") })
        let result = await collector.collect(snapshot: raw, summary: summary(missingOther: true))
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.snapshot?.otherCents, 1)
        XCTAssertEqual(result.snapshot?.otherObservedPlaces, 0)
        XCTAssertNil(result.snapshot?.estimatedOtherLimitCents)
    }
    func testIncoherentPeriodDoesNotSupplementSnapshot() throws {
        let invalid = try JSONDecoder().decode(CurrentPeriodUsageResponse.self, from: Data(#"{"billingCycleStart":"1970-01-01T00:00:01Z","billingCycleEnd":"1970-01-01T00:00:11Z","planUsage":{"includedSpend":1,"apiPercentUsed":20}}"#.utf8))
        let raw = snapshot(missingOther: true)
        XCTAssertEqual(raw.supplemented(by: invalid, summary: summary(missingOther: true), at: Date()), raw)
    }
    func makeCollector(fetchPeriod: @escaping @Sendable () async throws -> CurrentPeriodUsageResponse) -> CycleUsageCollector {
        CycleUsageCollector(fetchPage: { _, _ in self.page() }, fetchSummary: { self.summary() }, fetchPeriod: fetchPeriod)
    }
    func page(model: String = "composer-2.5") -> CycleHistoryPage {
        .init(page: .init(events: [.init(timestamp: "2000", model: model, kind: "USAGE_EVENT_KIND_INCLUDED_IN_ULTRA", chargedCents: 1)], total: 1, hasEvents: true), byteCount: 100)
    }
    func summary(missingOther: Bool = false) -> UsageSummaryResponse {
        try! JSONDecoder().decode(UsageSummaryResponse.self, from: Data("{\"billingCycleStart\":\"1970-01-01T00:00:01Z\",\"billingCycleEnd\":\"1970-01-01T00:00:10Z\",\"membershipType\":\"pro\",\"limitType\":\"none\",\"individualUsage\":{\"plan\":{\"used\":1,\"limit\":100,\"autoPercentUsed\":10\(missingOther ? "" : ",\"apiPercentUsed\":10")}}}".utf8))
    }
    func snapshot(missingOther: Bool = false) -> SplitUsageSnapshot {
        .init(identity: .init(localID: 1, credentialGeneration: 1, accountDigest: "a", scopeDigest: "s", cycle: .init(start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 10)), planIdentity: "pro:100"), capturedAt: Date(timeIntervalSince1970: 5), cursorPercent: 10, otherPercent: missingOther ? nil : 10, includedUsedCents: 1)
    }
    func period(models: String = "[\"composer-2.5\"]", otherPercent: String = "20") throws -> CurrentPeriodUsageResponse {
        try JSONDecoder().decode(CurrentPeriodUsageResponse.self, from: Data("{\"billingCycleStart\":\"1970-01-01T00:00:01Z\",\"billingCycleEnd\":\"1970-01-01T00:00:10Z\",\"planUsage\":{\"includedSpend\":1,\"autoPercentUsed\":99.123,\"apiPercentUsed\":\(otherPercent)},\"autoBucketModels\":\(models)}".utf8))
    }
}

private actor SupplementRecord {
    var value: SplitUsageSnapshot?
    func set(_ value: SplitUsageSnapshot) { self.value = value }
}
private actor SupplementHistoryGate {
    var released = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}

private actor SupplementSequence {
    var value = 0
    func next() -> Int { value += 1; return value }
}
