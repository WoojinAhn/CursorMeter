import XCTest
@testable import CursorMeter

final class TodayUsageTests: XCTestCase {
    private let instant = UsageCycle.parse("2026-10-02T03:00:00Z")!

    func testDayUsesKSTMidnightAndExclusiveEndRegardlessOfSystemTimeZone() throws {
        let original = NSTimeZone.default
        defer { NSTimeZone.default = original }
        for zone in ["America/Los_Angeles", "UTC", "Asia/Seoul"] {
            NSTimeZone.default = TimeZone(identifier: zone)!
            let before = UsageCycle.parse("2026-10-01T14:59:59Z")!
            let midnight = before.addingTimeInterval(1)
            let oldDay = try XCTUnwrap(TodayUsageDay(containing: before))
            let newDay = try XCTUnwrap(TodayUsageDay(containing: midnight))
            XCTAssertEqual(oldDay.end, midnight)
            XCTAssertEqual(newDay.start, midnight)
            XCTAssertEqual(newDay.end, midnight.addingTimeInterval(86_400))
            XCTAssertTrue(oldDay.contains(before))
            XCTAssertFalse(oldDay.contains(midnight))
            XCTAssertTrue(newDay.contains(midnight))
            XCTAssertFalse(newDay.contains(newDay.end))
        }
        XCTAssertNil(TodayUsageDay(containing: Date(timeIntervalSince1970: .nan)))
    }

    func testAdmissionContextCapturesOneDay() throws {
        let context = try XCTUnwrap(TodayUsageCollectionContext(admittedAt: instant))
        XCTAssertEqual(context.admittedAt, instant)
        XCTAssertEqual(context.day, TodayUsageDay(containing: instant))
        XCTAssertNil(TodayUsageCollectionContext(admittedAt: Date(timeIntervalSince1970: .infinity)))
    }

    func testAllocationUsesRawPercentAndExactCostRatioWithoutEstimatedLimits() throws {
        let (primary, amounts) = fixture()
        let values = try XCTUnwrap(allocate(primary, amounts))
        XCTAssertEqual(try XCTUnwrap(values[.cursor]), 8, accuracy: 0.000000001)
        XCTAssertEqual(try XCTUnwrap(values[.other]), 10, accuracy: 0.000000001)
        XCTAssertNil(amounts.estimatedCursorLimitCents)
        XCTAssertNil(amounts.estimatedOtherLimitCents)
    }

    func testVerifiedZeroAllAndTinyTodayPreserveTrueAngles() throws {
        let (primary, original) = fixture()
        for (today, expected): (Decimal, Double) in [(0, 0), (21_000, 42), (Decimal(string: "0.000000001")!, 0.000000000002)] {
            var amounts = original
            amounts.todayUsage?.cursorCents = today
            let value = try XCTUnwrap(allocate(primary, amounts)?[.cursor])
            XCTAssertEqual(value, expected, accuracy: 0.0000000000001)
        }
    }

    func testPositivePercentWithZeroCycleCostWithholdsBothPools() {
        let (primary, original) = fixture()
        for pool in UsagePoolID.allCases {
            var amounts = original
            if pool == .cursor { amounts.cursorCents = 0; amounts.todayUsage?.cursorCents = 0 }
            else { amounts.otherCents = 0; amounts.todayUsage?.otherCents = 0 }
            let total = amounts.cursorCents + amounts.otherCents
            let updated = replacing(primary, included: total)
            amounts.todayUsage = dayDetail(cursor: amounts.todayUsage!.cursorCents, other: amounts.todayUsage!.otherCents, included: total)
            XCTAssertNil(allocate(updated, amounts))
        }
    }

    func testZeroPercentAndZeroCostOmitsOnlyThatPool() throws {
        let (primary, original) = fixture()
        var amounts = original
        amounts.cursorCents = 0
        amounts.sourceCursorPercent = 0
        amounts.todayUsage = dayDetail(cursor: 0, other: 5_000, included: 10_000)
        let updated = replacing(primary, cursor: 0, included: 10_000)
        let values = try XCTUnwrap(allocate(updated, amounts))
        XCTAssertNil(values[.cursor])
        XCTAssertEqual(values[.other], 10)
    }

