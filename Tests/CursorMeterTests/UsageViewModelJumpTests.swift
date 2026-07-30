import XCTest
@testable import CursorMeter

/// Unit tests for jump-tier classification and delta formatting.
/// These exercise nonisolated static helpers on `UsageViewModel`, which mirror the
/// canonical-unit math used by `UsageViewModel.refresh()`.
final class UsageViewModelJumpTests: XCTestCase {

    // MARK: - Tier classification (with limit > 0, kept under absolute thresholds)

    func testTierZeroJustBelow5PercentAndAbsT1() {
        // 0.4% of 1000 cents = 4 cents (< 5% pct, < 5 cents T1)
        let tier = UsageViewModel.classifyTier(mode: .credit, delta: 4, limit: 1000)
        XCTAssertEqual(tier, .zero)
    }

    func testTierOneAt5PercentBoundaryUnderAbsT2() {
        // 5% of 500 cents = 25 cents (≥ 5% pct, ≥ 5 cents T1, < 30 cents T2)
        let tier = UsageViewModel.classifyTier(mode: .credit, delta: 25, limit: 500)
        XCTAssertEqual(tier, .one)
    }

    func testTierOneJustBelow15PercentAndAbsT2() {
        // 12.5% of 200 cents = 25 cents (< 15% pct, < 30 cents T2)
        let tier = UsageViewModel.classifyTier(mode: .credit, delta: 25, limit: 200)
        XCTAssertEqual(tier, .one)
    }

    func testTierTwoAt15PercentBoundary() {
        let tier = UsageViewModel.classifyTier(mode: .credit, delta: 150, limit: 1000)
        XCTAssertEqual(tier, .two)
    }

    func testTierZeroForZeroDelta() {
        let tier = UsageViewModel.classifyTier(mode: .credit, delta: 0, limit: 1000)
        XCTAssertEqual(tier, .zero)
    }

    func testTierZeroForNegativeDelta() {
        // Cycle reset: classify-helper itself returns zero rather than firing.
        let tier = UsageViewModel.classifyTier(mode: .credit, delta: -100, limit: 1000)
        XCTAssertEqual(tier, .zero)
    }

    // MARK: - Absolute thresholds escalate even when percent is tiny

    func testRequestAbsoluteEscalatesOnLargePlan() {
        // 27 / 500 = 5.4% → would be tier 1 by percent, but 27 ≥ T2 (15) escalates to tier 2.
        // This is the user-observed "Max-mode +27 on a 500-limit plan" case.
        let tier = UsageViewModel.classifyTier(mode: .request, delta: 27, limit: 500)
        XCTAssertEqual(tier, .two)
    }

    func testRequestAbsoluteEscalatesOnEnterprisePlan() {
        // 27 / 5000 = 0.54% → tier 0 by percent, but 27 ≥ T2 (15) → tier 2.
        let tier = UsageViewModel.classifyTier(mode: .request, delta: 27, limit: 5000)
        XCTAssertEqual(tier, .two)
    }

    func testCreditAbsoluteEscalatesOnLargePlan() {
        // $0.30 (= 30 cents) on a $50 plan: 0.6% by percent, but 30 ≥ T2 cents → tier 2.
        // This is roughly a single Max-mode query.
        let tier = UsageViewModel.classifyTier(mode: .credit, delta: 30, limit: 5000)
        XCTAssertEqual(tier, .two)
    }

    func testCreditAbsoluteEscalatesToTierOne() {
        // 5 cents on a $50 plan: 0.1% by percent, but 5 ≥ T1 cents → tier 1.
        let tier = UsageViewModel.classifyTier(mode: .credit, delta: 5, limit: 5000)
        XCTAssertEqual(tier, .one)
    }

    // MARK: - Fixed-threshold fallback (limit ≤ 0)

    func testCreditFallbackTierBoundaries() {
        // limit ≤ 0 → absolute-only thresholds: T1=5, T2=30 cents
        XCTAssertEqual(UsageViewModel.classifyTier(mode: .credit, delta: 4, limit: 0), .zero)
        XCTAssertEqual(UsageViewModel.classifyTier(mode: .credit, delta: 5, limit: 0), .one)
        XCTAssertEqual(UsageViewModel.classifyTier(mode: .credit, delta: 29, limit: 0), .one)
        XCTAssertEqual(UsageViewModel.classifyTier(mode: .credit, delta: 30, limit: 0), .two)
    }

