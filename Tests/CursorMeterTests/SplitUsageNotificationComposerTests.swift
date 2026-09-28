import XCTest
@testable import CursorMeter

final class SplitUsageNotificationComposerTests: XCTestCase {
    private let owner = SplitAlertOwnership(accountDigest: "account", requestPlanScope: "personal", generation: 1)
    private let policy = SplitAlertPolicy(bold: true)

    private func sample(_ revision: UInt64, included: Double? = 0, cursor: Double? = 0,
                        other: Double? = 0, paid: Double? = nil, cap: Double? = nil,
                        enabled: Bool? = nil) -> SplitUsageObservation {
        SplitUsageObservation(ownership: owner, revision: revision,
            timestamp: Date(timeIntervalSince1970: Double(revision) * 60),
            includedCents: included, cursorPercent: cursor, otherPercent: other,
            paidCents: paid, paidCapCents: cap, paidEnabled: enabled)
    }

    private func content(_ batch: SplitUsageEventBatch) -> UsageNotificationContent? {
        SplitUsageNotificationComposer.compose(thresholds: batch.thresholds, bold: batch.boldJump)
    }

    func testWarningSeparatesActualUsageFromConfiguredLevel() {
        var engine = SplitUsageAlertEngine()
        let batch = engine.accept(sample(1, cursor: 82), policy: policy)
        XCTAssertEqual(content(batch), .init(title: "Cursor Models 82.0% · Warning",
                                             body: "Your warning level is 80%."))
        XCTAssertEqual(batch.thresholds.first?.observationRevision, 1)
        XCTAssertEqual(batch.thresholds.first?.percent, 82)
        XCTAssertEqual(batch.thresholds.first?.configuredPercent, 80)
    }

    func testTinyIncludedDoesNotHeadlineOrJoinQualifyingCursor() {
        var engine = SplitUsageAlertEngine()
        _ = engine.accept(sample(1, included: 100, cursor: 10), policy: policy)
        let batch = engine.accept(sample(2, included: 101, cursor: 25), policy: policy)
        XCTAssertEqual(content(batch), .init(title: "Cursor Models increased",
                                             body: "Last refresh 10.0% → now 25.0%"))
        XCTAssertEqual(batch.boldJump?.signals.first { $0.scope == .included }?.tier, 0)
        XCTAssertEqual(batch.boldJump?.deltas[.included], 1)
    }

    func testCapturedRawReferencesSurviveFurtherObservations() {
        var engine = SplitUsageAlertEngine()
        _ = engine.accept(sample(1, cursor: 1.002), policy: policy)
        let batch = engine.accept(sample(2, cursor: 16.002), policy: policy)
        _ = engine.accept(sample(3, cursor: 31.002), policy: policy)
        let cursor = batch.boldJump?.signals.first { $0.scope == .cursor }
        XCTAssertEqual(batch.boldJump?.observationRevision, 2)
        XCTAssertEqual(cursor?.referenceValue, 1.002)
        XCTAssertEqual(cursor?.currentValue, 16.002)
        XCTAssertEqual(cursor?.delta, 15)
        XCTAssertEqual(content(batch), .init(title: "Cursor Models increased",
                                             body: "Last refresh 1.0% → now 16.0%"))
    }

    func testCorrectedPercentageUsesPreviousPeak() {
        var engine = SplitUsageAlertEngine()
        _ = engine.accept(sample(1, cursor: 50), policy: policy)
        _ = engine.accept(sample(2, cursor: 40), policy: policy)
        let batch = engine.accept(sample(3, cursor: 65), policy: policy)
        XCTAssertEqual(content(batch), .init(title: "Cursor Models increased",
                                             body: "Previous peak 50.0% → now 65.0%"))
        XCTAssertEqual(batch.boldJump?.signals.first { $0.scope == .cursor }?.referenceValue, 50)
        XCTAssertTrue(batch.boldJump?.signals.first { $0.scope == .cursor }?.corrected == true)
    }

    func testCorrectedSecondaryPercentageExplicitlyLabelsPeak() {
        var engine = SplitUsageAlertEngine()
        _ = engine.accept(sample(1, cursor: 50, other: 20), policy: policy)
        _ = engine.accept(sample(2, cursor: 40, other: 20), policy: policy)
        let batch = engine.accept(sample(3, cursor: 65, other: 35), policy: policy)
        XCTAssertEqual(content(batch), .init(title: "Other Models increased",
                                             body: "Last refresh 20.0% → now 35.0%\nCursor Models: peak 50.0% → 65.0%"))
    }