    func testZeroReportedUsageHasNoSubdivisionEvenWithRecordedCosts() throws {
        let (primary, original) = fixture()
        var amounts = original
        amounts.sourceCursorPercent = 0
        let values = try XCTUnwrap(allocate(replacing(primary, cursor: 0), amounts))
        XCTAssertNil(values[.cursor])
        XCTAssertEqual(values[.other], 10)
        var empty = replacing(primary, cursor: 0, included: 0)
        empty.otherPercent = 0
        amounts.cursorCents = 0
        amounts.otherCents = 0
        amounts.sourceOtherPercent = 0
        amounts.todayUsage = dayDetail(cursor: 0, other: 0, included: 0)
        XCTAssertEqual(allocate(empty, amounts), [:])
    }

    func testFractionalCentsAreNotRoundedBeforeAllocation() throws {
        let (primary, original) = fixture()
        var amounts = original
        amounts.cursorCents = Decimal(string: "0.123456789123456789")!
        amounts.otherCents = Decimal(string: "0.876543210876543211")!
        amounts.todayUsage = dayDetail(cursor: Decimal(string: "0.0123456789123456789")!, other: 0, included: 1)
        let value = try XCTUnwrap(allocate(replacing(primary, included: 1), amounts)?[.cursor])
        XCTAssertEqual(value, 4.2, accuracy: 0.000000000001)
    }

    func testMissingAndUnsafeRawPercentagesWithholdBothPools() {
        let (primary, original) = fixture()
        for value: Double? in [nil, -1, .nan, .infinity, 100, 101] {
            for pool in UsagePoolID.allCases {
                var updated = primary
                var amounts = original
                if pool == .cursor { updated.cursorPercent = value; amounts.sourceCursorPercent = value }
                else { updated.otherPercent = value; amounts.sourceOtherPercent = value }
                XCTAssertNil(allocate(updated, amounts))
            }
        }
    }

    func testEffectiveSupplementPercentIsUsedAndMustMatchRawSource() throws {
        let (primary, original) = fixture()
        var updated = primary
        var amounts = original
        updated.otherPercent = 20.1234
        updated.otherSource = .period
        amounts.sourceOtherPercent = updated.otherPercent
        XCTAssertEqual(try XCTUnwrap(allocate(updated, amounts)?[.other]), 10.0617, accuracy: 0.00000001)
        amounts.sourceOtherPercent = 20.1235
        XCTAssertNil(allocate(updated, amounts))
        amounts = original
        amounts.sourceCursorPercent = 42.0001
        XCTAssertNil(allocate(primary, amounts))
    }

    func testMissingStaleCachedAndUnadmittedEvidenceWithholdsOverlay() {
        let (primary, original) = fixture()
        XCTAssertNil(TodayUsageAllocation.percentagePoints(snapshot: nil, amounts: original, primaryIsStale: false, currentSessionAndDemandEligible: true, now: instant))
        XCTAssertNil(TodayUsageAllocation.percentagePoints(snapshot: primary, amounts: nil, primaryIsStale: false, currentSessionAndDemandEligible: true, now: instant))
        XCTAssertNil(TodayUsageAllocation.percentagePoints(snapshot: primary, amounts: original, primaryIsStale: true, currentSessionAndDemandEligible: true, now: instant))
        XCTAssertNil(TodayUsageAllocation.percentagePoints(snapshot: primary, amounts: original, primaryIsStale: false, currentSessionAndDemandEligible: false, now: instant))
        var amounts = original
        amounts.isCached = true
        XCTAssertNil(allocate(primary, amounts))
        amounts = original
        amounts.todayUsage = nil
        XCTAssertNil(allocate(primary, amounts))
    }

    func testExpiredDayAndFutureEvidenceWithholdOverlayWithoutDiscardingCycleCosts() {
        let (primary, original) = fixture()
        var amounts = original
        XCTAssertNil(allocate(primary, amounts, now: amounts.todayUsage!.day.end))
        XCTAssertNil(allocate(primary, amounts, now: instant.addingTimeInterval(-1)))
        XCTAssertNil(allocate(primary, amounts, now: Date(timeIntervalSince1970: .nan)))
        XCTAssertEqual(amounts.cursorCents, 21_000)
        amounts.todayUsage = .init(day: amounts.todayUsage!.day, evidenceAt: instant.addingTimeInterval(1),
                                  cursorCents: 4_000, otherCents: 5_000, sourceIncludedTotalCents: 31_000)
        XCTAssertNil(allocate(primary, amounts))
    }

    func testSameOwnerNewPrimaryRevisionCanUseAdmittedReceipt() {
        let (primary, amounts) = fixture()
        let updated = replacing(primary, identity: identity(localID: 2))
        XCTAssertNotNil(allocate(updated, amounts))
    }