    func testRequestFallbackTierBoundaries() {
        // limit ≤ 0 → absolute-only thresholds: T1=5, T2=15 requests
        XCTAssertEqual(UsageViewModel.classifyTier(mode: .request, delta: 4, limit: 0), .zero)
        XCTAssertEqual(UsageViewModel.classifyTier(mode: .request, delta: 5, limit: 0), .one)
        XCTAssertEqual(UsageViewModel.classifyTier(mode: .request, delta: 14, limit: 0), .one)
        XCTAssertEqual(UsageViewModel.classifyTier(mode: .request, delta: 15, limit: 0), .two)
    }

    // MARK: - Percent-only mode (5%p / 15%p)

    func testPercentModeTierBoundaries() {
        // Percent-only: limit is 100, deltas are %-points
        XCTAssertEqual(UsageViewModel.classifyTier(mode: .percent, delta: 4.9, limit: 100), .zero)
        XCTAssertEqual(UsageViewModel.classifyTier(mode: .percent, delta: 5.0, limit: 100), .one)
        XCTAssertEqual(UsageViewModel.classifyTier(mode: .percent, delta: 14.9, limit: 100), .one)
        XCTAssertEqual(UsageViewModel.classifyTier(mode: .percent, delta: 15.0, limit: 100), .two)
    }

    // MARK: - displayDelta formatting

    func testDisplayDeltaCreditUSDFormat() {
        // 30 cents -> "+$0.30"
        let event = UsageViewModel.makeJumpEvent(mode: .credit, delta: 30, limit: 1000)
        XCTAssertEqual(event.displayDelta, "+$0.30")
    }

    func testDisplayDeltaCreditWholeDollar() {
        let event = UsageViewModel.makeJumpEvent(mode: .credit, delta: 150, limit: 1000)
        XCTAssertEqual(event.displayDelta, "+$1.50")
    }

    func testDisplayDeltaRequestFormat() {
        let event = UsageViewModel.makeJumpEvent(mode: .request, delta: 30, limit: 500)
        XCTAssertEqual(event.displayDelta, "+30")
    }

    func testDisplayDeltaPercentFormat() {
        let event = UsageViewModel.makeJumpEvent(mode: .percent, delta: 15.0, limit: 100)
        XCTAssertEqual(event.displayDelta, "+15.0%")
    }

    // MARK: - JumpEvent end-to-end shape

    func testMakeJumpEventPopulatesFields() {
        let event = UsageViewModel.makeJumpEvent(mode: .credit, delta: 200, limit: 1000)
        XCTAssertEqual(event.tier, .two)
        XCTAssertEqual(event.deltaCanonical, 200)
        XCTAssertEqual(event.deltaPct, 20.0, accuracy: 0.001)
        XCTAssertEqual(event.mode, .credit)
        XCTAssertEqual(event.displayDelta, "+$2.00")
    }

    func testMakeJumpEventDeltaPctWithZeroLimitIsZero() {
        // No meaningful percent when limit is 0 — avoids divide-by-zero noise in UI.
        // Tier comes from the absolute-only fallback: 10 ∈ [T1=5, T2=15) → tier 1.
        let event = UsageViewModel.makeJumpEvent(mode: .request, delta: 10, limit: 0)
        XCTAssertEqual(event.deltaPct, 0)
        XCTAssertEqual(event.tier, .one)
    }

    // MARK: - Settings persistence + setters

    @MainActor
    func testJumpSettingsDefaults() {
        UserDefaults.standard.removeObject(forKey: "jumpEffectEnabled")
        UserDefaults.standard.removeObject(forKey: "jumpIntensity")
        let vm = UsageViewModel()
        XCTAssertTrue(vm.jumpEffectEnabled)
        XCTAssertEqual(vm.jumpIntensity, .normal)
    }

