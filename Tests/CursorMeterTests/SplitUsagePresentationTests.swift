import Foundation
import XCTest
@testable import CursorMeter

final class SplitUsagePresentationTests: XCTestCase {
    func testHealthyHoverKeepsNamedPoolsAndReadablePercentWithoutDiagnostics() {
        let current = snapshot(cursor: 135.25, other: 0)
        let result = SplitUsagePresentation.make(snapshot: current)
        XCTAssertEqual(result.pools.map(\.id), [.other, .cursor])
        XCTAssertTrue(result.tooltip.contains("Other Models: 0.0%"))
        XCTAssertTrue(result.tooltip.contains("Cursor Models: 135.3%"))
        XCTAssertEqual(result.accessibilityValue, result.tooltip)
        for forbidden in ["Ready", "Percent refreshed", "Cycle:", "Coverage:", "residual", "private-account", "private-scope", "private-plan", "$400"] {
            XCTAssertFalse(result.tooltip.contains(forbidden), forbidden)
        }
    }

    func testReadablePercentagesPreserveZeroAndLimitBoundaries() {
        let cases: [(Double?, String)] = [
            (nil, "—"), (.nan, "—"), (.infinity, "—"), (-.infinity, "—"), (-1, "—"),
            (-0.0, "0.0%"), (0, "0.0%"), (Double.leastNonzeroMagnitude, "<0.1%"),
            (0.049, "<0.1%"), (0.0999, "<0.1%"), (0.1, "0.1%"),
            (29, "29.0%"), (23.1, "23.1%"), (29.04, "29.0%"),
            (1.977667, "2.0%"), (26.734, "26.7%"), (2.5, "2.5%"),
            (99.94, "99.9%"), (99.95, "<100.0%"), (99.99, "<100.0%"),
            (100, "100.0%"), (100.01, ">100.0%"), (100.05, "100.1%"), (135.25, "135.3%"),
        ]
        for (value, expected) in cases {
            let result = SplitUsagePresentation.make(snapshot: snapshot(cursor: value, other: 41))
            XCTAssertEqual(result.pools.first { $0.id == .cursor }?.percentText, expected, "Input: \(String(describing: value))")
        }
    }

    func testRoundedDisplayDoesNotMakeMismatchedEstimateCurrent() {
        let current = snapshot(cursor: 10.001, other: 41)
        let result = SplitUsagePresentation.make(snapshot: current, amounts: estimatedAmounts(for: current),
                                                amountState: .ready, showEstimatedLimits: true)
        let cursor = result.pools.first { $0.id == .cursor }
        XCTAssertEqual(cursor?.percentText, "10.0%")
        XCTAssertNil(cursor?.limitText)
    }

    func testDefaultHidesInferredLimitsButRetainsRecordedCosts() {
        let current = snapshot(cursor: 10, other: 41)
        let result = SplitUsagePresentation.make(snapshot: current, amounts: estimatedAmounts(for: current), amountState: .ready)
        XCTAssertEqual(result.pools.first { $0.id == .cursor }?.amountText, "$10.00")
        XCTAssertTrue(result.pools.allSatisfy { $0.limitText == nil })
        XCTAssertFalse(result.tooltip.contains("Estimate"))
    }

    func testMissingValuesRemainUnavailableAndFailureRetainsPercent() {
        let result = SplitUsagePresentation.make(snapshot: snapshot(cursor: nil, other: 41), amountState: .failed, percentIsStale: true)
        XCTAssertEqual(result.pools.first { $0.id == .cursor }?.percentText, "—")
        XCTAssertTrue(result.tooltip.contains("41.0%"))
        XCTAssertTrue(result.tooltip.contains("Couldn't update costs"))
        XCTAssertTrue(result.tooltip.contains("Usage may be out of date"))
        XCTAssertTrue(result.pools.allSatisfy { $0.amountText == nil && $0.limitText == nil })
    }

    func testOptInShowsWholeDollarLimitsOnlyForMatchingCurrentPercentages() {
        let current = snapshot(cursor: 11, other: 41)
        let result = SplitUsagePresentation.make(snapshot: current, amounts: estimatedAmounts(for: current), amountState: .refreshing, showEstimatedLimits: true)
        let cursor = result.pools.first { $0.id == .cursor }!
        XCTAssertEqual(cursor.amountText, "$10.00")
        XCTAssertNil(cursor.limitText)
        XCTAssertEqual(result.pools.first { $0.id == .other }?.limitText, "~$200")
        XCTAssertTrue(result.tooltip.contains("Showing earlier costs"))
        XCTAssertFalse(result.tooltip.contains("snapshot"))
    }

