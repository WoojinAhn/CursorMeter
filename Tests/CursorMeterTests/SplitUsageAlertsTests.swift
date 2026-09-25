import XCTest
@testable import CursorMeter

final class SplitUsageAlertsTests: XCTestCase {
    private let owner = SplitAlertOwnership(accountDigest: "account", requestPlanScope: "personal-pro", generation: 1)
    private func sample(_ revision: UInt64, included: Double? = 0, cursor: Double? = 0,
                        other: Double? = 0, paid: Double? = nil, cap: Double? = nil,
                        enabled: Bool? = nil, time: TimeInterval? = nil, reset: Bool = false) -> SplitUsageObservation {
        SplitUsageObservation(ownership: owner, revision: revision,
            timestamp: Date(timeIntervalSince1970: time ?? Double(revision) * 60),
            includedCents: included, cursorPercent: cursor, otherPercent: other,
            paidCents: paid, paidCapCents: cap, paidEnabled: enabled, continuityReset: reset)
    }

    func testCredentialRenewalPreservesCycleHighWater() {
        var engine = SplitUsageAlertEngine()
        _ = engine.accept(sample(1, cursor: 50), policy: .init())
        var renewed = sample(2, cursor: 40)
        renewed.ownership.generation = 2
        XCTAssertNil(engine.accept(renewed, policy: .init()).jump)
        var next = sample(3, cursor: 56)
        next.ownership.generation = 2
        XCTAssertEqual(engine.accept(next, policy: .init()).jump?.deltas[.cursor], 6)
    }

    func testThresholdNormalizerPreservesUpperPairAndRoundsToSteps() {
        let upper = SplitAlertPolicy.normalizeThresholds(warning: 95, critical: 100)
        XCTAssertEqual(upper.warning, 95)
        XCTAssertEqual(upper.critical, 100)
        let rounded = SplitAlertPolicy.normalizeThresholds(warning: 83, critical: 92)
        XCTAssertEqual(rounded.warning, 85)
        XCTAssertEqual(rounded.critical, 90)
    }

    func testExactIndependentJumpEdges() {
        for (cents, pp, expected) in [(4.99, 4.99, 0), (5.0, 0.0, 1), (0.0, 5.0, 1),
                                      (29.99, 14.99, 1), (30.0, 0.0, 2), (0.0, 15.0, 2)] {
            var engine = SplitUsageAlertEngine()
            XCTAssertNil(engine.accept(sample(1), policy: .init()).jump)
            XCTAssertEqual(engine.accept(sample(2, included: cents, cursor: pp), policy: .init()).jump?.tier ?? 0, expected)
        }
    }

    func testFractionalPercentagePointBoundariesUseSourcePrecision() {
        for (start, end, expectedTier) in [(7.7, 12.7, 1), (1.002, 16.002, 2),
                                          (7.7, 12.699, 0), (1.002, 16.001, 1)] {
            for scope in [SplitAlertScope.cursor, .other] {
                var engine = SplitUsageAlertEngine()
                var previous = sample(1)
                var current = sample(2)
                if scope == .cursor {
                    previous.cursorPercent = start
                    current.cursorPercent = end
                } else {
                    previous.otherPercent = start
                    current.otherPercent = end
                }
                _ = engine.accept(previous, policy: .init())
                let jump = engine.accept(current, policy: .init()).jump
                XCTAssertEqual(jump?.tier ?? 0, expectedTier, "\(scope): \(start) to \(end)")
                if expectedTier > 0 {
                    XCTAssertEqual(jump?.deltas[scope], ((end - start) * 1000).rounded() / 1000)
                }
            }
        }
    }

    func testAggregateIncludedJumpHasNoInventedPoolAttribution() {
        var engine = SplitUsageAlertEngine()
        _ = engine.accept(sample(1, included: 100), policy: .init())
        let jump = engine.accept(sample(2, included: 140, cursor: 1, other: 1), policy: .init()).jump
        XCTAssertEqual(jump?.tier, 2)
        XCTAssertEqual(jump?.deltas[.included], 40)
        XCTAssertEqual(jump?.title, "Included Usage Jump")
        XCTAssertTrue(jump?.body.contains("풀별 금액 배분을 확인할 수 없습니다") == true)
    }

    func testHighWaterCorrectionDoesNotTurnSixPointsIntoSixteen() {
        var engine = SplitUsageAlertEngine()
        _ = engine.accept(sample(1, cursor: 50), policy: .init())
        XCTAssertNil(engine.accept(sample(2, cursor: 40), policy: .init()).jump)
        let jump = engine.accept(sample(3, cursor: 56), policy: .init()).jump
        XCTAssertEqual(jump?.tier, 1)
        XCTAssertEqual(jump?.deltas[.cursor], 6)
        XCTAssertTrue(jump?.correctedScopes.contains(.cursor) == true)
    }

