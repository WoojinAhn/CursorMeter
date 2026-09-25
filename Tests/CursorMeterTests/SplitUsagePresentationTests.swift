import Foundation
import XCTest
@testable import CursorMeter

final class SplitUsagePresentationTests: XCTestCase {
    func testDefaultOrderAndAccessibleIdentityRetainTruePercentAboveOneHundred() {
        let result = SplitUsagePresentation.make(snapshot: snapshot(cursor: 135.25, other: 0))
        XCTAssertEqual(result.pools.map(\.id), [.other, .cursor])
        XCTAssertEqual(result.pools.map(\.position), [.outer, .center])
        XCTAssertEqual(result.pools[0].percentText, "0%")
        XCTAssertEqual(result.pools[1].percentText, "135.25%")
        XCTAssertTrue(result.tooltip.contains("Other Models (outer ring): 0%"))
        XCTAssertTrue(result.tooltip.contains("Cursor Models (center pie): 135.25%"))
        XCTAssertEqual(result.accessibilityValue, result.tooltip)
        XCTAssertFalse(result.tooltip.contains("private-account"))
        XCTAssertFalse(result.tooltip.contains("private-scope"))
        XCTAssertFalse(result.tooltip.contains("private-plan"))
        XCTAssertFalse(result.tooltip.contains("$400"))
    }

    func testSwapAndMissingRemainStableAcrossValues() {
        let result = SplitUsagePresentation.make(snapshot: snapshot(cursor: nil, other: 3), outerPool: .cursor)
        XCTAssertEqual(result.pools.map(\.id), [.cursor, .other])
        XCTAssertEqual(result.pools[0].percentText, "Unavailable")
        XCTAssertTrue(result.tooltip.contains("Cursor Models (outer ring): Unavailable"))
        XCTAssertTrue(result.tooltip.contains("Other Models (center pie): 3%"))
    }