    func testNewerSummaryWithUnchangedPercentagesDoesNotMakeCostsOld() {
        let current = snapshot(cursor: 10, other: 41)
        var amounts = estimatedAmounts(for: current)
        amounts.isCached = false
        let unchanged = SplitUsagePresentation.make(snapshot: current, amounts: amounts, amountState: .ready,
            showEstimatedLimits: true)
        XCTAssertFalse(unchanged.tooltip.contains("Showing earlier costs"))
        XCTAssertEqual(unchanged.pools.first { $0.id == .cursor }?.limitText, "~$100")
        let changed = SplitUsagePresentation.make(snapshot: snapshot(cursor: 11, other: 41), amounts: amounts,
            amountState: .ready, showEstimatedLimits: true)
        XCTAssertTrue(changed.tooltip.contains("Showing earlier costs"))
        XCTAssertNil(changed.pools.first { $0.id == .cursor }?.limitText)
        amounts.sourceOtherPercent = nil
        let uncertain = SplitUsagePresentation.make(snapshot: current, amounts: amounts, amountState: .ready)
        XCTAssertTrue(uncertain.tooltip.contains("Showing earlier costs"))
    }

    func testHealthyCurrentCostsUseWholeDollarEstimateWithoutStatusParagraph() {
        let current = snapshot(cursor: 10, other: 41)
        let amounts = CycleAmountSnapshot(identity: current.identity, capturedAt: current.capturedAt,
            cursorCents: 1000, otherCents: 8000,
            coverage: CycleCoverage(complete: true, pageCount: 1, eventCount: 20),
            status: .estimatedAttribution, estimatedCursorLimitCents: Decimal(string: "10049.99"),
            estimatedOtherLimitCents: Decimal(string: "20050"), sourceCursorPercent: 10, sourceOtherPercent: 41)
        let result = SplitUsagePresentation.make(snapshot: current, amounts: amounts, amountState: .ready,
            valueMode: .dollars, showEstimatedLimits: true)
        let cursor = result.pools.first { $0.id == .cursor }!
        XCTAssertEqual(cursor.readoutText, "$10.00")
        XCTAssertEqual(cursor.detailText, "of ~$100")
        XCTAssertEqual(result.pools.first { $0.id == .other }?.limitText, "~$201")
        XCTAssertEqual(result.detailLines, ["Included total: $182.00"])
        XCTAssertFalse(result.tooltip.contains("Ready"))
        XCTAssertFalse(result.tooltip.contains("unavailable"))
    }

    func testOptInPreservesSourceAndSpilloverGates() {
        for (cursor, other) in [(nil, 41.0), (10.0, nil), (100.0, 41.0), (10.0, 100.0), (135.0, 41.0), (10.0, Double.nan)] as [(Double?, Double?)] {
            let current = snapshot(cursor: cursor, other: other)
            let result = SplitUsagePresentation.make(snapshot: current, amounts: estimatedAmounts(for: current), amountState: .ready, showEstimatedLimits: true)
            XCTAssertTrue(result.pools.allSatisfy { $0.limitText == nil })
            XCTAssertTrue(result.pools.allSatisfy { $0.amountText != nil })
        }
        let current = snapshot(cursor: 10, other: 41)
        var amounts = estimatedAmounts(for: current)
        amounts.sourceOtherPercent = nil
        let result = SplitUsagePresentation.make(snapshot: current, amounts: amounts, amountState: .ready, showEstimatedLimits: true)
        XCTAssertNil(result.pools.first { $0.id == .other }?.limitText)
        XCTAssertEqual(result.pools.first { $0.id == .cursor }?.limitText, "~$100")
    }

