import XCTest
@testable import CursorMeter

/// Tests focus on the pure intensity-policy helper, which is the only piece of
/// `JumpEffectCoordinator` that can be exercised without an `NSStatusItem` and a
/// running NSApplication. The coordinator's image-swap orchestration is verified
/// by manual smoke testing per Issue #55.
final class JumpEffectCoordinatorTests: XCTestCase {

    // MARK: - Tier 0 (always inert)

    func testTierZeroNeverFires() {
        for intensity in JumpIntensity.allCases {
            let result = JumpEffectCoordinator.shouldFire(intensity: intensity, tier: .zero)
            XCTAssertFalse(result, "tier 0 should never fire (intensity=\(intensity))")
        }
    }

    // MARK: - Quiet

    func testQuietIgnoresTierOne() {
        let result = JumpEffectCoordinator.shouldFire(intensity: .quiet, tier: .one)
        XCTAssertFalse(result)
    }

    func testQuietFiresOnTierTwo() {
        let result = JumpEffectCoordinator.shouldFire(intensity: .quiet, tier: .two)
        XCTAssertTrue(result)
    }

    // MARK: - Normal

    func testNormalFiresOnTierOne() {
        let result = JumpEffectCoordinator.shouldFire(intensity: .normal, tier: .one)
        XCTAssertTrue(result)
    }

    func testNormalFiresOnTierTwo() {
        let result = JumpEffectCoordinator.shouldFire(intensity: .normal, tier: .two)
        XCTAssertTrue(result)
    }

    // MARK: - Bold

    func testBoldFiresOnTierOne() {
        let result = JumpEffectCoordinator.shouldFire(intensity: .bold, tier: .one)
        XCTAssertTrue(result)
    }

    func testBoldFiresOnTierTwo() {
        let result = JumpEffectCoordinator.shouldFire(intensity: .bold, tier: .two)
        XCTAssertTrue(result)
    }

    // MARK: - Swap params

    func testSwapParamsTierOneUsesLightningNoGlow() {
        let params = JumpEffectCoordinator.swapParams(for: .one)
        XCTAssertEqual(params.emoji, "⚡")
        XCTAssertFalse(params.glow)
        XCTAssertEqual(params.durationMs, 6000)
    }

    func testSwapParamsTierTwoUsesRocketWithGlow() {
        let params = JumpEffectCoordinator.swapParams(for: .two)
        XCTAssertEqual(params.emoji, "🚀")
        XCTAssertTrue(params.glow)
        XCTAssertEqual(params.durationMs, 15000)
    }

    // MARK: - Swap params: dollar glyph style (#73)

    func testSwapParamsDollarStyleTierOne() {
        let params = JumpEffectCoordinator.swapParams(for: .one, style: .dollar)
        XCTAssertEqual(params.emoji, "💲")
        XCTAssertFalse(params.glow, "glow is style-agnostic; tier-1 stays off")
        XCTAssertEqual(params.durationMs, 6000)
    }

    func testSwapParamsDollarStyleTierTwo() {
        let params = JumpEffectCoordinator.swapParams(for: .two, style: .dollar)
        XCTAssertEqual(params.emoji, "💸")
        XCTAssertTrue(params.glow, "glow is style-agnostic; tier-2 stays on")
        XCTAssertEqual(params.durationMs, 15000)
    }

    func testSwapParamsClassicAndDollarShareTierZeroDegenerate() {
        for style in JumpGlyphStyle.allCases {
            let params = JumpEffectCoordinator.swapParams(for: .zero, style: style)
            XCTAssertEqual(params.emoji, "")
            XCTAssertFalse(params.glow)
            XCTAssertEqual(params.durationMs, 0)
        }
    }

    func testGlyphsForStyle() {
        XCTAssertEqual(JumpEffectCoordinator.glyphs(for: .classic).tier1, "⚡")
        XCTAssertEqual(JumpEffectCoordinator.glyphs(for: .classic).tier2, "🚀")
        XCTAssertEqual(JumpEffectCoordinator.glyphs(for: .dollar).tier1, "💲")
        XCTAssertEqual(JumpEffectCoordinator.glyphs(for: .dollar).tier2, "💸")
    }

    // MARK: - JumpGlyphStyle persistence

    @MainActor
    func testJumpGlyphStylePersists() {
        UserDefaults.standard.removeObject(forKey: "jumpGlyphStyle")
        let vm = UsageViewModel()
        XCTAssertEqual(vm.jumpGlyphStyle, .classic, "default is classic for back-compat")

        vm.setJumpGlyphStyle(.dollar)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "jumpGlyphStyle"), JumpGlyphStyle.dollar.rawValue)

        let reloaded = UsageViewModel()
        XCTAssertEqual(reloaded.jumpGlyphStyle, .dollar)

        UserDefaults.standard.removeObject(forKey: "jumpGlyphStyle")
    }
}
