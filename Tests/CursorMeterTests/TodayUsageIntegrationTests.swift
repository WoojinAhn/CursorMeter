import XCTest
@testable import CursorMeter

@MainActor
final class TodayUsageIntegrationTests: XCTestCase {
    private let start = ISO8601DateFormatter().date(from: "2026-09-15T04:00:00Z")!
    private func summary(cursor: Double? = 20, other: Double? = 40, used: Int = 300) throws -> UsageSummaryResponse {
        try JSONDecoder().decode(UsageSummaryResponse.self, from: Data("""
        {"membershipType":"ultra","billingCycleStart":"2026-09-01T00:00:00Z","billingCycleEnd":"2026-10-01T00:00:00Z","individualUsage":{"plan":{"used":\(used),"limit":40000,"autoPercentUsed":\(cursor.map(String.init(describing:)) ?? "null"),"apiPercentUsed":\(other.map(String.init(describing:)) ?? "null")}}}
        """.utf8))
    }
    private func accept(_ controller: SplitUsageController, _ summary: UsageSummaryResponse, generation: UInt64 = 1) throws -> UsageRevisionIdentity {
        try XCTUnwrap(controller.accept(summary: summary, usage: JSONDecoder().decode(UsageResponse.self, from: Data("{}".utf8)),
            userInfo: .init(email: "synthetic@example.test", name: "Demo", sub: "today-tests"), generation: generation, enterpriseScope: false))
    }
    private func request(_ controller: SplitUsageController, _ summary: UsageSummaryResponse, _ evidence: CycleEventEvidence,
                         identity: UsageRevisionIdentity? = nil, epoch: UInt64? = nil) throws {
        controller.requestAmounts(summary: summary, cookieHeader: "synthetic", primaryIdentity: try XCTUnwrap(identity ?? controller.primarySnapshot?.identity),
            eventEvidence: evidence, historyEpoch: epoch ?? controller.historyEpoch)
    }
    private func eventually(_ predicate: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await predicate()), ContinuousClock.now < deadline { await Task.yield() }
        let matched = await predicate()
        XCTAssertTrue(matched, file: file, line: line)
    }
    private actor Collector {
        var contexts: [TodayUsageCollectionContext?] = []
        var identities: [UsageRevisionIdentity] = []
        var hold = false
        var continuation: CheckedContinuation<Void, Never>?
        var status: CycleCollectionStatus = .complete
        var unreconciled = false
        var unknown = false
        var pageCount = 2
        func set(hold: Bool = false, status: CycleCollectionStatus = .complete, unreconciled: Bool = false,
                 unknown: Bool = false, pageCount: Int = 2) {
            self.hold = hold; self.status = status; self.unreconciled = unreconciled; self.unknown = unknown
            self.pageCount = pageCount
        }
        func collect(_ snapshot: SplitUsageSnapshot, context: TodayUsageCollectionContext?) async -> CycleCollectionResult {
            contexts.append(context); identities.append(snapshot.identity)
            if hold { await withCheckedContinuation { continuation = $0 } }
            guard status == .complete else { return .init(status: status, snapshot: nil, pageCount: 0, byteCount: 0) }
            var amounts = CycleAmountSnapshot(identity: snapshot.identity, capturedAt: context?.admittedAt ?? snapshot.capturedAt)
            amounts.coverage.complete = true
            amounts.cursorCents = 100; amounts.otherCents = 200
            amounts.residualCents = unreconciled ? 5 : 0
            amounts.unknownCount = unknown ? 1 : 0
            amounts.status = unreconciled || unknown ? .unavailable : .estimatedAttribution
            amounts.sourceCursorPercent = snapshot.cursorPercent; amounts.sourceOtherPercent = snapshot.otherPercent
            if let context {
                amounts.todayUsage = .init(day: context.day, evidenceAt: context.admittedAt,
                    cursorCents: 25, otherCents: 100, sourceIncludedTotalCents: snapshot.includedUsedCents!)
            }
            return .init(status: .complete, snapshot: amounts, pageCount: pageCount, byteCount: 0)
        }
        func release() { hold = false; continuation?.resume(); continuation = nil }
    }
    private actor Wake {
        var deadlines: [Date] = []
        var continuation: CheckedContinuation<Void, Error>?
        func wait(_ date: Date) async throws {
            deadlines.append(date)
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        func fire() { continuation?.resume(); continuation = nil }
    }

    func testChangedRevisionWithSameSummaryWithholdsThenDrainsAtSixtySeconds() async throws {
        var time = start
        let collector = Collector(), wake = Wake()
        let controller = SplitUsageController(now: { time }, collectToday: { snapshot, _, _, _, context, _ in
            await collector.collect(snapshot, context: context)
        }, waitUntil: { try await wake.wait($0) })
        let summary = try summary()
        _ = try accept(controller, summary)
        try request(controller, summary, .revision("a"))
        await eventually { controller.todayPercentagePoints?[.cursor] == 5 }
        XCTAssertEqual(controller.todayPercentagePoints?[.other], 20)
        time = start.addingTimeInterval(10)
        _ = try accept(controller, summary)
        try request(controller, summary, .revision("b"))
        XCTAssertNil(controller.todayPercentagePoints)
        XCTAssertNotNil(controller.amounts)
        await eventually { await wake.deadlines.count == 1 }
        let deadline = await wake.deadlines.last
        XCTAssertEqual(deadline, start.addingTimeInterval(60))
        time = start.addingTimeInterval(60)
        await wake.fire()
        await eventually { await collector.contexts.count == 2 && controller.todayPercentagePoints != nil }
        _ = try accept(controller, summary)
        try request(controller, summary, .revision("b"))
        for _ in 0..<20 { await Task.yield() }
        let count = await collector.contexts.count
        XCTAssertEqual(count, 2)
    }

    func testNewestDemandDrainsOnceAtAdaptiveDeadlineAfterCollectionCompletes() async throws {
        var time = start
        let collector = Collector(), wake = Wake()
        await collector.set(hold: true, pageCount: 51)
        let controller = SplitUsageController(now: { time }, collectToday: { snapshot, _, _, _, context, _ in
            await collector.collect(snapshot, context: context)
        }, waitUntil: { try await wake.wait($0) })
        let summary = try summary()
        _ = try accept(controller, summary)
        try request(controller, summary, .revision("a"))
        await eventually { await collector.contexts.count == 1 }
        time = start.addingTimeInterval(45)
        await collector.release()
        await eventually { controller.todayPercentagePoints != nil && controller.amountState == .ready }
        let costs = try XCTUnwrap(controller.amounts)
        XCTAssertEqual(controller.todayPercentagePoints?[.cursor], 5)
        XCTAssertEqual(controller.todayPercentagePoints?[.other], 20)

        time = start.addingTimeInterval(55)
        _ = try accept(controller, summary)
        try request(controller, summary, .revision("b"))
        XCTAssertNil(controller.todayPercentagePoints)
        XCTAssertEqual(controller.amounts, costs)
        await eventually { await wake.deadlines.count == 1 }
        time = start.addingTimeInterval(65)
        let latest = try accept(controller, summary)
        try request(controller, summary, .revision("c"))
        for _ in 0..<20 { await Task.yield() }
        let deadlines = await wake.deadlines
        XCTAssertEqual(deadlines, [start.addingTimeInterval(963)])
        let callsBeforeWake = await collector.contexts.count
        XCTAssertEqual(callsBeforeWake, 1)
        XCTAssertNil(controller.todayPercentagePoints)
        XCTAssertEqual(controller.amounts, costs)
        XCTAssertEqual(controller.schedule.automaticPagesRemaining(at: time), 249)

        await collector.set(hold: true, pageCount: 51)
        time = start.addingTimeInterval(963)
        await wake.fire()
        await eventually { await collector.contexts.count == 2 }
        let identity = await collector.identities.last
        let contexts = await collector.contexts
        XCTAssertEqual(identity, latest)
        XCTAssertEqual(contexts[1]?.admittedAt, time)
        XCTAssertNil(controller.todayPercentagePoints)
        XCTAssertEqual(controller.amounts, costs)
        await collector.release()
        await eventually { controller.todayPercentagePoints != nil && controller.amountState == .ready }
        XCTAssertEqual(controller.amounts?.identity, latest)
        XCTAssertEqual(controller.amounts?.cursorCents, costs.cursorCents)
        XCTAssertEqual(controller.amounts?.otherCents, costs.otherCents)
        XCTAssertEqual(controller.todayPercentagePoints?[.cursor], 5)
        XCTAssertEqual(controller.todayPercentagePoints?[.other], 20)
        try request(controller, summary, .revision("c"))
        for _ in 0..<20 { await Task.yield() }
        let finalCalls = await collector.contexts.count
        let finalDeadlines = await wake.deadlines
        XCTAssertEqual(finalCalls, 2)
        XCTAssertEqual(finalDeadlines, deadlines)
    }

    func testFallbackTokensInvalidateAndDuplicateCallbackCoalesces() async throws {
        var time = start
        let collector = Collector()
        let controller = SplitUsageController(now: { time }, collectToday: { snapshot, _, _, _, context, _ in
            await collector.collect(snapshot, context: context)
        })
        let summary = try summary()
        _ = try accept(controller, summary)
        try request(controller, summary, .primaryRefresh(1))
        await eventually { controller.todayPercentagePoints != nil }
        time = start.addingTimeInterval(60)
        _ = try accept(controller, summary)
        try request(controller, summary, .primaryRefresh(2))
        XCTAssertNil(controller.todayPercentagePoints)
        try request(controller, summary, .primaryRefresh(2))
        await eventually { await collector.contexts.count == 2 && controller.todayPercentagePoints != nil }
    }

    func testOlderInFlightCompletionRetainsCostsButCannotFulfillNewerPendingDemand() async throws {
        var time = start
        let collector = Collector(), wake = Wake()
        await collector.set(hold: true)
        let controller = SplitUsageController(now: { time }, collectToday: { snapshot, _, _, _, context, _ in
            await collector.collect(snapshot, context: context)
        }, waitUntil: { try await wake.wait($0) })
        let summary = try summary()
        _ = try accept(controller, summary)
        try request(controller, summary, .revision("a"))
        await eventually { await collector.contexts.count == 1 }
        _ = try accept(controller, summary)
        try request(controller, summary, .revision("b"))
        await collector.release()
        await eventually { controller.amounts != nil }
        XCTAssertNil(controller.todayPercentagePoints)
        await eventually { await wake.deadlines.count == 1 }
        time = start.addingTimeInterval(60)
        await wake.fire()
        await eventually { await collector.contexts.count == 2 && controller.todayPercentagePoints != nil }
    }

    func testNewPrimaryWithoutHistoryDecisionPreventsOlderDeferredStart() async throws {
        var time = start
        let collector = Collector(), wake = Wake()
        let controller = SplitUsageController(now: { time }, collectToday: { snapshot, _, _, _, context, _ in
            await collector.collect(snapshot, context: context)
        }, waitUntil: { try await wake.wait($0) })
        let summary = try summary()
        _ = try accept(controller, summary)
        try request(controller, summary, .revision("a"))
        await eventually { controller.todayPercentagePoints != nil }
        time = start.addingTimeInterval(10)
        _ = try accept(controller, summary)
        try request(controller, summary, .revision("b"))
        await eventually { await wake.deadlines.count == 1 }
        let latest = try accept(controller, summary)
        time = start.addingTimeInterval(60)
        await wake.fire()
        for _ in 0..<30 { await Task.yield() }
        let count = await collector.contexts.count
        XCTAssertEqual(count, 1)
        try request(controller, summary, .revision("c"))
        await eventually { await collector.identities.last == latest }
    }

    func testOrdinaryFailureDoesNotSelfEnqueue() async throws {
        let collector = Collector(), wake = Wake()
        await collector.set(status: .transportFailure)
        let controller = SplitUsageController(now: { self.start }, collectToday: { snapshot, _, _, _, context, _ in
            await collector.collect(snapshot, context: context)
        }, waitUntil: { try await wake.wait($0) })
        let summary = try summary()
        _ = try accept(controller, summary)
        try request(controller, summary, .revision("a"))
        await eventually { controller.amountState == .failed }
        let deadlines = await wake.deadlines
        XCTAssertTrue(deadlines.isEmpty)
        try request(controller, summary, .revision("a"))
        for _ in 0..<20 { await Task.yield() }
        let count = await collector.contexts.count
        XCTAssertEqual(count, 1)
    }

    func testUnreconciledTodayPreservesEarlierCostsAndUsesUnstableBackoff() async throws {
        var time = start
        let collector = Collector()
        let controller = SplitUsageController(now: { time }, collectToday: { snapshot, _, _, _, context, _ in
            await collector.collect(snapshot, context: context)
        })
        let summary = try summary()
        _ = try accept(controller, summary)
        try request(controller, summary, .revision("a"))
        await eventually { controller.todayPercentagePoints != nil }
        let previous = controller.amounts
        await collector.set(unreconciled: true)
        time = start.addingTimeInterval(60)
        _ = try accept(controller, summary)
        try request(controller, summary, .revision("b"))
        await eventually { controller.amountsAreEarlier }
        XCTAssertEqual(controller.amounts, previous)
        XCTAssertFalse(try XCTUnwrap(controller.amounts).isCached)
        XCTAssertNil(controller.todayPercentagePoints)
        XCTAssertEqual(controller.schedule.availability(at: time, manual: false, todayDemand: "new"),
                       .waiting(until: time.addingTimeInterval(300)))
    }

    func testSleepRequiresNewBatchAndMidnightOnlyInvalidatesPresentation() async throws {
        var time = start
        let collector = Collector()
        let controller = SplitUsageController(now: { time }, collectToday: { snapshot, _, _, _, context, _ in
            await collector.collect(snapshot, context: context)
        })
        let summary = try summary()
        _ = try accept(controller, summary)
        try request(controller, summary, .revision("a"))
        await eventually { controller.todayPercentagePoints != nil }
        let oldEpoch = controller.historyEpoch
        controller.prepareForSleep()
        time = start.addingTimeInterval(86_400)
        controller.resumeAfterWake()
        controller.reevaluateToday(at: time)
        XCTAssertNil(controller.todayPercentagePoints)
        _ = try accept(controller, summary)
        try request(controller, summary, .revision("late"), epoch: oldEpoch)
        for _ in 0..<20 { await Task.yield() }
        let count = await collector.contexts.count
        XCTAssertEqual(count, 1)
        _ = try accept(controller, summary)
        try request(controller, summary, .revision("new"))
        await eventually { await collector.contexts.count == 2 && controller.todayPercentagePoints != nil }
    }
    func testDurableUnknownAttributionUsesLegacyRecoveryThenRestoresFastCadence() async throws {
        var time = start
        let collector = Collector(), wake = Wake()
        await collector.set(unknown: true)
        let controller = SplitUsageController(now: { time }, collectToday: { snapshot, _, _, _, context, _ in
            await collector.collect(snapshot, context: context)
        }, waitUntil: { try await wake.wait($0) })
        let initial = try summary()
        _ = try accept(controller, initial)
        try request(controller, initial, .revision("a"))
        await eventually { controller.amountState == .ready }
        XCTAssertNil(controller.todayPercentagePoints)
        time = start.addingTimeInterval(60)
        _ = try accept(controller, initial)
        try request(controller, initial, .revision("b"))
        for _ in 0..<20 { await Task.yield() }
        let before = await collector.contexts.count
        XCTAssertEqual(before, 1, "A revision alone cannot bypass legacy unchanged suppression after durable bad attribution")
        let changed = try summary(cursor: 21)
        _ = try accept(controller, changed)
        try request(controller, changed, .revision("c"))
        await eventually { await wake.deadlines.count == 1 }
        let deadline = await wake.deadlines.last
        XCTAssertEqual(deadline, start.addingTimeInterval(600))
        await collector.set()
        time = start.addingTimeInterval(600)
        await wake.fire()
        await eventually { controller.todayPercentagePoints != nil }
        time = start.addingTimeInterval(660)
        _ = try accept(controller, changed)
        try request(controller, changed, .revision("d"))
        await eventually { await collector.contexts.count == 3 && controller.todayPercentagePoints != nil }
    }

    func testLegacyStoppedCostRetryNeverReceivesTodayContextOrFulfillsDemand() async throws {
        var time = start
        let collector = Collector()
        await collector.set(status: .partial)
        let controller = SplitUsageController(now: { time }, collectToday: { snapshot, _, _, _, context, _ in
            await collector.collect(snapshot, context: context)
        })
        let summary = try summary()
        _ = try accept(controller, summary)
        try request(controller, summary, .revision("a"))
        await eventually { controller.isAmountCollectionPaused }
        await collector.set()
        time = start.addingTimeInterval(59)
        await controller.retryStoppedAmounts()
        let before = await collector.contexts.count
        XCTAssertEqual(before, 1)
        time = start.addingTimeInterval(60)
        await controller.retryStoppedAmounts()
        await eventually { await collector.contexts.count == 2 && controller.amountState == .ready }
        let contexts = await collector.contexts
        XCTAssertNotNil(contexts[0])
        XCTAssertNil(contexts[1])
        XCTAssertNil(controller.todayPercentagePoints)
        XCTAssertFalse(controller.isAmountCollectionPaused)
    }

    func testSupplementCompletionDrainsLatestDemandUsingEffectivePercentages() async throws {
        actor Gate {
            var continuation: CheckedContinuation<Void, Never>?
            var calls = 0
            var waiting = false
            func first() -> Bool { calls += 1; return calls == 1 }
            func wait() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
            func release() { continuation?.resume(); continuation = nil }
        }
        var time = start
        let gate = Gate(), collector = Collector()
        let period = try JSONDecoder().decode(CurrentPeriodUsageResponse.self, from: Data("""
        {"billingCycleStart":"2026-09-01T00:00:00Z","billingCycleEnd":"2026-10-01T00:00:00Z","planUsage":{"includedSpend":300,"autoPercentUsed":20,"apiPercentUsed":40}}
        """.utf8))
        let controller = SplitUsageController(now: { time }, fetchPeriod: { _ in
            await gate.wait()
            return period
        }, collectToday: { snapshot, summary, _, _, context, supplement in
            if await gate.first() { return .init(status: .complete, snapshot: nil, pageCount: 1, byteCount: 0) }
            let effective = snapshot.supplemented(by: period, summary: summary, at: context!.admittedAt)
            await supplement(effective)
            return await collector.collect(effective, context: context)
        })
        let missing = try summary(cursor: nil)
        _ = try accept(controller, missing)
        try request(controller, missing, .revision("a"))
        await eventually { controller.amountState == .ready }
        time = start.addingTimeInterval(60)
        _ = try accept(controller, missing)
        try request(controller, missing, .revision("b"))
        await eventually { await gate.waiting }
        let latest = try accept(controller, missing)
        try request(controller, missing, .revision("c"))
        await gate.release()
        await eventually { controller.todayPercentagePoints?[.cursor] == 5 }
        let identity = await collector.identities.last
        XCTAssertEqual(identity, latest)
        XCTAssertNil(controller.primarySnapshot?.cursorPercent)
        XCTAssertEqual(controller.snapshot?.cursorPercent, 20)
    }

    func testAuthorityWaitCrossingMidnightCapturesNewDayOnceAndActiveAttemptKeepsIt() async throws {
        actor Gate {
            var continuation: CheckedContinuation<Void, Never>?
            var waiting = false
            func wait() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
            func release() { continuation?.resume(); continuation = nil }
        }
        var time = ISO8601DateFormatter().date(from: "2026-09-15T14:59:59Z")!
        let gate = Gate(), collector = Collector()
        let store = CycleUsageStore(hooks: .init(beforeAuthorityChange: { await gate.wait() }))
        let controller = SplitUsageController(store: store, now: { time }, collectToday: { snapshot, _, _, _, context, _ in
            await collector.collect(snapshot, context: context)
        })
        let summary = try summary()
        _ = try accept(controller, summary)
        let prepare = Task { await controller.prepareProfileAuthority(freshSubjectDigest: UsageRevisionIdentity.digest("today-tests")) }
        await eventually { await gate.waiting }
        try request(controller, summary, .revision("a"))
        time = time.addingTimeInterval(2)
        await collector.set(hold: true)
        await gate.release()
        _ = await prepare.value
        await eventually { await collector.contexts.count == 1 }
        let contexts = await collector.contexts
        let admitted = try XCTUnwrap(contexts.first ?? nil)
        XCTAssertEqual(admitted.admittedAt, time)
        time = time.addingTimeInterval(86_400)
        await collector.release()
        await eventually { controller.amounts != nil }
        XCTAssertEqual(controller.amounts?.todayUsage?.day, admitted.day)
        controller.reevaluateToday(at: time)
        XCTAssertNil(controller.todayPercentagePoints)
    }

    func testGenerationAndRetiredPresentationDropHighlightAndPendingWork() async throws {
        for change in ["generation", "retire", "logout"] {
            var time = start
            let collector = Collector(), wake = Wake()
            let controller = SplitUsageController(now: { time }, collectToday: { snapshot, _, _, _, context, _ in
                await collector.collect(snapshot, context: context)
            }, waitUntil: { try await wake.wait($0) })
            let summary = try summary()
            _ = try accept(controller, summary)
            try request(controller, summary, .revision("a"))
            await eventually { controller.todayPercentagePoints != nil }
            time = start.addingTimeInterval(10)
            _ = try accept(controller, summary)
            try request(controller, summary, .revision("b"))
            await eventually { await wake.deadlines.count == 1 }
            if change == "generation" { _ = try accept(controller, summary, generation: 2) }
            else if change == "logout" { controller.reset() }
            else {
                controller.accept(summary: summary, usage: nil, userInfo: .init(email: nil, name: nil),
                                  generation: 1, enterpriseScope: true)
            }
            XCTAssertNil(controller.todayPercentagePoints, change)
            XCTAssertNil(controller.amounts, change)
            time = start.addingTimeInterval(60)
            await wake.fire()
            for _ in 0..<20 { await Task.yield() }
            let count = await collector.contexts.count
            XCTAssertEqual(count, 1, change)
        }
    }

    func testRetiredCollectionSettlementUnblocksReservedBudgetForNewestPendingDemand() async throws {
        actor Gate {
            var continuations: [Int: CheckedContinuation<Void, Never>] = [:]
            var count = 0
            func collect() async -> CycleCollectionResult {
                let index = count
                count += 1
                await withCheckedContinuation { continuations[index] = $0 }
                return .init(status: .cancelled, snapshot: nil, pageCount: 0, byteCount: 0)
            }
            func release(_ index: Int) { continuations.removeValue(forKey: index)?.resume() }
        }
        let gate = Gate()
        let controller = SplitUsageController(now: { self.start }, collectToday: { _, _, _, _, _, _ in await gate.collect() })
        let summary = try summary()
        for index in 0..<3 {
            _ = try accept(controller, summary)
            try request(controller, summary, .primaryRefresh(UInt64(index)))
            await eventually { await gate.count == index + 1 }
            controller.reset()
        }
        _ = try accept(controller, summary)
        try request(controller, summary, .primaryRefresh(4))
        for _ in 0..<20 { await Task.yield() }
        let reserved = await gate.count
        XCTAssertEqual(reserved, 3)
        await gate.release(0)
        await eventually { await gate.count == 4 }
        controller.reset()
        for index in 1..<4 { await gate.release(index) }
    }

    func testNewCredentialGenerationRecollectsEvenIdenticalDemand() async throws {
        let collector = Collector()
        let controller = SplitUsageController(now: { self.start }, collectToday: { snapshot, _, _, _, context, _ in
            await collector.collect(snapshot, context: context)
        })
        let summary = try summary()
        _ = try accept(controller, summary)
        try request(controller, summary, .revision("same"))
        await eventually { controller.todayPercentagePoints != nil }
        _ = try accept(controller, summary, generation: 2)
        XCTAssertNil(controller.todayPercentagePoints)
        try request(controller, summary, .revision("same"))
        await eventually { await collector.contexts.count == 2 && controller.todayPercentagePoints != nil }
    }

    func testMissingCycleCannotAdmitSupportingCollection() async throws {
        let collector = Collector()
        let controller = SplitUsageController(now: { self.start }, collectToday: { snapshot, _, _, _, context, _ in
            await collector.collect(snapshot, context: context)
        })
        let summary = try JSONDecoder().decode(UsageSummaryResponse.self, from: Data("""
        {"membershipType":"ultra","individualUsage":{"plan":{"used":300,"limit":40000,"autoPercentUsed":20,"apiPercentUsed":40}}}
        """.utf8))
        _ = try accept(controller, summary)
        try request(controller, summary, .revision("a"))
        for _ in 0..<30 { await Task.yield() }
        let count = await collector.contexts.count
        XCTAssertEqual(count, 0)
    }

    func testDeferredStartRefreshesDayAndSleepCancelsActiveAttemptUntilNewHistory() async throws {
        var time = ISO8601DateFormatter().date(from: "2026-09-15T14:59:40Z")!
        let collector = Collector(), wake = Wake()
        let controller = SplitUsageController(now: { time }, collectToday: { snapshot, _, _, _, context, _ in
            await collector.collect(snapshot, context: context)
        }, waitUntil: { try await wake.wait($0) })
        let summary = try summary()
        _ = try accept(controller, summary)
        try request(controller, summary, .revision("a"))
        await eventually { controller.todayPercentagePoints != nil }
        time = time.addingTimeInterval(10)
        _ = try accept(controller, summary)
        try request(controller, summary, .revision("b"))
        await eventually { await wake.deadlines.count == 1 }
        time = time.addingTimeInterval(50)
        await collector.set(hold: true)
        await wake.fire()
        await eventually { await collector.contexts.count == 2 }
        let contexts = await collector.contexts
        XCTAssertNotEqual(contexts[0]?.day, contexts[1]?.day)
        XCTAssertEqual(contexts[1]?.admittedAt, time)
        let oldEpoch = controller.historyEpoch
        controller.prepareForSleep()
        time = time.addingTimeInterval(3600)
        controller.resumeAfterWake()
        await collector.release()
        await eventually { controller.schedule.automaticPagesRemaining(at: time) == 298 }
        _ = try accept(controller, summary)
        try request(controller, summary, .revision("late"), epoch: oldEpoch)
        for _ in 0..<20 { await Task.yield() }
        let before = await collector.contexts.count
        XCTAssertEqual(before, 2)
        XCTAssertNil(controller.todayPercentagePoints)
        _ = try accept(controller, summary)
        try request(controller, summary, .revision("new"))
        await eventually { await collector.contexts.count == 3 && controller.todayPercentagePoints != nil }
    }

    func testCompletedTodayRecollectsSameRevisionOnceAfterSleepWithFreshEpochAndStartGate() async throws {
        var time = start
        let collector = Collector(), wake = Wake()
        let controller = SplitUsageController(now: { time }, collectToday: { snapshot, _, _, _, context, _ in
            await collector.collect(snapshot, context: context)
        }, waitUntil: { try await wake.wait($0) })
        let summary = try summary()
        _ = try accept(controller, summary)
        try request(controller, summary, .revision("same"))
        await eventually { controller.todayPercentagePoints != nil && controller.amountState == .ready }
        let oldEpoch = controller.historyEpoch
        let costs = controller.amounts
        time = start.addingTimeInterval(10)
        controller.prepareForSleep()
        time = start.addingTimeInterval(20)
        controller.resumeAfterWake()
        XCTAssertNil(controller.todayPercentagePoints)
        XCTAssertEqual(controller.amounts, costs)
        XCTAssertEqual(controller.schedule.automaticPagesRemaining(at: time), 298)
        XCTAssertEqual(controller.schedule.availability(at: time, manual: false), .unchanged,
                       "Sleep must preserve the legacy raw-summary latch")
        _ = try accept(controller, summary)
        try request(controller, summary, .revision("same"), epoch: oldEpoch)
        for _ in 0..<20 { await Task.yield() }
        let oldCalls = await collector.contexts.count
        XCTAssertEqual(oldCalls, 1)
        let oldDeadlines = await wake.deadlines
        XCTAssertTrue(oldDeadlines.isEmpty, "Late pre-sleep history cannot unlock admission")
        try request(controller, summary, .revision("same"))
        try request(controller, summary, .revision("same"))
        await eventually { await wake.deadlines.count == 1 }
        let deadlines = await wake.deadlines
        XCTAssertEqual(deadlines.first, start.addingTimeInterval(60))
        let earlyCalls = await collector.contexts.count
        XCTAssertEqual(earlyCalls, 1)
        time = start.addingTimeInterval(60)
        await wake.fire()
        await eventually { await collector.contexts.count == 2 && controller.todayPercentagePoints != nil }
        XCTAssertEqual(controller.schedule.automaticPagesRemaining(at: time), 296)
        try request(controller, summary, .revision("same"))
        _ = try accept(controller, summary)
        try request(controller, summary, .revision("same"))
        for _ in 0..<20 { await Task.yield() }
        let finalCalls = await collector.contexts.count
        XCTAssertEqual(finalCalls, 2, "The fresh-epoch receipt restores ordinary unchanged suppression")
    }

    func testSameOwnerAuthorityDowngradeAndRecoveryRequireFreshSameRevisionCollection() async throws {
        var time = start
        let collector = Collector(), wake = Wake()
        let controller = SplitUsageController(now: { time }, collectToday: { snapshot, _, _, _, context, _ in
            await collector.collect(snapshot, context: context)
        }, waitUntil: { try await wake.wait($0) })
        let summary = try summary()
        let subject = try XCTUnwrap(UsageRevisionIdentity.accountDigest(subject: "today-tests", email: nil))
        let prepared = await controller.prepareProfileAuthority(freshSubjectDigest: subject)
        XCTAssertTrue(prepared)
        let original = try accept(controller, summary)
        try request(controller, summary, .revision("same"))
        await eventually { controller.todayPercentagePoints != nil && controller.amountState == .ready }
        XCTAssertEqual(controller.persistentSubjectDigest, subject)

        for (index, authority) in [nil, Optional(subject)].enumerated() {
            let costs = controller.amounts
            time = start.addingTimeInterval(Double(index * 60 + 10))
            let acknowledged = await controller.prepareProfileAuthority(freshSubjectDigest: authority)
            XCTAssertTrue(acknowledged)
            let current = try accept(controller, summary)
            XCTAssertTrue(current.sameScope(as: original))
            XCTAssertEqual(current.credentialGeneration, original.credentialGeneration)
            XCTAssertEqual(controller.persistentSubjectDigest, authority,
                           "Retained display identity cannot restore verified persistence authority")
            XCTAssertEqual(controller.amounts, costs)
            XCTAssertNil(controller.todayPercentagePoints)
            XCTAssertEqual(controller.schedule.automaticPagesRemaining(at: time), 298 - index * 2)
            XCTAssertEqual(controller.schedule.availability(at: time, manual: false), .unchanged)
            try request(controller, summary, .revision("same"))
            await eventually { await wake.deadlines.count == index + 1 }
            let deadlines = await wake.deadlines
            XCTAssertEqual(deadlines.last, start.addingTimeInterval(Double((index + 1) * 60)))
            guard deadlines.count == index + 1 else { return }
            await collector.set(hold: true)
            time = start.addingTimeInterval(Double((index + 1) * 60))
            await wake.fire()
            await eventually { await collector.contexts.count == index + 2 }
            XCTAssertNil(controller.todayPercentagePoints, "Matching old costs cannot fulfill retired authority evidence")
            XCTAssertEqual(controller.amounts, costs)
            XCTAssertEqual(controller.persistentSubjectDigest, authority)
            await collector.release()
            await eventually { controller.todayPercentagePoints != nil && controller.amountState == .ready }
            XCTAssertEqual(controller.persistentSubjectDigest, authority)
            try request(controller, summary, .revision("same"))
        }
        _ = try accept(controller, summary)
        try request(controller, summary, .revision("same"))
        for _ in 0..<20 { await Task.yield() }
        let count = await collector.contexts.count
        XCTAssertEqual(count, 3)
        XCTAssertEqual(controller.schedule.automaticPagesRemaining(at: time), 294)
    }

}