    func testDollarIncreaseDoesNotInventMissingPercentSnapshots() {
        var engine = SplitUsageAlertEngine()
        _ = engine.accept(sample(1, included: 1000, cursor: nil, other: nil), policy: policy)
        let batch = engine.accept(sample(2, included: 1040, cursor: nil, other: nil), policy: policy)
        XCTAssertEqual(content(batch), .init(title: "Included usage increased", body: "+$0.40 since last refresh"))
        XCTAssertEqual(batch.boldJump?.signals.map(\.scope), [.included])
    }

    func testCorrectedMoneyRetainsDeltaAndPeakBasis() {
        var engine = SplitUsageAlertEngine()
        _ = engine.accept(sample(1, included: 1000), policy: policy)
        _ = engine.accept(sample(2, included: 900), policy: policy)
        let batch = engine.accept(sample(3, included: 1040), policy: policy)
        XCTAssertEqual(content(batch), .init(title: "Included usage increased", body: "+$0.40 above previous peak"))
    }

    func testThreeThresholdsDisplaceAllBoldDetails() {
        var engine = SplitUsageAlertEngine()
        _ = engine.accept(sample(1, included: 0, cursor: 60, other: 60, paid: 800, cap: 1000, enabled: true), policy: policy)
        let batch = engine.accept(sample(2, included: 40, cursor: 93, other: 82, paid: 930, cap: 1000, enabled: true), policy: policy)
        XCTAssertEqual(content(batch), .init(title: "Paid budget 93.0% · Critical",
                                             body: "$9.30 of $10.00 · alert at 90%\nCursor Models 93.0% · Critical\nOther Models 82.0% · Warning"))
        XCTAssertEqual(batch.thresholds.first { $0.scope == .onDemand }?.usedCents, 930)
        XCTAssertEqual(batch.thresholds.first { $0.scope == .onDemand }?.limitCents, 1000)
    }

    func testEqualSeverityUsesPaidOtherCursorOrder() {
        var engine = SplitUsageAlertEngine()
        let batch = engine.accept(sample(1, cursor: 95, other: 96, paid: 970, cap: 1000, enabled: true), policy: policy)
        XCTAssertEqual(content(batch), .init(title: "Paid budget 97.0% · Critical",
                                             body: "$9.70 of $10.00 · alert at 90%\nOther Models 96.0% · Critical\nCursor Models 95.0% · Critical"))
    }

    func testCriticalOutranksHigherPercentageWarning() {
        var engine = SplitUsageAlertEngine()
        var custom = policy
        custom.thresholdsByScope = [.cursor: .init(warning: 50, critical: 60), .other: .init(warning: 80, critical: 95)]
        let batch = engine.accept(sample(1, cursor: 65, other: 90), policy: custom)
        XCTAssertEqual(content(batch), .init(title: "Cursor Models 65.0% · Critical",
                                             body: "Your critical level is 60%.\nOther Models 90.0% · Warning"))
    }

    func testThresholdRowsComeBeforeOrderedQualifiedIncreases() {
        var engine = SplitUsageAlertEngine()
        _ = engine.accept(sample(1, cursor: 60, other: 10, paid: 100, cap: 1000, enabled: true), policy: policy)
        let batch = engine.accept(sample(2, cursor: 82, other: 25, paid: 130, cap: 1000, enabled: true), policy: policy)
        XCTAssertEqual(content(batch), .init(title: "Cursor Models 82.0% · Warning",
                                             body: "Your warning level is 80%.\nPaid spending: +$0.30 since last refresh\nOther Models: 10.0% → 25.0%"))
    }

    func testSameScopeThresholdAndBoldUseSingleLabel() {
        var engine = SplitUsageAlertEngine()
        _ = engine.accept(sample(1, cursor: 60), policy: policy)
        let batch = engine.accept(sample(2, cursor: 82), policy: policy)
        XCTAssertEqual(content(batch), .init(title: "Cursor Models 82.0% · Warning",
                                             body: "Your warning level is 80%.\nLast refresh 60.0% → now 82.0%"))
    }

