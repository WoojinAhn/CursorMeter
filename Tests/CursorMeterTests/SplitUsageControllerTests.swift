import XCTest
@testable import CursorMeter

@MainActor
final class SplitUsageControllerTests: XCTestCase {
    private func summary(cursor: Double? = 10, other: Double? = 41, limit: Int? = 40000, membership: String? = "ultra") -> UsageSummaryResponse {
        UsageSummaryResponse(billingCycleStart: "2026-09-01T00:00:00Z", billingCycleEnd: "2026-10-01T00:00:00Z", membershipType: membership, limitType: nil, isUnlimited: nil, autoModelSelectedDisplayMessage: nil,
            individualUsage: IndividualUsage(plan: PlanUsage(enabled: true, used: 18200, limit: limit, remaining: nil, totalPercentUsed: nil, autoPercentUsed: cursor, apiPercentUsed: other), onDemand: nil, overall: nil), teamUsage: nil)
    }
    private func usage() throws -> UsageResponse { try JSONDecoder().decode(UsageResponse.self, from: Data("{}".utf8)) }
    private var user: UserInfoResponse { .init(email: "demo@example.test", name: "Demo User", sub: "demo-subject") }

    func testInitialSplitEvidenceWaitsForSuccessfulRequestCapabilityVerification() throws {
        let controller = SplitUsageController()
        controller.accept(summary: summary(), usage: nil, userInfo: user, generation: 1, enterpriseScope: false)
        XCTAssertEqual(controller.eligibility, .checking)
        XCTAssertNil(controller.snapshot?.cursorPercent)
        XCTAssertTrue(controller.suppressesLegacyMeter)
        controller.accept(summary: summary(), usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
        XCTAssertEqual(controller.eligibility, .eligible)
        XCTAssertEqual(controller.snapshot?.otherPercent, 41)
    }

    func testLatchedSplitMissingFieldsRemainUnavailableInsteadOfLegacyRatio() throws {
        let controller = SplitUsageController()
        controller.accept(summary: summary(), usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
        controller.accept(summary: summary(cursor: nil, other: nil, limit: nil, membership: nil), usage: nil, userInfo: user, generation: 1, enterpriseScope: false)
        XCTAssertEqual(controller.eligibility, .eligible)
        XCTAssertNil(controller.snapshot?.cursorPercent)
        XCTAssertNil(controller.snapshot?.otherPercent)
        XCTAssertEqual(controller.snapshot?.identity.planIdentity, "ultra:40000")
    }

    func testBlankMembershipMetadataDoesNotResetVerifiedScope() throws {
        let controller = SplitUsageController()
        controller.accept(summary: summary(), usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
        controller.accept(summary: summary(membership: "  "), usage: nil, userInfo: user, generation: 1, enterpriseScope: false)
        XCTAssertEqual(controller.eligibility, .eligible)
        XCTAssertEqual(controller.primarySnapshot?.identity.planIdentity, "ultra:40000")
    }

    func testFailureRetainsSourceTimestampAndNextPrimaryHasNewRevision() throws {
        let controller = SplitUsageController()
        controller.accept(summary: summary(), usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
        let first = try XCTUnwrap(controller.snapshot)
        controller.recordFailure()
        XCTAssertTrue(controller.isStale)
        XCTAssertEqual(controller.snapshot, first)
        controller.accept(summary: summary(), usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
        XCTAssertFalse(controller.isStale)
        XCTAssertGreaterThan(try XCTUnwrap(controller.snapshot).identity.localID, first.identity.localID)
    }

    func testPlanTransitionCannotReusePriorCapabilityAndEnterpriseRetiresSplit() throws {
        let controller = SplitUsageController()
        controller.accept(summary: summary(), usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
        controller.accept(summary: summary(limit: 2000, membership: "pro"), usage: nil, userInfo: user, generation: 1, enterpriseScope: false)
        XCTAssertEqual(controller.eligibility, .checking)
        controller.accept(summary: summary(), usage: try usage(), userInfo: user, generation: 1, enterpriseScope: true)
        XCTAssertEqual(controller.eligibility, .legacy)
        XCTAssertNil(controller.snapshot)
    }

    func testIdentityWithoutSubjectCannotEnablePersistentAmounts() throws {
        let controller = SplitUsageController()
        controller.accept(summary: summary(), usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
        XCTAssertNotNil(controller.persistentSubjectDigest)
        controller.accept(summary: summary(), usage: try usage(), userInfo: .init(email: user.email, name: nil), generation: 1, enterpriseScope: false)
        XCTAssertNil(controller.persistentSubjectDigest)
        XCTAssertNotEqual(controller.snapshot?.identity.accountDigest, UsageRevisionIdentity.accountDigest(subject: user.sub, email: nil))
    }

    func testPrecisionEvidenceAccumulatesOnlyWithinScope() throws {
        let controller = SplitUsageController()
        controller.accept(summary: summary(cursor: 1.234), usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
        controller.accept(summary: summary(cursor: 2), usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
        XCTAssertEqual(controller.snapshot?.cursorObservedPlaces, 3)
        controller.accept(summary: summary(cursor: 2, limit: 2000, membership: "pro"), usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
        XCTAssertEqual(controller.snapshot?.cursorObservedPlaces, 0)
    }
    func testUnknownIdentityUsesIsolatedSessionSplitWithoutPersistentWrites() throws {
        let controller = SplitUsageController()
        let unknown = UserInfoResponse(email: nil, name: nil, sub: nil)
        controller.accept(summary: summary(), usage: try usage(), userInfo: unknown, generation: 1, enterpriseScope: false)
        XCTAssertEqual(controller.eligibility, .eligible)
        let firstAccount = controller.snapshot?.identity.accountDigest
        XCTAssertNotNil(firstAccount)
        XCTAssertNil(controller.persistentSubjectDigest)
        controller.accept(summary: summary(), usage: try usage(), userInfo: unknown, generation: 1, enterpriseScope: false)
        XCTAssertEqual(controller.snapshot?.identity.accountDigest, firstAccount)
        controller.accept(summary: summary(), usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
        XCTAssertNotEqual(controller.snapshot?.identity.accountDigest, firstAccount)
    }

    private actor CollectionGate {
        var calls = 0
        var waiter: CheckedContinuation<Void, Never>?
        func collect(_ snapshot: SplitUsageSnapshot) async -> CycleCollectionResult {
            calls += 1
            await withCheckedContinuation { waiter = $0 }
            return .init(status: .complete, snapshot: .init(identity: snapshot.identity, capturedAt: snapshot.capturedAt), pageCount: 2, byteCount: 100)
        }
        func release() { waiter?.resume(); waiter = nil }
    }

    private func eventually(_ condition: @MainActor () async -> Bool) async {
        let end = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await condition()), ContinuousClock.now < end { await Task.yield() }
        let result = await condition()
        XCTAssertTrue(result)
    }

    func testPrimaryRevisionAdvancesWhileOneMonthlyCollectionIsHeld() async throws {
        let gate = CollectionGate()
        let controller = SplitUsageController(collect: { snapshot, _, _, _, _ in await gate.collect(snapshot) })
        controller.accept(summary: summary(), usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
        controller.requestAmounts(summary: summary(), cookieHeader: "fixture")
        await eventually { await gate.calls == 1 }
        let firstID = controller.snapshot?.identity.localID
        controller.accept(summary: summary(cursor: 11), usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
        controller.requestAmounts(summary: summary(cursor: 11), cookieHeader: "fixture")
        XCTAssertEqual(controller.snapshot?.cursorPercent, 11)
        XCTAssertNotEqual(controller.snapshot?.identity.localID, firstID)
        let calls = await gate.calls
        XCTAssertEqual(calls, 1)
        await gate.release()
        await eventually { controller.amounts != nil }
        XCTAssertEqual(controller.amounts?.identity.localID, firstID)
        XCTAssertEqual(controller.snapshot?.cursorPercent, 11, "Late amounts never replace newer primary percentages")
    }

    func testRetiredCollectionCannotPublishIntoAnotherAccount() async throws {
        let gate = CollectionGate()
        let controller = SplitUsageController(collect: { snapshot, _, _, _, _ in await gate.collect(snapshot) })
        controller.accept(summary: summary(), usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
        controller.requestAmounts(summary: summary(), cookieHeader: "fixture")
        await eventually { await gate.calls == 1 }
        controller.accept(summary: summary(), usage: try usage(), userInfo: .init(email: "second@example.test", name: nil, sub: "second"), generation: 2, enterpriseScope: false)
        await gate.release()
        for _ in 0..<20 { await Task.yield() }
        await eventually { controller.schedule.automaticPagesRemaining(at: Date()) == 298 }
        XCTAssertNil(controller.amounts)
        XCTAssertEqual(controller.snapshot?.identity.accountDigest, UsageRevisionIdentity.accountDigest(subject: "second", email: nil))
    }

    func testMembershipDiscoveryKeepsOwnershipAndDoesNotStrandCollection() async throws {
        let gate = CollectionGate()
        let controller = SplitUsageController(collect: { snapshot, _, _, _, _ in await gate.collect(snapshot) })
        controller.accept(summary: summary(membership: nil), usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
        let initial = try XCTUnwrap(controller.snapshot)
        controller.requestAmounts(summary: summary(membership: nil), cookieHeader: "fixture")
        await eventually { await gate.calls == 1 }
        controller.accept(summary: summary(), usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
        XCTAssertEqual(controller.snapshot?.identity.planIdentity, initial.identity.planIdentity)
        await gate.release()
        await eventually { controller.amountState != .refreshing }
        XCTAssertEqual(controller.amountState, .ready)
        XCTAssertNotEqual(controller.schedule.availability(at: Date(), manual: true), .collecting)
    }

    func testSummaryFingerprintNormalizesEquivalentDatesAndMetadata() throws {
        let first = summary()
        let equivalent = UsageSummaryResponse(billingCycleStart: "2026-09-01T00:00:00.000Z", billingCycleEnd: "2026-10-01T00:00:00.000Z", membershipType: " ULTRA ", limitType: nil, isUnlimited: nil, autoModelSelectedDisplayMessage: nil, individualUsage: first.individualUsage, teamUsage: nil)
        XCTAssertEqual(SplitUsageController.fingerprint(summary: first), SplitUsageController.fingerprint(summary: equivalent))
    }

    private func period(cursor: Double = 1.234, used: Int = 18200) throws -> CurrentPeriodUsageResponse {
        try JSONDecoder().decode(CurrentPeriodUsageResponse.self, from: Data("""
        {"billingCycleStart":"2026-09-01T00:00:00Z","billingCycleEnd":"2026-10-01T00:00:00Z","planUsage":{"includedSpend":\(used),"autoPercentUsed":\(cursor),"apiPercentUsed":41}}
        """.utf8))
    }

    func testCoherentSupplementSurvivesEqualPrimaryWithoutLeakingPrecision() async throws {
        var time = Date()
        let period = try period()
        let controller = SplitUsageController(now: { time }, collect: { snapshot, summary, _, _, _ in
            .init(status: .complete, snapshot: nil, pageCount: 0, byteCount: 0,
                  supplementarySnapshot: snapshot.supplemented(by: period, summary: summary, at: snapshot.capturedAt))
        })
        let missing = summary(cursor: nil)
        controller.accept(summary: missing, usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
        controller.requestAmounts(summary: missing, cookieHeader: "fixture")
        await eventually { controller.snapshot?.cursorPercent == 1.234 }
        let fetchedAt = controller.snapshot?.periodCapturedAt
        time = time.addingTimeInterval(60)
        controller.accept(summary: missing, usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
        XCTAssertEqual(controller.snapshot?.cursorPercent, 1.234)
        XCTAssertEqual(controller.snapshot?.cursorSource, .period)
        XCTAssertEqual(controller.snapshot?.periodCapturedAt, fetchedAt)
        controller.accept(summary: summary(cursor: 2), usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
        XCTAssertEqual(controller.snapshot?.cursorSource, .summary)
        XCTAssertEqual(controller.snapshot?.cursorObservedPlaces, 0)
    }

    func testSupplementExpiresAndChangedIncludedSpendInvalidatesMemo() async throws {
        for change in ["amount", "expiry", "generation"] {
            var time = Date()
            let period = try period()
            let controller = SplitUsageController(now: { time }, collect: { snapshot, summary, _, _, _ in
                .init(status: .complete, snapshot: nil, pageCount: 0, byteCount: 0,
                      supplementarySnapshot: snapshot.supplemented(by: period, summary: summary, at: snapshot.capturedAt))
            })
            let missing = summary(cursor: nil)
            controller.accept(summary: missing, usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
            controller.requestAmounts(summary: missing, cookieHeader: "fixture")
            await eventually { controller.snapshot?.cursorPercent == 1.234 }
            let changed: UsageSummaryResponse
            if change == "amount" {
                let data = Data("""
                {"billingCycleStart":"2026-09-01T00:00:00Z","billingCycleEnd":"2026-10-01T00:00:00Z","membershipType":"ultra","individualUsage":{"plan":{"used":18201,"limit":40000,"apiPercentUsed":41}}}
                """.utf8)
                changed = try JSONDecoder().decode(UsageSummaryResponse.self, from: data)
            } else { changed = missing }
            if change == "expiry" { time = time.addingTimeInterval(601) }
            controller.accept(summary: changed, usage: try usage(), userInfo: user, generation: change == "generation" ? 2 : 1, enterpriseScope: false)
            XCTAssertNil(controller.snapshot?.cursorPercent, change)
        }
    }

    func testPartialCollectionCannotReplacePriorCompleteAmounts() async throws {
        actor Responses {
            var calls = 0
            func collect(_ snapshot: SplitUsageSnapshot) -> CycleCollectionResult {
                calls += 1
                var amounts = CycleAmountSnapshot(identity: snapshot.identity, capturedAt: snapshot.capturedAt)
                amounts.coverage.complete = calls == 1
                amounts.cursorCents = calls == 1 ? 100 : 10
                return .init(status: calls == 1 ? .complete : .partial, snapshot: amounts, pageCount: 1, byteCount: 100)
            }
        }
        var time = Date()
        let responses = Responses()
        let controller = SplitUsageController(now: { time }, collect: { snapshot, _, _, _, _ in await responses.collect(snapshot) })
        controller.accept(summary: summary(), usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
        controller.requestAmounts(summary: summary(), cookieHeader: "fixture")
        await eventually { controller.amounts?.coverage.complete == true }
        time = time.addingTimeInterval(61)
        controller.requestAmounts(manual: true)
        await eventually { await responses.calls == 2 && controller.amountState != .refreshing }
        XCTAssertEqual(controller.amounts?.cursorCents, 100)
        XCTAssertTrue(controller.amounts?.coverage.complete == true)
    }

    func testHardCollectionLimitExplainsAutomaticPauseWhileManualRetryRemainsAvailable() async throws {
        var time = Date()
        let controller = SplitUsageController(now: { time }, collect: { _, _, _, _, _ in
            .init(status: .partial, snapshot: nil, pageCount: 100, byteCount: 0)
        })
        controller.accept(summary: summary(), usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
        controller.requestAmounts(summary: summary(), cookieHeader: "fixture")
        await eventually { controller.amountState == .unavailable }
        XCTAssertFalse(controller.canRefreshAmounts)
        time = time.addingTimeInterval(61)
        XCTAssertEqual(controller.schedule.availability(at: time, manual: false), .cycleLimit)
        XCTAssertTrue(controller.canRefreshAmounts)
        XCTAssertEqual(controller.amountsRefreshStateText, "Auto collection paused · Retry manually")
    }

    func testEarlyPeriodSupplementSurvivesHistoryFailureAndNeverChangesPrimary() async throws {
        let period = try period()
        let controller = SplitUsageController(collect: { snapshot, summary, _, _, supplement in
            await supplement(snapshot.supplemented(by: period, summary: summary, at: snapshot.capturedAt))
            return .init(status: .transportFailure, snapshot: nil, pageCount: 1, byteCount: 0)
        })
        let missing = summary(cursor: nil)
        controller.accept(summary: missing, usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
        controller.requestAmounts(summary: missing, cookieHeader: "fixture")
        await eventually { controller.amountState == .failed }
        XCTAssertEqual(controller.snapshot?.cursorPercent, 1.234)
        XCTAssertNil(controller.primarySnapshot?.cursorPercent)
        XCTAssertEqual(controller.primarySnapshot?.cursorObservedPlaces, 0)
    }

    private actor PeriodFetcher {
        let period: CurrentPeriodUsageResponse
        var errors: [CycleEnrichmentError]
        var calls = 0
        init(period: CurrentPeriodUsageResponse, errors: [CycleEnrichmentError] = []) {
            self.period = period; self.errors = errors
        }
        func fetch() throws -> CurrentPeriodUsageResponse {
            calls += 1
            if !errors.isEmpty { throw errors.removeFirst() }
            return period
        }
    }

    func testStandaloneSupplementIsRateLimitedAndDoesNotAdvancePrimary() async throws {
        var time = Date()
        let fetcher = PeriodFetcher(period: try period())
        let controller = SplitUsageController(now: { time }, fetchPeriod: { _ in try await fetcher.fetch() })
        let missing = summary(cursor: nil)
        controller.accept(summary: missing, usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
        let revision = controller.primarySnapshot?.identity.localID
        controller.requestAmounts(summary: missing, cookieHeader: "fixture")
        await eventually { controller.snapshot?.cursorPercent == 1.234 }
        XCTAssertNil(controller.primarySnapshot?.cursorPercent)
        XCTAssertEqual(controller.primarySnapshot?.identity.localID, revision)
        controller.requestAmounts(manual: true)
        time = time.addingTimeInterval(59)
        controller.requestAmounts(manual: true)
        let callsBeforeDeadline = await fetcher.calls
        XCTAssertEqual(callsBeforeDeadline, 1)
        time = time.addingTimeInterval(1)
        controller.requestAmounts(manual: true)
        await eventually { await fetcher.calls == 2 }
    }

    func testStandaloneSupplementDisablesRefreshUntilOwnedCompletionOrRetirement() async throws {
        actor PeriodGate {
            let period: CurrentPeriodUsageResponse
            var continuation: CheckedContinuation<Void, Never>?
            var started = false
            init(period: CurrentPeriodUsageResponse) { self.period = period }
            func fetch() async -> CurrentPeriodUsageResponse {
                started = true
                await withCheckedContinuation { continuation = $0 }
                return period
            }
            func release() { continuation?.resume(); continuation = nil }
        }
        for retire in [false, true] {
            let gate = PeriodGate(period: try period())
            let controller = SplitUsageController(fetchPeriod: { _ in await gate.fetch() })
            let missing = summary(cursor: nil)
            controller.accept(summary: missing, usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
            XCTAssertTrue(controller.canRefreshAmounts)
            controller.requestAmounts(summary: missing, cookieHeader: "fixture")
            await eventually { await gate.started }
            XCTAssertFalse(controller.canRefreshAmounts)
            XCTAssertEqual(controller.amountsRefreshStateText, "Refreshing percentages…")
            if retire {
                controller.suspend()
                controller.accept(summary: missing, usage: try usage(), userInfo: user, generation: 2, enterpriseScope: false)
                XCTAssertTrue(controller.canRefreshAmounts)
                XCTAssertEqual(controller.amountsRefreshStateText, "Refresh amounts")
            }
            await gate.release()
            await eventually { controller.canRefreshAmounts }
            XCTAssertEqual(controller.amountsRefreshStateText, "Refresh amounts")
        }
    }

    func testStandaloneTransportBackoffAndServerRetryAfter() async throws {
        for (errors, waits) in [([CycleEnrichmentError.transport, .transport], [60.0, 120.0]),
                                ([.http(status: 429, retryAfter: 300)], [300.0]),
                                ([.invalidResponse], [1800.0])] {
            var time = Date()
            let fetcher = PeriodFetcher(period: try period(), errors: errors)
            let controller = SplitUsageController(now: { time }, fetchPeriod: { _ in try await fetcher.fetch() })
            let missing = summary(cursor: nil)
            controller.accept(summary: missing, usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
            controller.requestAmounts(summary: missing, cookieHeader: "fixture")
            for (index, wait) in waits.enumerated() {
                await eventually { await fetcher.calls == index + 1 }
                for _ in 0..<30 { await Task.yield() }
                time = time.addingTimeInterval(wait - 1)
                controller.requestAmounts(manual: true)
                let before = await fetcher.calls
                XCTAssertEqual(before, index + 1)
                time = time.addingTimeInterval(1)
                controller.requestAmounts(manual: true)
            }
            await eventually { controller.snapshot?.cursorPercent == 1.234 }
        }
    }

    func testResetDeletesExplicitVerifiedSubjectBeforeStoreActivation() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let source = SplitUsageController()
        source.accept(summary: summary(), usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
        let snapshot = try XCTUnwrap(source.primarySnapshot)
        let writer = CycleUsageStore(fileURL: url)
        let operation = await writer.activate(identity: snapshot.identity, subjectDigest: snapshot.identity.accountDigest)
        try await writer.save(.init(identity: snapshot.identity, capturedAt: snapshot.capturedAt), operation: operation)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let controller = SplitUsageController(store: CycleUsageStore(fileURL: url))
        controller.reset(removePersisted: true, subjectDigest: snapshot.identity.accountDigest)
        await eventually { !FileManager.default.fileExists(atPath: url.path) }
    }

    private actor SupplementGate {
        var started = false
        var continuation: CheckedContinuation<Void, Never>?
        func wait() async {
            started = true
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { continuation?.resume(); continuation = nil }
    }

    func testPrimaryCompletionWhileSleepingCannotStartAmountOrPeriodRequests() async throws {
        actor Calls {
            var count = 0
            func record() { count += 1 }
        }
        for standalone in [false, true] {
            let calls = Calls()
            let period = try period()
            let collect: SplitUsageController.Collect = { _, _, _, _, _ in
                await calls.record()
                return .init(status: .complete, snapshot: nil, pageCount: 0, byteCount: 0)
            }
            let controller = SplitUsageController(collect: standalone ? nil : collect, fetchPeriod: { _ in
                await calls.record()
                return period
            })
            let missing = summary(cursor: nil)
            controller.prepareForSleep()
            controller.accept(summary: missing, usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
            controller.requestAmounts(summary: missing, cookieHeader: "fixture")
            for _ in 0..<20 { await Task.yield() }
            let sleepingCalls = await calls.count
            XCTAssertEqual(sleepingCalls, 0)
            controller.resumeAfterWake()
            controller.requestAmounts(summary: missing, cookieHeader: "fixture")
            await eventually { await calls.count == 1 }
        }
    }

    func testDelayedSupplementFillsEqualPrimaryRevisionAcrossAllDeliveryPaths() async throws {
        for path in ["callback", "result", "standalone"] {
            let gate = SupplementGate()
            let period = try period()
            let collect: SplitUsageController.Collect = { snapshot, summary, _, _, supplement in
                await gate.wait()
                let enriched = snapshot.supplemented(by: period, summary: summary, at: snapshot.capturedAt)
                if path == "callback" { await supplement(enriched) }
                return .init(status: .complete, snapshot: nil, pageCount: 0, byteCount: 0,
                    supplementarySnapshot: path == "result" ? enriched : nil)
            }
            let controller = SplitUsageController(collect: path == "standalone" ? nil : collect, fetchPeriod: { _ in
                await gate.wait()
                return period
            })
            let missing = summary(cursor: nil)
            controller.accept(summary: missing, usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
            let original = try XCTUnwrap(controller.primarySnapshot)
            controller.requestAmounts(summary: missing, cookieHeader: "fixture")
            await eventually { await gate.started }
            controller.accept(summary: missing, usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
            let latest = try XCTUnwrap(controller.primarySnapshot)
            XCTAssertNotEqual(original.identity.localID, latest.identity.localID, path)
            await gate.release()
            await eventually { !controller.isFetchingSupplement && controller.amountState != .refreshing }
            XCTAssertEqual(controller.snapshot?.cursorPercent, 1.234, path)
            XCTAssertEqual(controller.snapshot?.cursorSource, .period, path)
            XCTAssertNotNil(controller.snapshot?.periodCapturedAt, path)
            XCTAssertEqual(controller.snapshot?.identity, latest.identity, path)
            XCTAssertEqual(controller.primarySnapshot, latest, "Display enrichment must not mutate primary event evidence: \(path)")
        }
    }

    func testDelayedSupplementRejectsChangedEvidenceOwnershipAndExpiredSource() async throws {
        for change in ["amount", "percentage", "generation", "account", "expiry"] {
            var time = Date()
            let gate = SupplementGate()
            let period = try period()
            let controller = SplitUsageController(now: { time }, collect: { snapshot, summary, _, _, supplement in
                await gate.wait()
                await supplement(snapshot.supplemented(by: period, summary: summary, at: snapshot.capturedAt))
                return .init(status: .complete, snapshot: nil, pageCount: 0, byteCount: 0)
            })
            let missing = summary(cursor: nil)
            controller.accept(summary: missing, usage: try usage(), userInfo: user, generation: 1, enterpriseScope: false)
            controller.requestAmounts(summary: missing, cookieHeader: "fixture")
            await eventually { await gate.started }
            let changed: UsageSummaryResponse
            if change == "amount" {
                changed = try JSONDecoder().decode(UsageSummaryResponse.self, from: Data("""
                {"billingCycleStart":"2026-09-01T00:00:00Z","billingCycleEnd":"2026-10-01T00:00:00Z","membershipType":"ultra","individualUsage":{"plan":{"used":18201,"limit":40000,"apiPercentUsed":41}}}
                """.utf8))
            } else { changed = summary(cursor: nil, other: change == "percentage" ? 42 : 41) }
            if change == "expiry" { time = time.addingTimeInterval(601) }
            let identity = change == "account" ? UserInfoResponse(email: "second@example.test", name: nil, sub: "second") : user
            controller.accept(summary: changed, usage: try usage(), userInfo: identity,
                generation: change == "generation" ? 2 : 1, enterpriseScope: false)
            await gate.release()
            await eventually { controller.amountState != .refreshing }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertNil(controller.snapshot?.cursorPercent, change)
            XCTAssertNil(controller.primarySnapshot?.cursorPercent, change)
        }
    }

}