    func testValueModesChangeReadingsWithoutChangingPercentOrAvailability() {
        let current = snapshot(cursor: 10, other: 41)
        for mode in PopoverValueMode.allCases {
            let result = SplitUsagePresentation.make(snapshot: current, amounts: estimatedAmounts(for: current), amountState: .ready, valueMode: mode)
            let cursor = result.pools.first { $0.id == .cursor }!
            XCTAssertEqual(cursor.percentText, "10.0%")
            XCTAssertEqual(cursor.amountText, "$10.00")
            XCTAssertEqual(cursor.readoutText, mode == .dollars ? "$10.00" : "10.0%")
            XCTAssertEqual(cursor.detailText, mode == .both ? "$10.00" : nil)
            XCTAssertTrue(result.tooltip.contains("10.0%"))
            XCTAssertEqual(result.tooltip.contains("$10.00"), mode != .percent)
        }
        let missing = SplitUsagePresentation.make(snapshot: current, valueMode: .dollars)
        XCTAssertTrue(missing.pools.allSatisfy { $0.readoutText == "—" })
    }

    func testPartialOrForeignAmountsNeverBecomePoolAmountsOrLimits() {
        let current = snapshot(cursor: 10, other: 41)
        var amounts = estimatedAmounts(for: current)
        amounts.status = .unavailable
        let partial = SplitUsagePresentation.make(snapshot: current, amounts: amounts, amountState: .ready, showEstimatedLimits: true)
        XCTAssertTrue(partial.pools.allSatisfy { $0.amountText == nil && $0.limitText == nil })
        XCTAssertFalse(partial.tooltip.contains("Coverage"))
        let foreign = CycleAmountSnapshot(identity: UsageRevisionIdentity(localID: 1, credentialGeneration: 2, accountDigest: "foreign", scopeDigest: "private-scope", cycle: current.identity.cycle, planIdentity: "private-plan"), capturedAt: current.capturedAt, cursorCents: 9999, status: .estimatedAttribution)
        let result = SplitUsagePresentation.make(snapshot: current, amounts: foreign, amountState: .ready, showEstimatedLimits: true)
        XCTAssertFalse(result.tooltip.contains("$99.99"))
        XCTAssertTrue(result.pools.allSatisfy { $0.amountText == nil && $0.limitText == nil })
    }

    func testPaidAndBotStaySeparateAndEmptyDisabledPaidIsHidden() {
        let current = snapshot(cursor: 10, other: 41)
        var amounts = estimatedAmounts(for: current)
        amounts.botCents = 300
        let result = SplitUsagePresentation.make(snapshot: current, amounts: amounts, paid: SplitPaidPresentation(enabled: false, usedCents: 500, limitCents: 1000))
        XCTAssertTrue(result.detailLines.contains("Bot activity: $3.00"))
        XCTAssertTrue(result.detailLines.contains("Paid spending: $5.00 · Disabled"))
        XCTAssertTrue(result.detailLines.contains("Included total: $182.00"))
        let empty = SplitUsagePresentation.make(snapshot: current, paid: SplitPaidPresentation(enabled: false, usedCents: 0, limitCents: 1000))
        XCTAssertFalse(empty.tooltip.contains("Paid spending"))
        let uncapped = SplitUsagePresentation.make(snapshot: current, paid: SplitPaidPresentation(enabled: true, usedCents: 234, limitCents: nil))
        XCTAssertTrue(uncapped.tooltip.contains("Paid spending: $2.34"))
        XCTAssertFalse(uncapped.tooltip.contains("/ $0"))
        let percentOnly = SplitUsagePresentation.make(snapshot: current, paid: SplitPaidPresentation(enabled: false, usedCents: 500, limitCents: nil), valueMode: .percent)
        XCTAssertTrue(percentOnly.detailLines.contains("Paid spending: $5.00 · Disabled"))
    }

    func testPartialBotTotalsStayHiddenAndCostStatusDoesNotStack() {
        let current = snapshot(cursor: 11, other: 41)
        var amounts = estimatedAmounts(for: current)
        amounts.botCents = 300
        amounts.status = .unavailable
        amounts.coverage.complete = false
        let partial = SplitUsagePresentation.make(snapshot: current, amounts: amounts, amountState: .ready,
                                                   showEstimatedLimits: true)
        XCTAssertEqual(partial.detailLines, ["Included total: $182.00", "Costs unavailable"])
        amounts.status = .estimatedAttribution
        amounts.coverage.complete = true
        let old = SplitUsagePresentation.make(snapshot: current, amounts: amounts, amountState: .ready,
                                               showEstimatedLimits: true)
        XCTAssertEqual(old.detailLines, ["Included total: $182.00", "Bot activity: $3.00", "Showing earlier costs"])
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