    func testScopeGenerationPlanAndClassifierMismatchesWithholdOverlay() {
        let (primary, original) = fixture()
        let identities = [identity(account: "other"), identity(scope: "other"), identity(generation: 2), identity(plan: "other"),
                          identity(cycle: UsageCycle(start: instant.addingTimeInterval(-10), end: instant.addingTimeInterval(10))!)]
        for identity in identities { XCTAssertNil(allocate(replacing(primary, identity: identity), original)) }
        var amounts = original
        amounts.classifierVersion -= 1
        XCTAssertNil(allocate(primary, amounts))
    }

    func testSourceIncludedTotalMustMatchEvenWhenPercentagesAreUnchanged() {
        let (primary, amounts) = fixture()
        XCTAssertNil(allocate(replacing(primary, included: 31_001), amounts))
        let missing = SplitUsageSnapshot(identity: primary.identity, capturedAt: instant, cursorPercent: 42, otherPercent: 20, includedUsedCents: nil)
        XCTAssertNil(allocate(missing, amounts))
    }

    func testUnresolvedPartialAndUnreconciledReceiptsWithholdBothPools() {
        let (primary, original) = fixture()
        let changes: [(inout CycleAmountSnapshot) -> Void] = [
            { $0.coverage.complete = false }, { $0.status = .unavailable },
            { $0.unknownCount = 1 }, { $0.unknownCents = 1 },
            { $0.residualCents = nil }, { $0.residualCents = 2 }, { $0.residualCents = .nan },
            { $0.cursorCents = 21_002 }, { $0.cursorCents = .nan }, { $0.otherCents = -1 }
        ]
        for change in changes {
            var amounts = original
            change(&amounts)
            XCTAssertNil(allocate(primary, amounts))
        }
    }

    func testInvalidDailyAmountsWithholdBothPools() {
        let (primary, original) = fixture()
        for today in [Decimal(-1), Decimal.nan, Decimal(21_001)] {
            var amounts = original
            amounts.todayUsage?.cursorCents = today
            XCTAssertNil(allocate(primary, amounts))
        }
        var amounts = original
        amounts.todayUsage = dayDetail(cursor: 4_000, other: 5_000, included: -1)
        XCTAssertNil(allocate(primary, amounts))
    }

    private func allocate(_ primary: SplitUsageSnapshot, _ amounts: CycleAmountSnapshot, now: Date? = nil) -> [UsagePoolID: Double]? {
        TodayUsageAllocation.percentagePoints(snapshot: primary, amounts: amounts, primaryIsStale: false,
                                              currentSessionAndDemandEligible: true, now: now ?? instant)
    }

    private func identity(localID: UInt64 = 1, account: String = "account", scope: String = "scope", generation: UInt64 = 1,
                          plan: String = "pro:100", cycle: UsageCycle? = nil) -> UsageRevisionIdentity {
        .init(localID: localID, credentialGeneration: generation, accountDigest: account, scopeDigest: scope,
              cycle: cycle ?? UsageCycle(start: instant.addingTimeInterval(-15 * 86_400), end: instant.addingTimeInterval(15 * 86_400)), planIdentity: plan)
    }

    private func dayDetail(cursor: Decimal, other: Decimal, included: Decimal) -> TodayUsageAggregate {
        .init(day: TodayUsageDay(containing: instant)!, evidenceAt: instant, cursorCents: cursor, otherCents: other,
              sourceIncludedTotalCents: included)
    }

    private func fixture() -> (SplitUsageSnapshot, CycleAmountSnapshot) {
        let primary = SplitUsageSnapshot(identity: identity(), capturedAt: instant, cursorPercent: 42, otherPercent: 20, includedUsedCents: 31_000)
        let amounts = CycleAmountSnapshot(identity: primary.identity, capturedAt: instant, cursorCents: 21_000, otherCents: 10_000,
                                          residualCents: 0, coverage: .init(complete: true), status: .estimatedAttribution,
                                          sourceCursorPercent: 42, sourceOtherPercent: 20,
                                          todayUsage: dayDetail(cursor: 4_000, other: 5_000, included: 31_000))
        return (primary, amounts)
    }

    private func replacing(_ source: SplitUsageSnapshot, identity: UsageRevisionIdentity? = nil, cursor: Double? = nil,
                           included: Decimal? = nil) -> SplitUsageSnapshot {
        .init(identity: identity ?? source.identity, capturedAt: source.capturedAt, cursorPercent: cursor ?? source.cursorPercent,
              otherPercent: source.otherPercent, includedUsedCents: included ?? source.includedUsedCents)
    }
}
