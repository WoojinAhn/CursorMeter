import AppKit
import XCTest
@testable import CursorMeter

@MainActor
final class SplitMenuBarIntegrationTests: XCTestCase {
    private var savedDefaults: [String: Any] = [:]

    override func setUp() async throws {
        try XCTSkipIf(Bundle.main.bundleIdentifier == "com.woojin.CursorMeter",
                      "Requires a separate XCTest defaults domain")
        for key in SplitMenuBarTestFixtures.preferenceKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
        }
        UserDefaults.standard.removeObject(forKey: "splitMenuBarPercentagesEnabled")
    }

    override func tearDown() async throws {
        guard Bundle.main.bundleIdentifier != "com.woojin.CursorMeter" else { return }
        SplitMenuBarTestFixtures.restoreDefaults(savedDefaults)
    }

    func testViewModelGatesAndPartialValuesUseCurrentPresentation() throws {
        let vm = SplitMenuBarTestFixtures.makeViewModel()
        try SplitMenuBarTestFixtures.publishSplit(to: vm, cursor: nil)
        XCTAssertNil(vm.splitMenuBarReadout)
        vm.setSplitMenuBarPercentagesEnabled(true)
        XCTAssertEqual(vm.splitMenuBarReadout, .init(upper: "42.0%", lower: "—"))
        vm.setSplitOuterPool(.cursor)
        XCTAssertEqual(vm.splitMenuBarReadout, .init(upper: "—", lower: "42.0%"))
        vm.setPopoverValueMode(.dollars)
        XCTAssertEqual(vm.splitMenuBarReadout, .init(upper: "—", lower: "42.0%"))
        vm.usageData = nil
        XCTAssertNil(vm.splitMenuBarReadout)
        try SplitMenuBarTestFixtures.publishLegacy(to: vm)
        XCTAssertNil(vm.splitMenuBarReadout)
    }

    func testProfile404SplitMeasurementNeedsNoVerifiedIdentity() throws {
        let vm = SplitMenuBarTestFixtures.makeViewModel()
        let summary = try SplitMenuBarTestFixtures.publishSplit(to: vm, withoutIdentity: true)
        XCTAssertEqual(summary.profile404Measurement(usage: UsageResponse(models: [:], startOfMonth: nil),
                                                     enterpriseScope: false), .split)
        vm.setSplitMenuBarPercentagesEnabled(true)
        XCTAssertEqual(vm.splitUsage.eligibility, .eligible)
        XCTAssertEqual(vm.splitMenuBarReadout, .init(upper: "42.0%", lower: "12.0%"))
    }

    func testSameOwnerFailureRetainsFormattedReadoutAndRenderedNumbers() throws {
        let vm = SplitMenuBarTestFixtures.makeViewModel()
        try SplitMenuBarTestFixtures.publishSplit(to: vm, cursor: 99.95, other: 0.001)
        vm.setSplitMenuBarPercentagesEnabled(true)
        let app = AppDelegate(viewModel: vm)
        let snapshot = try XCTUnwrap(vm.splitUsage.snapshot)
        let readout = SplitMenuBarReadout(upper: "<0.1%", lower: "<100.0%")
        let active = ActiveJump(emoji: "🚀", glow: true, fallbackSize: NSSize(width: 18, height: 18))
        let before = try [nil, active].map { try SplitMenuBarTestFixtures.pixels(app.currentStatusImage(activeJump: $0)) }
        XCTAssertEqual(vm.splitMenuBarReadout, readout)

        vm.splitUsage.recordFailure()

        XCTAssertTrue(vm.splitUsage.isStale)
        XCTAssertEqual(vm.splitUsage.snapshot, snapshot)
        XCTAssertEqual(vm.splitMenuBarReadout, readout)
        XCTAssertTrue(vm.splitMenuBarPercentagesEnabled)
        for (index, jump) in [nil, active].enumerated() {
            XCTAssertTrue(try SplitMenuBarTestFixtures.pixels(app.currentStatusImage(activeJump: jump)) == before[index],
                          "Same-owner stale data must keep both normal and jump numbers")
        }
    }

    func testAccountReplacementWithMissingPercentagesRetiresOldNumbersAndKeepsPreference() throws {
        let vm = SplitMenuBarTestFixtures.makeViewModel()
        try SplitMenuBarTestFixtures.publishSplit(to: vm, cursor: 17, other: 51, subject: "old-owner")
        vm.setSplitMenuBarPercentagesEnabled(true)
        let app = AppDelegate(viewModel: vm)
        let oldOwner = try XCTUnwrap(vm.splitUsage.snapshot).identity.accountDigest
        let active = ActiveJump(emoji: "🚀", glow: true, fallbackSize: NSSize(width: 18, height: 18))
        let oldPixels = try SplitMenuBarTestFixtures.pixels(app.currentStatusImage(activeJump: active))
        vm.splitUsage.recordFailure()

        try SplitMenuBarTestFixtures.publishSplit(to: vm, cursor: nil, other: 3.5, subject: "new-owner")

        XCTAssertNotEqual(try XCTUnwrap(vm.splitUsage.snapshot).identity.accountDigest, oldOwner)
        XCTAssertFalse(vm.splitUsage.isStale)
        XCTAssertNil(vm.splitUsage.snapshot?.cursorPercent)
        XCTAssertEqual(vm.splitUsage.snapshot?.otherPercent, 3.5)
        XCTAssertEqual(vm.splitMenuBarReadout, .init(upper: "3.5%", lower: "—"))
        let expected = SplitMenuBarRenderer.image(icon: CircularProgressIcon.makeEmojiImage(
            emoji: active.emoji, size: active.fallbackSize, glow: active.glow),
            readout: .init(upper: "3.5%", lower: "—"))
        let currentPixels = try SplitMenuBarTestFixtures.pixels(app.currentStatusImage(activeJump: active))
        XCTAssertFalse(currentPixels == oldPixels, "An active jump must not retain the previous owner's numbers")
        XCTAssertTrue(currentPixels == (try SplitMenuBarTestFixtures.pixels(expected)))

        vm.splitUsage.reset()
        XCTAssertNil(vm.splitMenuBarReadout)
        XCTAssertNil(vm.splitUsage.snapshot)
        XCTAssertTrue(vm.splitMenuBarPercentagesEnabled)
        XCTAssertEqual(UserDefaults.standard.object(forKey: "splitMenuBarPercentagesEnabled") as? Bool, true)
        try SplitMenuBarTestFixtures.publishSplit(to: vm, cursor: nil, other: nil, subject: "new-owner")
        XCTAssertEqual(vm.splitUsage.eligibility, .legacy)
        XCTAssertNil(vm.splitMenuBarReadout)
        XCTAssertTrue(vm.splitMenuBarPercentagesEnabled)
        let fallback = CircularProgressIcon.makeEmojiImage(
            emoji: active.emoji, size: active.fallbackSize, glow: active.glow)
        XCTAssertTrue(try SplitMenuBarTestFixtures.pixels(app.currentStatusImage(activeJump: active))
            == SplitMenuBarTestFixtures.pixels(fallback))
    }

    func testNoCookieLoginRequiredHidesReadoutAndPreservesExistingCircle() async throws {
        let vm = SplitMenuBarTestFixtures.makeViewModel()
        try SplitMenuBarTestFixtures.publishSplit(to: vm)
        vm.setSplitMenuBarPercentagesEnabled(true)
        let app = AppDelegate(viewModel: vm)
        let tooltip = vm.splitPresentation?.tooltip
        let snapshot = vm.splitUsage.snapshot
        vm.activeAuthSource = .cursorIDE
        await vm.refresh()
        XCTAssertEqual(vm.authState, .loginRequired)
        XCTAssertNotNil(vm.usageData)
        XCTAssertEqual(vm.splitUsage.snapshot, snapshot)
        XCTAssertNil(vm.splitMenuBarReadout)
        XCTAssertEqual(vm.splitPresentation?.tooltip, tooltip)
        let expected = CircularProgressIcon.makeSplitImage(cursorPercent: 12, otherPercent: 42)
        XCTAssertEqual(try SplitMenuBarTestFixtures.pixels(app.currentStatusImage(activeJump: nil)),
                       try SplitMenuBarTestFixtures.pixels(expected))
    }

    func testNormalAndJumpImagesUseLatestValuesWithStableWidth() throws {
        let vm = SplitMenuBarTestFixtures.makeViewModel()
        try SplitMenuBarTestFixtures.publishSplit(to: vm)
        vm.setSplitMenuBarPercentagesEnabled(true)
        let app = AppDelegate(viewModel: vm)
        let active = ActiveJump(emoji: "🚀", glow: true, fallbackSize: NSSize(width: 18, height: 18))
        let normal = app.currentStatusImage(activeJump: nil)
        let before = app.currentStatusImage(activeJump: active)
        XCTAssertEqual(normal.size, before.size)
        try SplitMenuBarTestFixtures.publishSplit(to: vm, cursor: 17, other: 51)
        let updated = app.currentStatusImage(activeJump: active)
        XCTAssertEqual(updated.size, before.size)
        XCTAssertNotEqual(try SplitMenuBarTestFixtures.pixels(updated), try SplitMenuBarTestFixtures.pixels(before))
        vm.setSplitOuterPool(.cursor)
        let swapped = app.currentStatusImage(activeJump: active)
        XCTAssertEqual(swapped.size, before.size)
        XCTAssertNotEqual(try SplitMenuBarTestFixtures.pixels(swapped), try SplitMenuBarTestFixtures.pixels(updated))
        let expected = SplitMenuBarRenderer.image(icon: CircularProgressIcon.makeEmojiImage(
            emoji: active.emoji, size: NSSize(width: 18, height: 18), glow: active.glow),
            readout: .init(upper: "17.0%", lower: "51.0%"))
        XCTAssertEqual(try SplitMenuBarTestFixtures.pixels(swapped), try SplitMenuBarTestFixtures.pixels(expected))
    }

    func testLegacyAndDisabledReadoutPreserveCapturedEmojiSize() throws {
        let vm = SplitMenuBarTestFixtures.makeViewModel()
        try SplitMenuBarTestFixtures.publishLegacy(to: vm)
        vm.setMenuBarDisplayMode(1)
        let app = AppDelegate(viewModel: vm)
        let base = app.currentStatusImage(activeJump: nil)
        XCTAssertEqual(app.currentJumpFallbackSize(), base.size)
        let active = ActiveJump(emoji: "🚀", glow: true, fallbackSize: base.size)
        XCTAssertEqual(app.currentStatusImage(activeJump: active).size, base.size)
        try SplitMenuBarTestFixtures.publishSplit(to: vm)
        XCTAssertEqual(app.currentStatusImage(activeJump: active).size, base.size)
        vm.setSplitMenuBarPercentagesEnabled(true)
        vm.authState = .loginRequired
        XCTAssertEqual(app.currentStatusImage(activeJump: active).size, base.size)
    }

    func testExistingWideLegacyJumpEnteringSplitRendersFresh18PointEmoji() throws {
        let vm = SplitMenuBarTestFixtures.makeViewModel()
        try SplitMenuBarTestFixtures.publishLegacy(to: vm)
        vm.setMenuBarDisplayMode(1)
        let app = AppDelegate(viewModel: vm)
        let legacySize = app.currentJumpFallbackSize()
        XCTAssertGreaterThan(legacySize.width, 18)
        let active = ActiveJump(emoji: "🚀", glow: true, fallbackSize: legacySize)
        try SplitMenuBarTestFixtures.publishSplit(to: vm)
        vm.setSplitMenuBarPercentagesEnabled(true)
        let expected = SplitMenuBarRenderer.image(icon: CircularProgressIcon.makeEmojiImage(
            emoji: active.emoji, size: NSSize(width: 18, height: 18), glow: active.glow),
            readout: try XCTUnwrap(vm.splitMenuBarReadout))
        XCTAssertEqual(try SplitMenuBarTestFixtures.pixels(app.currentStatusImage(activeJump: active)),
                       try SplitMenuBarTestFixtures.pixels(expected))
        XCTAssertEqual(active.fallbackSize, legacySize)
        XCTAssertEqual(app.currentJumpFallbackSize(), NSSize(width: 18, height: 18))
    }

    func testSplitToLegacyNewJumpUsesBaseMeterInsteadOfPriorComposite() throws {
        let vm = SplitMenuBarTestFixtures.makeViewModel()
        try SplitMenuBarTestFixtures.publishSplit(to: vm)
        vm.setSplitMenuBarPercentagesEnabled(true)
        let app = AppDelegate(viewModel: vm)
        let prior = app.currentStatusImage(activeJump: ActiveJump(
            emoji: "🚀", glow: true, fallbackSize: NSSize(width: 18, height: 18)))
        try SplitMenuBarTestFixtures.publishLegacy(to: vm)
        vm.setMenuBarDisplayMode(0)
        XCTAssertEqual(app.currentJumpFallbackSize(), NSSize(width: 18, height: 18))
        XCTAssertNotEqual(app.currentJumpFallbackSize(), prior.size)
        vm.setMenuBarDisplayMode(1)
        XCTAssertEqual(app.currentJumpFallbackSize(), app.currentStatusImage(activeJump: nil).size)
    }

    func testRealAppRendererUsesLatestReadoutWithoutResettingCoordinatorTimer() async throws {
        let vm = SplitMenuBarTestFixtures.makeViewModel()
        try SplitMenuBarTestFixtures.publishSplit(to: vm)
        vm.setSplitMenuBarPercentagesEnabled(true)
        let app = AppDelegate(viewModel: vm)
        var frames: [NSImage] = []
        var deadlines: [TimeInterval] = []
        var cancellations = 0
        var restore: (@MainActor @Sendable () -> Void)?
        let coordinator = JumpEffectCoordinator(viewModel: vm,
            render: { frames.append(app.currentStatusImage(activeJump: $0)) },
            fallbackImageSize: { app.currentJumpFallbackSize() },
            scheduleRestore: { delay, action in
                deadlines.append(delay)
                restore = action
                return { cancellations += 1 }
            })
        defer { coordinator.stop() }
        coordinator.start()
        vm.lastJump = SplitMenuBarTestFixtures.jump()
        for _ in 0..<20 { await Task.yield() }
        let active = try XCTUnwrap(coordinator.activeJump)
        let before = try XCTUnwrap(frames.last)
        try SplitMenuBarTestFixtures.publishSplit(to: vm, cursor: 13, other: 48)
        vm.setSplitOuterPool(.cursor)
        coordinator.redraw()
        XCTAssertEqual(coordinator.activeJump, active)
        XCTAssertEqual(deadlines, [15])
        XCTAssertEqual(cancellations, 0)
        XCTAssertEqual(try XCTUnwrap(frames.last).size, before.size)
        XCTAssertNotEqual(try SplitMenuBarTestFixtures.pixels(XCTUnwrap(frames.last)),
                          try SplitMenuBarTestFixtures.pixels(before))
        try XCTUnwrap(restore)()
        XCTAssertNil(coordinator.activeJump)
        XCTAssertEqual(try SplitMenuBarTestFixtures.pixels(XCTUnwrap(frames.last)),
                       try SplitMenuBarTestFixtures.pixels(app.currentStatusImage(activeJump: nil)))
    }
}
