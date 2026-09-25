import XCTest
@testable import CursorMeter

final class CycleUsageCollectorTests: XCTestCase, @unchecked Sendable {
    func testExactDecimalAndClassification() throws {
        let page = try JSONDecoder().decode(CycleUsagePage.self, from: Data(#"{"usageEventsDisplay":[{"timestamp":"2000","model":"composer-2.5","kind":"USAGE_EVENT_KIND_INCLUDED_IN_ULTRA","chargedCents":0.123456789123456789}]}"#.utf8))
        XCTAssertEqual(page.events[0].chargedCents, Decimal(string: "0.123456789123456789"))
        XCTAssertEqual(CycleModelClassifier.classify(" grok-bot-4.7 ", serverModels: ["grok-bot-4.7"]).family, .bot)
        for name in ["composer-2.5", "grok-4.5", "cursor-grok-4.6-fast", "grok-4.7"] {
            XCTAssertEqual(CycleModelClassifier.classify(name, serverModels: nil).family, .cursor)
        }
        for name in ["composer-3", "grok-4.8", "not-cursor-grok-4.7", "gpt-", "claude"] {
            XCTAssertEqual(CycleModelClassifier.classify(name, serverModels: nil).family, .unknown)
        }
    }
    func testShortPageDoesNotProveCoverage() async throws {
        let pages = PageFeed([page([event("2000", "1")]), page([], total: nil)])
        let result = await collector(pages).collect(snapshot: snapshot(used: 1), summary: summary(used: 1))
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.pageCount, 3)
        XCTAssertEqual(result.snapshot?.cursorCents, 1)
    }
    func testWithinPageIdenticalRowsCountSeparately() async throws {
        let pages = PageFeed([page([event("2000", "1"), event("2000", "1")], total: 2)])
        let result = await collector(pages).collect(snapshot: snapshot(used: 2), summary: summary(used: 2))
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.snapshot?.cursorCents, 2)
    }
    func testCrossPageOverlapIsUnstable() async throws {
        let pages = PageFeed([page([event("2000", "1")]), page([event("2000", "1")])])
        let result = await collector(pages).collect(snapshot: snapshot(used: 2), summary: summary(used: 2))
        XCTAssertEqual(result.status, .unstable)
    }
    func testBudgetIsPartialAndRechecksConsumePages() async throws {
        let pages = PageFeed([page([event("2000", "1")], total: 1)])
        let result = await collector(pages, maxPages: 1).collect(snapshot: snapshot(used: 1), summary: summary(used: 1))
        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.pageCount, 1)
    }
    func testMissingArrayBelowTotalIsNotComplete() async throws {
        let missing = try JSONDecoder().decode(CycleUsagePage.self, from: Data(#"{"totalUsageEventsCount":10}"#.utf8))
        let pages = PageFeed([CycleHistoryPage(page: missing, byteCount: 32)])
        let result = await collector(pages).collect(snapshot: snapshot(used: 0), summary: summary(used: 0))
        XCTAssertEqual(result.status, .unstable)
    }
    func testOneCentToleranceAndPrecisionPolicy() async throws {
        let pages = PageFeed([page([event("2000", "99.25")], total: 1)])
        let result = await collector(pages).collect(snapshot: snapshot(used: 100), summary: summary(used: 100))
        XCTAssertEqual(result.snapshot?.residualCents, Decimal(string: "-0.75"))
        XCTAssertEqual(result.snapshot?.estimatedCursorLimitCents, Decimal(string: "992.5"))
    }
    func testContradictoryChargeabilityWithholdsLimits() async throws {
        var row = event("2000", "1"); row.isChargeable = false
        let result = await collector(PageFeed([page([row], total: 1)])).collect(snapshot: snapshot(used: 1), summary: summary(used: 1))
        XCTAssertNil(result.snapshot?.estimatedCursorLimitCents)
        XCTAssertEqual(result.snapshot?.status, .unavailable)
    }
    func testOlderBoundaryCompletesEvenWhenTotalIncludesOldHistory() async throws {
        let pages = PageFeed([page([event("2000", "1"), event("500", "10")], total: 900)])
        let result = await collector(pages).collect(snapshot: snapshot(used: 1), summary: summary(used: 1))
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.snapshot?.cursorCents, 1)
    }
    func testSnapshotPercentMustBelongToSuppliedSummary() async throws {
        var wrong = snapshot(used: 1); wrong.cursorPercent = 50
        let result = await collector(PageFeed([page([event("2000", "1")], total: 1)])).collect(snapshot: wrong, summary: summary(used: 1))
        XCTAssertEqual(result.status, .unstable)
        XCTAssertNil(result.snapshot?.estimatedCursorLimitCents)
    }
    func testPrecisionPolicyDoesNotInventSmallDenominators() {
        XCTAssertNil(CycleUsageCollector.estimate(amount: 100, percent: 1, places: 0))
        XCTAssertNil(CycleUsageCollector.estimate(amount: 100, percent: 3, places: 0))
        XCTAssertEqual(CycleUsageCollector.estimate(amount: 100, percent: 10, places: 0), 1000)
        XCTAssertNotNil(CycleUsageCollector.estimate(amount: 1, percent: 0.1, places: 3))
        XCTAssertNil(CycleUsageCollector.estimate(amount: 1, percent: 100, places: 3))
        XCTAssertNil(CycleUsageCollector.estimate(amount: 1, percent: 0.099, places: 3))
    }
    func testUnknownPaidBotAndCustomKindsStaySeparate() async throws {
        let rows = [
            event("9000", "1"),
            CycleUsageEvent(timestamp: "8000", model: "grok-bot-4.7", kind: "USAGE_EVENT_KIND_INCLUDED_IN_ULTRA", chargedCents: 3),
            CycleUsageEvent(timestamp: "7000", model: "claude-sonnet", kind: "USAGE_EVENT_KIND_USAGE_BASED", chargedCents: 4),
            CycleUsageEvent(timestamp: "6000", model: "unknown", kind: "USAGE_EVENT_KIND_INCLUDED_IN_ULTRA", chargedCents: 5),
            CycleUsageEvent(timestamp: "5000", model: "composer-2.5", kind: "USAGE_EVENT_KIND_CUSTOM_SUBSCRIPTION", chargedCents: 6)
        ]
        let collector = CycleUsageCollector(fetchPage: { _, _ in self.page(rows, total: 5) }, fetchSummary: { self.summary(used: 6) }, fetchPeriod: { try self.period() })
        let result = await collector.collect(snapshot: snapshot(used: 6), summary: summary(used: 6))
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.snapshot?.status, .unavailable)
        XCTAssertEqual(result.snapshot?.cursorCents, 1)
        XCTAssertEqual(result.snapshot?.botCents, 3)
        XCTAssertEqual(result.snapshot?.paidCents, 4)
        XCTAssertEqual(result.snapshot?.unknownCents, 11)
        XCTAssertEqual(result.snapshot?.unknownCount, 2)
        XCTAssertNil(result.snapshot?.estimatedCursorLimitCents)
    }
    func testCancellationAndRateLimitOutcome() async throws {
        let rate = CycleUsageCollector(fetchPage: { _, _ in throw CycleEnrichmentError.http(status: 429, retryAfter: 120) }, fetchSummary: { self.summary(used: 1) }, fetchPeriod: { try self.period() })
        let result = await rate.collect(snapshot: snapshot(used: 1), summary: summary(used: 1))
        XCTAssertEqual(result.status, .rateLimited(retryAfter: 120))
        XCTAssertEqual(result.pageCount, 1)
        let cancelled = CycleUsageCollector(fetchPage: { _, _ in throw CancellationError() }, fetchSummary: { self.summary(used: 1) }, fetchPeriod: { try self.period() })
        let cancelledResult = await cancelled.collect(snapshot: snapshot(used: 1), summary: summary(used: 1))
        XCTAssertEqual(cancelledResult.status, .cancelled)
    }
    func testInvalidTimestampOrderAndChangingTotalAreUnstable() async throws {
        let samples = [
            [page([event("bad", "1")], total: 1)],
            [page([event("2000", "1"), event("3000", "1")], total: 2)],
            [page([event("3000", "1")], total: 2), page([event("2000", "1")], total: 3)]
        ]
        for pages in samples {
            let result = await collector(PageFeed(pages)).collect(snapshot: snapshot(used: 1), summary: summary(used: 1))
            XCTAssertEqual(result.status, .unstable)
        }
    }
    func period() throws -> CurrentPeriodUsageResponse {
        try JSONDecoder().decode(CurrentPeriodUsageResponse.self, from: Data(#"{"billingCycleStart":"1970-01-01T00:00:01Z","billingCycleEnd":"1970-01-01T00:00:10Z","planUsage":{"includedSpend":1},"autoBucketModels":["composer-2.5"]}"#.utf8))
    }
    func testOversizedResponseAccountsActualBytesWithoutDecode() async throws {
        let oversized = CycleUsageCollector(fetchPage: { _, _ in throw CycleEnrichmentError.oversizedPayload(byteCount: 17 * 1024 * 1024) }, fetchSummary: { self.summary(used: 1) }, fetchPeriod: { try self.period() })
        let result = await oversized.collect(snapshot: snapshot(used: 1), summary: summary(used: 1))
        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.byteCount, 17 * 1024 * 1024)
        XCTAssertEqual(result.pageCount, 1)
    }
    func testChangedSummaryStopsWithoutRetryingObsoleteRevision() async throws {
        let calls = CollectionSequence()
        let collector = CycleUsageCollector(fetchPage: { _, _ in self.page([self.event("2000", "1")], total: 1) }, fetchSummary: {
            self.summary(used: await calls.next() == 1 ? 2 : 1)
        }, fetchPeriod: { try self.period() })
        let result = await collector.collect(snapshot: snapshot(used: 1), summary: summary(used: 1))
        XCTAssertEqual(result.status, .unstable)
        XCTAssertEqual(result.pageCount, 1)
        XCTAssertNil(result.snapshot)
    }
    func testChangedHeadAndRepeatedInstabilityRemainBounded() async throws {
        let calls = CollectionSequence()
        let collector = CycleUsageCollector(fetchPage: { _, _ in
            self.page([self.event(await calls.next().isMultiple(of: 2) ? "3000" : "2000", "1")], total: 1)
        }, fetchSummary: { self.summary(used: 1) }, fetchPeriod: { try self.period() })
        let result = await collector.collect(snapshot: snapshot(used: 1), summary: summary(used: 1))
        XCTAssertEqual(result.status, .unstable)
        XCTAssertEqual(result.pageCount, 4)
    }
    func testByteEventAndTimeBudgetsNeverMarkComplete() async throws {
        for budget in [CycleUsageCollector.Budget(maxBytes: 99), .init(maxEvents: 0), .init(maxDuration: 0)] {
            let collector = CycleUsageCollector(budget: budget, fetchPage: { _, _ in self.page([self.event("2000", "1")], total: 1) }, fetchSummary: { self.summary(used: 1) }, fetchPeriod: { try self.period() })
            let result = await collector.collect(snapshot: snapshot(used: 1), summary: summary(used: 1))
            XCTAssertEqual(result.status, .partial)
            XCTAssertNotEqual(result.snapshot?.coverage.complete, true)
        }
    }
    func testAbsentMembershipStillShowsProvisionalAmountsWithoutLimits() async throws {
        let collector = CycleUsageCollector(fetchPage: { _, _ in self.page([self.event("2000", "1")], total: 1) }, fetchSummary: { self.summary(used: 1) }, fetchPeriod: {
            try JSONDecoder().decode(CurrentPeriodUsageResponse.self, from: Data(#"{"billingCycleStart":"1970-01-01T00:00:01Z","billingCycleEnd":"1970-01-01T00:00:10Z","planUsage":{"includedSpend":1}}"#.utf8))
        })
        let result = await collector.collect(snapshot: snapshot(used: 1), summary: summary(used: 1))
        XCTAssertEqual(result.snapshot?.status, .estimatedAttribution)
        XCTAssertEqual(result.snapshot?.cursorCents, 1)
        XCTAssertNil(result.snapshot?.estimatedCursorLimitCents)
    }
    func testExplicitEmptyAndOmittedZeroAreCompleteCycles() async throws {
        for raw in [#"{"usageEventsDisplay":[]}"#, #"{"totalUsageEventsCount":0}"#] {
            let empty = try JSONDecoder().decode(CycleUsagePage.self, from: Data(raw.utf8))
            let result = await collector(PageFeed([.init(page: empty, byteCount: raw.count)])).collect(snapshot: snapshot(used: 0), summary: summary(used: 0))
            XCTAssertEqual(result.status, .complete)
            XCTAssertEqual(result.snapshot?.cursorCents, 0)
            XCTAssertNil(result.snapshot?.estimatedCursorLimitCents)
        }
    }
    func testWallClockBudgetCancelsInFlightEnrichment() async throws {
        let started = Date()
        let collector = CycleUsageCollector(budget: .init(maxDuration: 0.02), fetchPage: { _, _ in self.page([], total: 0) }, fetchSummary: { self.summary(used: 0) }, fetchPeriod: {
            try await Task.sleep(for: .seconds(1))
            return try self.period()
        })
        let result = await collector.collect(snapshot: snapshot(used: 0), summary: summary(used: 0))
        XCTAssertEqual(result.status, .partial)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
    }
    func testRetryBudgetNeverReturnsRejectedOverlapOrHeadAggregate() async throws {
        for rejectHead in [false, true] {
            let periods = CollectionSequence()
            let pages = CollectionSequence()
            let collector = CycleUsageCollector(fetchPage: { _, _ in
                let call = await pages.next()
                return self.page([self.event(rejectHead && call == 2 ? "3000" : "2000", "1")], total: rejectHead ? 1 : nil)
            }, fetchSummary: { self.summary(used: 1) }, fetchPeriod: {
                if await periods.next() == (rejectHead ? 3 : 2) { throw CycleEnrichmentError.payloadBudget }
                return try self.period()
            })
            let result = await collector.collect(snapshot: snapshot(used: 1), summary: summary(used: 1))
            XCTAssertEqual(result.status, .partial)
            XCTAssertNil(result.snapshot, "Rejected \(rejectHead ? "head" : "overlap") evidence must not survive into a retry")
            XCTAssertEqual(result.pageCount, 2)
            XCTAssertEqual(result.byteCount, 200)
        }
    }

    func testSourceExhaustionWithoutBoundaryRequiresReconciliation() async throws {
        for usesTotal in [true, false] {
            let collector = CycleUsageCollector(fetchPage: { number, _ in
                if number == 1 { return self.page([self.event("2000", "3")], total: usesTotal ? 1 : nil) }
                return self.page([])
            }, fetchSummary: { self.summary(used: 10) }, fetchPeriod: { try self.period() })
            let result = await collector.collect(snapshot: snapshot(used: 10), summary: summary(used: 10))
            XCTAssertEqual(result.status, .unstable, "Source exhaustion must not imply full cycle coverage without reconciliation")
            XCTAssertNil(result.snapshot, "A rejected subtotal must not replace the previous complete snapshot")
            XCTAssertEqual(result.pageCount, usesTotal ? 4 : 6, "Only one retry shares the original budget")
        }
    }
    func testReachedCycleBoundaryCanHaveCompleteCoverageButUnavailableAttribution() async throws {
        let collector = CycleUsageCollector(fetchPage: { _, _ in
            self.page([self.event("2000", "3"), self.event("500", "10")], total: 50)
        }, fetchSummary: { self.summary(used: 10) }, fetchPeriod: { try self.period() })
        let result = await collector.collect(snapshot: snapshot(used: 10), summary: summary(used: 10))
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.snapshot?.coverage.complete, true)
        XCTAssertEqual(result.snapshot?.status, .unavailable)
        XCTAssertEqual(result.snapshot?.residualCents, -7)
        XCTAssertEqual(result.snapshot?.cursorCents, 3)
        XCTAssertNil(result.snapshot?.estimatedCursorLimitCents)
        XCTAssertEqual(result.pageCount, 2)
    }
    func testExhaustionMismatchRetryCanRecoverWithoutExceedingSharedBudget() async throws {
        let periods = CollectionSequence()
        let collector = CycleUsageCollector(fetchPage: { _, _ in
            let attemptStarted = await periods.value
            return self.page([self.event("2000", attemptStarted <= 2 ? "3" : "10")], total: 1)
        }, fetchSummary: { self.summary(used: 10) }, fetchPeriod: {
            _ = await periods.next()
            return try self.period()
        })
        let result = await collector.collect(snapshot: snapshot(used: 10), summary: summary(used: 10))
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.snapshot?.cursorCents, 10)
        XCTAssertEqual(result.snapshot?.coverage.complete, true)
        XCTAssertEqual(result.pageCount, 4)
    }

    func testReconciliationRetryBudgetExhaustionRemainsUnstableWithoutReplacementSnapshot() async throws {
        let budgets: [(CycleUsageCollector.Budget, Int, Int)] = [
            (.init(maxPages: 2), 2, 200),
            (.init(maxPages: 3), 3, 300),
            (.init(maxEvents: 2), 3, 300),
            (.init(maxBytes: 250), 3, 300)
        ]
        for (budget, expectedPages, expectedBytes) in budgets {
            let collector = CycleUsageCollector(budget: budget, fetchPage: { _, _ in
                self.page([self.event("2000", "3")], total: 1)
            }, fetchSummary: { self.summary(used: 10) }, fetchPeriod: { try self.period() })
            let result = await collector.collect(snapshot: snapshot(used: 10), summary: summary(used: 10))
            XCTAssertEqual(result.status, .unstable, "A rejected first scan must retain instability when its retry exhausts the shared budget")
            XCTAssertNil(result.snapshot, "Neither rejected nor unverified retry subtotals may replace a prior complete snapshot")
            XCTAssertEqual(result.pageCount, expectedPages)
            XCTAssertEqual(result.byteCount, expectedBytes)
        }
    }
    func testOversizedReconciliationRetryRemainsUnstableAndAccountsBytes() async throws {
        let pages = CollectionSequence()
        let collector = CycleUsageCollector(fetchPage: { _, _ in
            if await pages.next() == 3 { throw CycleEnrichmentError.oversizedPayload(byteCount: 1000) }
            return self.page([self.event("2000", "3")], total: 1)
        }, fetchSummary: { self.summary(used: 10) }, fetchPeriod: { try self.period() })
        let result = await collector.collect(snapshot: snapshot(used: 10), summary: summary(used: 10))
        XCTAssertEqual(result.status, .unstable)
        XCTAssertNil(result.snapshot)
        XCTAssertEqual(result.pageCount, 3)
        XCTAssertEqual(result.byteCount, 1200)
    }
    func testInitialBudgetExhaustionStillReturnsGenuinePartial() async throws {
        let collector = CycleUsageCollector(budget: .init(maxPages: 1), fetchPage: { _, _ in
            self.page([self.event("2000", "3")], total: 1)
        }, fetchSummary: { self.summary(used: 10) }, fetchPeriod: { try self.period() })
        let result = await collector.collect(snapshot: snapshot(used: 10), summary: summary(used: 10))
        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.snapshot?.cursorCents, 3)
        XCTAssertEqual(result.snapshot?.coverage.complete, false)
        XCTAssertEqual(result.pageCount, 1)
        XCTAssertEqual(result.byteCount, 100)
    }

    func collector(_ feed: PageFeed, maxPages: Int = 100) -> CycleUsageCollector {
        CycleUsageCollector(budget: .init(maxPages: maxPages), fetchPage: { page, _ in await feed.get(page) }, fetchSummary: { self.summary(used: await feed.expectedUsed()) }, fetchPeriod: {
            try JSONDecoder().decode(CurrentPeriodUsageResponse.self, from: Data(#"{"billingCycleStart":"1970-01-01T00:00:01Z","billingCycleEnd":"1970-01-01T00:00:10Z","planUsage":{"includedSpend":\#(await feed.expectedUsed())},"autoBucketModels":["composer-2.5"]}"#.utf8))
        })
    }
    func testCoherentPeriodSupplementsOnlyMissingPrimaryPoolField() async throws {
        let missing = try JSONDecoder().decode(UsageSummaryResponse.self, from: Data(#"{"billingCycleStart":"1970-01-01T00:00:01Z","billingCycleEnd":"1970-01-01T00:00:10Z","membershipType":"pro","individualUsage":{"plan":{"used":1,"limit":100,"autoPercentUsed":10}}}"#.utf8))
        let period = try JSONDecoder().decode(CurrentPeriodUsageResponse.self, from: Data(#"{"billingCycleStart":"1970-01-01T00:00:01Z","billingCycleEnd":"1970-01-01T00:00:10Z","planUsage":{"includedSpend":1,"autoPercentUsed":99,"apiPercentUsed":20},"autoBucketModels":["composer-2.5"]}"#.utf8))
        var primary = snapshot(used: 1); primary.otherPercent = nil
        let collector = CycleUsageCollector(fetchPage: { _, _ in self.page([self.event("2000", "1")], total: 1) }, fetchSummary: { missing }, fetchPeriod: { period })
        let result = await collector.collect(snapshot: primary, summary: missing)
        XCTAssertEqual(result.status, .complete)
        XCTAssertEqual(result.supplementarySnapshot?.cursorPercent, 10, "Primary wins")
        XCTAssertEqual(result.supplementarySnapshot?.otherPercent, 20)
        XCTAssertEqual(result.snapshot?.sourceOtherPercent, 20)
    }

    func event(_ timestamp: String, _ cents: String) -> CycleUsageEvent {
        CycleUsageEvent(timestamp: timestamp, model: "composer-2.5", kind: "USAGE_EVENT_KIND_INCLUDED_IN_ULTRA", chargedCents: Decimal(string: cents))
    }
    func page(_ rows: [CycleUsageEvent], total: Int? = nil) -> CycleHistoryPage { .init(page: .init(events: rows, total: total, hasEvents: true), byteCount: 100) }
    func snapshot(used: Int) -> SplitUsageSnapshot {
        .init(identity: .init(localID: 1, credentialGeneration: 1, accountDigest: "a", scopeDigest: "s", cycle: UsageCycle(start: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 10)), planIdentity: "pro:100"), capturedAt: Date(), cursorPercent: 10, otherPercent: 10, includedUsedCents: Decimal(used))
    }
    func summary(used: Int) -> UsageSummaryResponse {
        try! JSONDecoder().decode(UsageSummaryResponse.self, from: Data("{\"billingCycleStart\":\"1970-01-01T00:00:01Z\",\"billingCycleEnd\":\"1970-01-01T00:00:10Z\",\"membershipType\":\"pro\",\"individualUsage\":{\"plan\":{\"used\":\(used),\"limit\":100,\"autoPercentUsed\":10,\"apiPercentUsed\":10}}}".utf8))
    }
}
actor PageFeed {
    let pages: [CycleHistoryPage]
    init(_ pages: [CycleHistoryPage]) { self.pages = pages }
    func get(_ page: Int) -> CycleHistoryPage { pages[min(page - 1, pages.count - 1)] }
    func expectedUsed() -> Int { Int(ceil(NSDecimalNumber(decimal: pages[0].page.events.filter { ($0.date?.timeIntervalSince1970 ?? 0) >= 1 }.reduce(Decimal.zero) { $0 + ($1.chargedCents ?? 0) }).doubleValue)) }
}

private actor CollectionSequence {
    var value = 0
    func next() -> Int { value += 1; return value }
}