    func testPaidRelativeOnlyTierTwoIsNotLostByAbsoluteFiltering() {
        var engine = SplitUsageAlertEngine()
        _ = engine.accept(sample(1, paid: 10, cap: 100, enabled: true), policy: policy)
        let batch = engine.accept(sample(2, paid: 25, cap: 100, enabled: true), policy: policy)
        XCTAssertEqual(batch.boldJump?.signals.first?.delta, 15)
        XCTAssertEqual(batch.boldJump?.signals.first?.tier, 2)
        XCTAssertEqual(content(batch), .init(title: "Paid spending increased", body: "+$0.15 since last refresh"))
    }

    func testPaidAbsoluteTierTwoNeedsNoCap() {
        var engine = SplitUsageAlertEngine()
        _ = engine.accept(sample(1, paid: 0, enabled: true), policy: policy)
        let batch = engine.accept(sample(2, paid: 30, enabled: true), policy: policy)
        XCTAssertEqual(content(batch), .init(title: "Paid spending increased", body: "+$0.30 since last refresh"))
        XCTAssertTrue(batch.thresholds.isEmpty)
    }

    func testFourQualifyingIncreasesOmitIncludedUnderThreeRowLimit() {
        var engine = SplitUsageAlertEngine()
        _ = engine.accept(sample(1, cursor: 10, other: 20, paid: 0, enabled: true), policy: policy)
        let batch = engine.accept(sample(2, included: 40, cursor: 25, other: 35, paid: 30, enabled: true), policy: policy)
        XCTAssertEqual(content(batch), .init(title: "Paid spending increased",
                                             body: "+$0.30 since last refresh\nOther Models: 20.0% → 35.0%\nCursor Models: 10.0% → 25.0%"))
        XCTAssertEqual(batch.boldJump?.signals.filter { $0.tier == 2 }.count, 4)
    }

    func testNewerThresholdOmitsOlderBoldSnapshot() {
        var engine = SplitUsageAlertEngine()
        _ = engine.accept(sample(1, cursor: 65), policy: policy)
        let previous = engine.accept(sample(2, cursor: 82), policy: policy)
        let current = engine.accept(sample(3, cursor: 86), policy: policy)
        XCTAssertEqual(SplitUsageNotificationComposer.compose(thresholds: current.thresholds, bold: previous.boldJump),
                       .init(title: "Cursor Models 86.0% · Warning", body: "Your warning level is 80%."))
        XCTAssertEqual(previous.boldJump?.observationRevision, 2)
    }

    func testTierOneCompanionDoesNotEnterTierTwoBanner() {
        var engine = SplitUsageAlertEngine()
        _ = engine.accept(sample(1, cursor: 1.002, other: 20), policy: policy)
        let batch = engine.accept(sample(2, included: 29.99, cursor: 16.001, other: 35), policy: policy)
        XCTAssertEqual(batch.boldJump?.signals.first { $0.scope == .cursor }?.tier, 1)
        XCTAssertEqual(content(batch), .init(title: "Other Models increased", body: "Last refresh 20.0% → now 35.0%"))
    }

    func testPercentFormattingRetainsBoundaryAndOverLimitMeaning() {
        var engine = SplitUsageAlertEngine()
        var custom = policy
        custom.thresholdsEnabled = false
        _ = engine.accept(sample(1, cursor: 0.01, other: 84.99), policy: custom)
        let batch = engine.accept(sample(2, cursor: 15.01, other: 99.99), policy: custom)
        XCTAssertEqual(content(batch), .init(title: "Other Models increased",
                                             body: "Last refresh 85.0% → now <100.0%\nCursor Models: <0.1% → 15.0%"))
        let next = engine.accept(sample(3, other: 120), policy: policy)
        XCTAssertEqual(content(next)?.title, "Other Models 120.0% · Critical")
    }

    func testNoTierTwoSignalDoesNotProduceIncreaseNotification() {
        var engine = SplitUsageAlertEngine()
        XCTAssertNil(content(engine.accept(sample(1, cursor: 10), policy: policy)))
        let batch = engine.accept(sample(2, cursor: 15), policy: policy)
        XCTAssertEqual(batch.jump?.tier, 1)
        XCTAssertNil(content(batch))
        XCTAssertNil(SplitUsageNotificationComposer.compose(thresholds: [], bold: batch.jump))
    }
}