    @MainActor
    func testJumpSettingsSettersPersist() {
        let vm = UsageViewModel()
        vm.setJumpEffectEnabled(false)
        vm.setJumpIntensity(.bold)
        XCTAssertFalse(vm.jumpEffectEnabled)
        XCTAssertEqual(vm.jumpIntensity, .bold)
        XCTAssertEqual(UserDefaults.standard.bool(forKey: "jumpEffectEnabled"), false)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "jumpIntensity"), JumpIntensity.bold.rawValue)

        // Cleanup so other tests aren't affected.
        UserDefaults.standard.removeObject(forKey: "jumpEffectEnabled")
        UserDefaults.standard.removeObject(forKey: "jumpIntensity")
    }

    // MARK: - On-demand mode

    func test_formatJumpDelta_onDemand_isUSD() {
        let s = UsageViewModel.formatJumpDelta(584, mode: .onDemand)
        XCTAssertEqual(s, "+$5.84")
    }

    func test_updateJumpState_transitionRequestToOnDemand_skipsDelta() async {
        let vm = await MainActor.run { UsageViewModel() }
        let d1 = makeFixture(
            requestsUsed: 400, requestsLimit: 500,
            onDemandUsedCents: 0, onDemandLimitCents: 4000, onDemandEnabled: true,
            isOnDemandActive: false
        )
        let d2 = makeFixture(
            requestsUsed: 757, requestsLimit: 500,
            onDemandUsedCents: 584, onDemandLimitCents: 4000, onDemandEnabled: true,
            isOnDemandActive: true
        )
        await MainActor.run {
            vm.testHook_updateJumpState(from: d1)
            vm.testHook_updateJumpState(from: d2)
        }
        // Mode transition → existing `modeChanged` guard skips this delta.
        let jump = await MainActor.run { vm.lastJump }
        XCTAssertNil(jump)
    }

    func test_updateJumpState_subsequentOnDemand_firesJump() async {
        let vm = await MainActor.run { UsageViewModel() }
        let baseline = makeFixture(
            onDemandUsedCents: 500, onDemandLimitCents: 4000, onDemandEnabled: true,
            isOnDemandActive: true
        )
        let next = makeFixture(
            onDemandUsedCents: 1100, onDemandLimitCents: 4000, onDemandEnabled: true,
            isOnDemandActive: true
        )
        await MainActor.run {
            vm.testHook_updateJumpState(from: baseline)
            vm.testHook_updateJumpState(from: next)
        }
        let jump = await MainActor.run { vm.lastJump }
        XCTAssertNotNil(jump)
        XCTAssertEqual(jump?.mode, .onDemand)
        XCTAssertEqual(jump?.deltaCanonical, 600)
        XCTAssertEqual(jump?.displayDelta, "+$6.00")
    }

    /// #64 — logout() must clear jump baselines. Before this fix, a refresh
    /// against a re-login (or post-logout edge path) would compute a phantom
    /// delta against the prior user's value. After clearing on logout, the
    /// next first refresh is treated as a baseline-set (no jump emitted).
    func test_logout_clearsJumpBaselines() async {
        let vm = await MainActor.run { UsageViewModel() }
        await MainActor.run { vm.keychainDeleteHandler = {} }  // #82: no real Keychain in tests
        let baseline = makeFixture(requestsUsed: 100, requestsLimit: 500)
        let next = makeFixture(requestsUsed: 150, requestsLimit: 500)

        await MainActor.run {
            // Establish a baseline that would otherwise emit a +50 jump on next refresh.
            vm.testHook_updateJumpState(from: baseline)
            // Logout clears auth + per-account state, including jump baselines.
            vm.logout()
            // Post-logout, a fresh delta computation must not see the prior baseline.
            vm.testHook_updateJumpState(from: next)
        }
        let jump = await MainActor.run { vm.lastJump }
        XCTAssertNil(jump, "post-logout first jump-state call must be a baseline-set, not a delta")
    }
}

// MARK: - Test fixture

private func makeFixture(
    email: String = "test@test.com",
    name: String = "Test",
    membershipType: String? = nil,
    planUsedCents: Int? = nil,
    planLimitCents: Int? = nil,
    serverPercentUsed: Double? = nil,
    requestsUsed: Int = 0,
    requestsLimit: Int = 0,
    onDemandUsedCents: Int? = nil,
    onDemandLimitCents: Int? = nil,
    onDemandEnabled: Bool? = nil,
    isOnDemandActive: Bool = false,
    cycleStartDate: Date? = nil,
    resetDate: Date? = nil,
) -> UsageDisplayData {
    UsageDisplayData(
        email: email,
        name: name,
        membershipType: membershipType,
        planUsedCents: planUsedCents,
        planLimitCents: planLimitCents,
        serverPercentUsed: serverPercentUsed,
        requestsUsed: requestsUsed,
        requestsLimit: requestsLimit,
        onDemandUsedCents: onDemandUsedCents,
        onDemandLimitCents: onDemandLimitCents,
        onDemandEnabled: onDemandEnabled,
        isOnDemandActive: isOnDemandActive,
        cycleStartDate: cycleStartDate,
        resetDate: resetDate
    )
}