    func testPendingAndFailedHistoryDoNotHideValidPercentages() {
        let pending = SplitUsagePresentation.make(snapshot: snapshot(cursor: 10, other: 41), amountState: .pending)
        XCTAssertTrue(pending.tooltip.contains("Amounts: Pending"))
        XCTAssertTrue(pending.tooltip.contains("10%"))
        let failed = SplitUsagePresentation.make(
            snapshot: snapshot(cursor: 10, other: 41), amountState: .failed, percentIsStale: true,
            timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertTrue(failed.tooltip.contains("Percent refreshed: 2026-09-26 10:00:00 GMT (stale)"))
        XCTAssertTrue(failed.tooltip.contains("Amounts: Refresh failed"))
        XCTAssertTrue(failed.pools.allSatisfy { $0.amountText == nil && $0.limitText == nil })
    }

    func testPaidActualIsSeparateFromIncludedAndNoCapIsHonest() {
        let result = SplitUsagePresentation.make(
            snapshot: snapshot(cursor: 10, other: 41),
            paid: SplitPaidPresentation(enabled: true, usedCents: Decimal(string: "234.5")!, limitCents: nil))
        XCTAssertTrue(result.tooltip.contains("Included total: $182.00"))
        XCTAssertTrue(result.tooltip.contains("Paid spending: $2.35 · No budget cap"))
        XCTAssertFalse(result.tooltip.contains("$400"))
        let disabled = SplitUsagePresentation.make(
            snapshot: snapshot(cursor: 10, other: 41),
            paid: SplitPaidPresentation(enabled: false, usedCents: 500, limitCents: 1000))
        XCTAssertTrue(disabled.tooltip.contains("Paid spending: $5.00 · Disabled; residual spending"))
    }

    func testUnknownPaidEnabledStateDoesNotClaimDisabledOrBudgetRatio() {
        let result = SplitUsagePresentation.make(
            snapshot: snapshot(cursor: 10, other: 41),
            paid: SplitPaidPresentation(enabled: nil, usedCents: 500, limitCents: 1000))
        XCTAssertTrue(result.tooltip.contains("Paid spending: $5.00 · Availability unknown"))
        XCTAssertFalse(result.tooltip.contains("Disabled"))
        XCTAssertFalse(result.tooltip.contains("/ $10.00"))
    }

    func testOlderCachedAmountsKeepTheirSourceTimeButHideEstimateForChangedPoolPercentage() {
        let current = snapshot(cursor: 11, other: 41)
        let amounts = estimatedAmounts(for: current)
        let result = SplitUsagePresentation.make(
            snapshot: current, amounts: amounts, amountState: .refreshing,
            timeZone: TimeZone(secondsFromGMT: 0)!)
        let cursor = result.pools.first { $0.id == .cursor }!
        XCTAssertEqual(cursor.percentText, "11%")
        XCTAssertEqual(cursor.amountText, "$10.00")
        XCTAssertNil(cursor.limitText)
        XCTAssertTrue(cursor.statusText.contains("Cached"))
        XCTAssertTrue(cursor.statusText.contains("Estimate stale"))
        XCTAssertEqual(result.pools.first { $0.id == .other }?.limitText, "~$200.00")
        XCTAssertTrue(result.tooltip.contains("Amount snapshot: 2026-09-26 09:50:00 GMT"))
        XCTAssertTrue(result.tooltip.contains("Percent refreshed: 2026-09-26 10:00:00 GMT"))
        XCTAssertTrue(result.tooltip.contains("Older amount snapshot; percentages refreshed separately"))
        XCTAssertTrue(result.tooltip.contains("Estimated from this cycle; model attribution may differ"))
        XCTAssertFalse(result.tooltip.contains("~$100.00"))
        XCTAssertFalse(result.tooltip.contains("~$90.91"))
    }

    func testEqualPercentagesKeepExistingEstimatesAcrossNewPrimaryRevisions() {
        let current = snapshot(cursor: 10, other: 41)
        let amounts = estimatedAmounts(for: current)
        XCTAssertNotEqual(amounts.identity.localID, current.identity.localID)
        let result = SplitUsagePresentation.make(snapshot: current, amounts: amounts, amountState: .ready)
        XCTAssertEqual(result.pools.first { $0.id == .cursor }?.limitText, "~$100.00")
        XCTAssertEqual(result.pools.first { $0.id == .other }?.limitText, "~$200.00")
        XCTAssertTrue(result.pools.allSatisfy { !$0.statusText.contains("Estimate stale") })
    }

    func testMissingSourcePercentageCannotBeInterpretedAsTheCurrentPercentage() {
        let current = snapshot(cursor: 10, other: 41)
        var amounts = estimatedAmounts(for: current)
        amounts.sourceOtherPercent = nil
        let result = SplitUsagePresentation.make(snapshot: current, amounts: amounts, amountState: .ready)
        let other = result.pools.first { $0.id == .other }!
        XCTAssertNil(other.limitText)
        XCTAssertEqual(other.amountText, "$80.00")
        XCTAssertTrue(other.statusText.contains("Estimate stale"))
        XCTAssertEqual(result.pools.first { $0.id == .cursor }?.limitText, "~$100.00")
    }

    func testMissingOrExhaustedCurrentPoolSuppressesBothEstimatesButRetainsAmounts() {
        let values: [(Double?, Double?)] = [
            (nil, 41), (10, nil), (100, 41), (10, 100), (135, 41), (10, .nan),
        ]
        for (cursor, other) in values {
            let current = snapshot(cursor: cursor, other: other)
            let result = SplitUsagePresentation.make(
                snapshot: current, amounts: estimatedAmounts(for: current), amountState: .ready)
            XCTAssertTrue(result.pools.allSatisfy { $0.limitText == nil })
            XCTAssertTrue(result.pools.allSatisfy { $0.amountText != nil })
            XCTAssertTrue(result.pools.allSatisfy { $0.statusText.contains("Estimate stale") })
        }
    }

    func testPeriodPercentageReportsItsOwnSourceTimeInBothPlacements() {
        var current = snapshot(cursor: 10, other: 41)
        current.otherSource = .period
        current.periodCapturedAt = current.capturedAt.addingTimeInterval(300)
        for outer in UsagePoolID.allCases {
            let result = SplitUsagePresentation.make(
                snapshot: current, outerPool: outer, timeZone: TimeZone(secondsFromGMT: 0)!)
            let other = result.pools.first { $0.id == .other }!
            XCTAssertEqual(other.sourceText, "Percent source: Current period · 2026-09-26 10:05:00 GMT")
            XCTAssertTrue(other.line.contains("Percent source: Current period · 2026-09-26 10:05:00 GMT"))
            XCTAssertTrue(result.tooltip.contains("Primary summary refreshed: 2026-09-26 10:00:00 GMT"))
            XCTAssertEqual(result.accessibilityValue, result.tooltip)
            XCTAssertNil(result.pools.first { $0.id == .cursor }?.sourceText)
        }
    }

    func testPeriodWithoutCaptureTimeDoesNotBorrowPrimaryTime() {
        var current = snapshot(cursor: 10, other: 41)
        current.cursorSource = .period
        let result = SplitUsagePresentation.make(snapshot: current, timeZone: TimeZone(secondsFromGMT: 0)!)
        let cursor = result.pools.first { $0.id == .cursor }!
        XCTAssertEqual(cursor.sourceText, "Percent source: Current period · Time unavailable")
        XCTAssertFalse(cursor.line.contains("10:00:00"))
    }

    func testPartialUnknownAndResidualAreExplicitWithoutClaimingVerifiedBotOrPaidTotals() {
        let current = snapshot(cursor: 10, other: 41)
        let amounts = CycleAmountSnapshot(
            identity: current.identity, capturedAt: current.capturedAt,
            cursorCents: 10, otherCents: 20, botCents: 30, paidCents: 40,
            unknownCents: Decimal(string: "12.5")!, unknownCount: 2,
            residualCents: Decimal(string: "1.25")!,
            coverage: CycleCoverage(complete: false, pageCount: 1, eventCount: 12, reason: "Budget exceeded"),
            status: .unavailable)
        let result = SplitUsagePresentation.make(snapshot: current, amounts: amounts, amountState: .ready)
        XCTAssertTrue(result.tooltip.contains("Coverage: Partial · 12 events / 1 pages"))
        XCTAssertTrue(result.tooltip.contains("Unknown: $0.13 · 2 events"))
        XCTAssertTrue(result.tooltip.contains("Reconciliation residual: 1.25 cents"))
        XCTAssertTrue(result.tooltip.contains("Bot observed cycle activity: $0.30"))
        XCTAssertTrue(result.tooltip.contains("Paid observed history: $0.40"))
        XCTAssertTrue(result.tooltip.contains("Observed activity only; coverage is partial"))
        XCTAssertTrue(result.tooltip.contains("Cursor Models observed family subtotal: $0.10"))
        XCTAssertTrue(result.pools.allSatisfy { $0.amountText == nil })
        XCTAssertTrue(result.pools.allSatisfy { $0.limitText == nil })
    }

    func testAmountsFromDifferentAccountOrCycleNeverAppear() {
        let current = snapshot(cursor: 10, other: 41)
        let identity = UsageRevisionIdentity(
            localID: 2, credentialGeneration: 1, accountDigest: "another-account",
            scopeDigest: current.identity.scopeDigest, cycle: current.identity.cycle,
            planIdentity: current.identity.planIdentity)
        let amounts = CycleAmountSnapshot(
            identity: identity, capturedAt: current.capturedAt,
            cursorCents: 9999, status: .estimatedAttribution)
        let result = SplitUsagePresentation.make(snapshot: current, amounts: amounts, amountState: .ready)
        XCTAssertFalse(result.tooltip.contains("$99.99"))
        XCTAssertTrue(result.pools.allSatisfy { $0.amountText == nil })
        XCTAssertTrue(result.tooltip.contains("Amounts: Unavailable"))
    }

    private func snapshot(cursor: Double?, other: Double?) -> SplitUsageSnapshot {
        SplitUsageSnapshot(
            identity: UsageRevisionIdentity(
                localID: 2, credentialGeneration: 1, accountDigest: "private-account",
                scopeDigest: "private-scope", cycle: UsageCycle(
                    start: Date(timeIntervalSince1970: 1_788_220_800),
                    end: Date(timeIntervalSince1970: 1_790_812_800)), planIdentity: "private-plan"),
            capturedAt: Date(timeIntervalSince1970: 1_790_416_800),
            cursorPercent: cursor, otherPercent: other, includedUsedCents: 18200)
    }

    private func estimatedAmounts(for current: SplitUsageSnapshot) -> CycleAmountSnapshot {
        let source = current.identity
        let identity = UsageRevisionIdentity(
            localID: source.localID - 1, credentialGeneration: source.credentialGeneration,
            accountDigest: source.accountDigest, scopeDigest: source.scopeDigest,
            cycle: source.cycle, planIdentity: source.planIdentity)
        return CycleAmountSnapshot(
            identity: identity, capturedAt: current.capturedAt.addingTimeInterval(-600),
            cursorCents: 1000, otherCents: 8000,
            coverage: CycleCoverage(complete: true, pageCount: 3, eventCount: 210),
            status: .estimatedAttribution, estimatedCursorLimitCents: 10000,
            estimatedOtherLimitCents: 20000, isCached: true,
            sourceCursorPercent: 10, sourceOtherPercent: 41)
    }
}