    func testResetAndLongGapRetainHighWaterButBreakContinuity() {
        var engine = SplitUsageAlertEngine()
        _ = engine.accept(sample(1, cursor: 50), policy: .init())
        XCTAssertNil(engine.accept(sample(2, cursor: 40, reset: true), policy: .init()).jump)
        XCTAssertEqual(engine.accept(sample(3, cursor: 56), policy: .init()).jump?.deltas[.cursor], 6)
        XCTAssertNil(engine.accept(sample(4, cursor: 80, time: 1000), policy: .init()).jump)
        XCTAssertEqual(engine.accept(sample(5, cursor: 85, time: 1060), policy: .init()).jump?.tier, 1)
    }

    func testMissingResetsOnlyItsSignalAndDuplicateRevisionDoesNotReplay() {
        var engine = SplitUsageAlertEngine()
        _ = engine.accept(sample(1, cursor: 20, other: 20), policy: .init())
        XCTAssertEqual(engine.accept(sample(2, cursor: nil, other: 25), policy: .init()).jump?.tier, 1)
        XCTAssertNil(engine.accept(sample(3, cursor: 50, other: 25), policy: .init()).jump)
        XCTAssertNil(engine.accept(sample(3, cursor: 80, other: 80), policy: .init()).jump)
    }

    func testExplicitFailureOrWakeResetAndInvalidReturnOnlyBaseline() {
        var engine = SplitUsageAlertEngine()
        _ = engine.accept(sample(1, included: 100, cursor: 40), policy: .init())
        engine.resetContinuity()
        XCTAssertNil(engine.accept(sample(2, included: 200, cursor: 55), policy: .init()).jump)
        _ = engine.accept(sample(3, included: .nan, cursor: -1), policy: .init())
        XCTAssertNil(engine.accept(sample(4, included: 300, cursor: 70), policy: .init()).jump)
    }

    func testPlanChangeResetsHighWaterAndOnlyEnabledPaidBudgetThresholdsQualify() {
        var engine = SplitUsageAlertEngine()
        _ = engine.accept(sample(1, cursor: 90), policy: .init())
        var changed = sample(2, cursor: 40, paid: 100, cap: 100, enabled: false)
        changed.ownership.requestPlanScope = "different-plan"
        let first = engine.accept(changed, policy: .init())
        XCTAssertNil(first.jump)
        XCTAssertTrue(first.thresholds.isEmpty)
        changed.revision = 3
        changed.cursorPercent = 55
        changed.timestamp = changed.timestamp.addingTimeInterval(60)
        XCTAssertEqual(engine.accept(changed, policy: .init()).jump?.tier, 2)
    }

    func testPaidZeroWithoutCapAndDisabledResidualAndCapTransition() {
        var engine = SplitUsageAlertEngine()
        _ = engine.accept(sample(1, paid: 0, enabled: true), policy: .init())
        XCTAssertEqual(engine.accept(sample(2, paid: 30, enabled: true), policy: .init()).jump?.tier, 2)
        XCTAssertNil(engine.accept(sample(3, paid: 100, enabled: false), policy: .init()).jump)
        XCTAssertNil(engine.accept(sample(4, paid: 200, cap: 1000, enabled: true), policy: .init()).jump)
        XCTAssertNil(engine.accept(sample(5, paid: 230, cap: 2000, enabled: true), policy: .init()).jump)
    }

    func testSmallPaidCapAllowsRelativeAlternative() {
        var engine = SplitUsageAlertEngine()
        _ = engine.accept(sample(1, paid: 0, cap: 10, enabled: true), policy: .init())
        XCTAssertEqual(engine.accept(sample(2, paid: 1.5, cap: 10, enabled: true), policy: .init()).jump?.tier, 2)
    }

    func testThresholdsAreIndependentAndCriticalCoversWarning() {
        var engine = SplitUsageAlertEngine()
        let batch = engine.accept(sample(1, cursor: 95, other: 85, paid: 90, cap: 100, enabled: true), policy: .init())
        XCTAssertEqual(batch.thresholds.count, 3)
        let cursor = batch.thresholds.first { $0.scope == .cursor }
        XCTAssertEqual(cursor?.level, .critical)
        XCTAssertEqual(cursor?.coveredIdentities.count, 2)
        XCTAssertTrue(cursor?.body.contains("현재 95") == true)
        XCTAssertTrue(cursor?.body.contains("90%") == true)
    }

    func testMasterOffDoesNotDisableBoldAndTargetsDoNotGateJumps() {
        var engine = SplitUsageAlertEngine()
        let policy = SplitAlertPolicy(thresholdsEnabled: false, targets: [], bold: true)
        _ = engine.accept(sample(1), policy: policy)
        let batch = engine.accept(sample(2, included: 40, cursor: 95), policy: policy)
        XCTAssertTrue(batch.thresholds.isEmpty)
        XCTAssertEqual(batch.boldJump?.tier, 2)
    }
}
