import AppKit
import XCTest
@testable import CursorMeter

@MainActor
final class JumpEffectCoordinatorTests: XCTestCase {
    private let preferenceKeys = ["jumpGlyphStyle", "splitAlertThresholds"]
    private var savedDefaults: [String: Any] = [:]

    override func setUp() async throws {
        try XCTSkipIf(Bundle.main.bundleIdentifier == "com.woojin.CursorMeter",
                      "Requires a separate XCTest defaults domain")
        for key in preferenceKeys { savedDefaults[key] = UserDefaults.standard.object(forKey: key) }
    }

    override func tearDown() async throws {
        guard Bundle.main.bundleIdentifier != "com.woojin.CursorMeter" else { return }
        for key in preferenceKeys {
            if let value = savedDefaults[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    func testRedrawUsesLatestReadoutWithoutRestartingOriginalRestore() async throws {
        let vm = makeViewModel()
        let scheduler = ManualRestoreScheduler()
        let output = RenderOutput()
        let coordinator = makeCoordinator(vm: vm, scheduler: scheduler, output: output)
        defer { coordinator.stop() }
        coordinator.start()
        coordinator.redraw()
        let normalSize = try XCTUnwrap(output.frames.last).size

        vm.lastJump = event(.two)
        await drainObservation()
        let active = try XCTUnwrap(coordinator.activeJump)
        XCTAssertEqual(active, ActiveJump(emoji: "🚀", glow: true, fallbackSize: NSSize(width: 18, height: 18)))
        XCTAssertTrue(coordinator.isSwapping)
        XCTAssertEqual(try XCTUnwrap(output.frames.last).size, normalSize)

        for readout in [SplitMenuBarReadout(upper: "47.0%", lower: "13.0%"),
                        .init(upper: "13.0%", lower: "47.0%"), nil,
                        .init(upper: "14.0%", lower: "48.0%")] {
            output.readout = readout
            coordinator.redraw()
            let frame = try XCTUnwrap(output.frames.last)
            XCTAssertEqual(frame.readout, readout)
            XCTAssertEqual(frame.activeJump, active)
            XCTAssertEqual(frame.size, readout == nil ? active.fallbackSize : normalSize)
        }
        XCTAssertEqual(scheduler.pending.map(\.delay), [15])
        XCTAssertEqual(scheduler.pending[0].cancellations, 0)

        scheduler.fire(0)
        XCTAssertFalse(coordinator.isSwapping)
        XCTAssertNil(coordinator.activeJump)
        let restored = try XCTUnwrap(output.frames.last)
        XCTAssertNil(restored.activeJump)
        XCTAssertEqual(restored.readout, .init(upper: "14.0%", lower: "48.0%"))
        XCTAssertEqual(restored.size, normalSize)
        XCTAssertEqual(scheduler.pending.count, 1)
    }

    func testOwnershipRetirementClearsReadoutWhileGlyphKeepsOriginalDeadline() async throws {
        let vm = makeViewModel()
        let scheduler = ManualRestoreScheduler()
        let output = RenderOutput()
        let coordinator = makeCoordinator(vm: vm, scheduler: scheduler, output: output)
        defer { coordinator.stop() }
        coordinator.start()
        vm.lastJump = event(.two)
        await drainObservation()
        let active = try XCTUnwrap(coordinator.activeJump)

        output.readout = nil
        vm.lastJump = nil
        await drainObservation()
        coordinator.redraw()
        XCTAssertEqual(vm.authState, .loggedIn)
        XCTAssertEqual(coordinator.activeJump, active)
        XCTAssertNil(try XCTUnwrap(output.frames.last).readout)
        XCTAssertEqual(try XCTUnwrap(output.frames.last).size, NSSize(width: 18, height: 18))
        XCTAssertEqual(scheduler.pending.map(\.delay), [15])
        XCTAssertEqual(scheduler.pending[0].cancellations, 0)
        scheduler.fire(0)
        XCTAssertNil(coordinator.activeJump)
    }

    func testDisableAndAuthLossCancelEffectAndRejectQueuedRestore() async throws {
        for losesAuth in [false, true] {
            let vm = makeViewModel()
            let scheduler = ManualRestoreScheduler()
            let output = RenderOutput()
            let coordinator = makeCoordinator(vm: vm, scheduler: scheduler, output: output)
            defer { coordinator.stop() }
            coordinator.start()
            vm.lastJump = event(.two)
            await drainObservation()
            XCTAssertTrue(coordinator.isSwapping)

            output.readout = nil
            if losesAuth { vm.authState = .loginRequired }
            else { vm.jumpEffectEnabled = false }
            await drainObservation()
            XCTAssertNil(coordinator.activeJump)
            XCTAssertFalse(coordinator.isSwapping)
            XCTAssertEqual(scheduler.pending[0].cancellations, 1)
            XCTAssertNil(try XCTUnwrap(output.frames.last).activeJump)
            let renderCount = output.frames.count
            scheduler.fire(0)
            XCTAssertEqual(output.frames.count, renderCount)
        }
    }

    func testStopClearsEffectAndRejectsPendingObserverAndRestore() async throws {
        let vm = makeViewModel()
        let scheduler = ManualRestoreScheduler()
        let output = RenderOutput()
        let coordinator = makeCoordinator(vm: vm, scheduler: scheduler, output: output)
        coordinator.start()
        vm.lastJump = event(.one)
        await drainObservation()
        XCTAssertTrue(coordinator.isSwapping)

        vm.lastJump = event(.two, sequence: 2)
        coordinator.stop()
        XCTAssertNil(coordinator.activeJump)
        XCTAssertFalse(coordinator.isSwapping)
        XCTAssertEqual(scheduler.pending[0].cancellations, 1)
        XCTAssertNil(try XCTUnwrap(output.frames.last).activeJump)
        let renderCount = output.frames.count
        await drainObservation()
        scheduler.fire(0)
        XCTAssertEqual(scheduler.pending.count, 1)
        XCTAssertEqual(output.frames.count, renderCount)
    }

    func testCancelledRestoreCannotClearNewerEvent() async throws {
        let vm = makeViewModel()
        let scheduler = ManualRestoreScheduler()
        let output = RenderOutput()
        let coordinator = makeCoordinator(vm: vm, scheduler: scheduler, output: output)
        defer { coordinator.stop() }
        coordinator.start()
        vm.lastJump = event(.one)
        await drainObservation()
        vm.lastJump = event(.two, sequence: 2)
        await drainObservation()
        let active = try XCTUnwrap(coordinator.activeJump)
        XCTAssertEqual(scheduler.pending.map(\.delay), [6, 15])
        XCTAssertEqual(scheduler.pending[0].cancellations, 1)
        let renderCount = output.frames.count

        scheduler.fire(0)
        XCTAssertEqual(coordinator.activeJump, active)
        XCTAssertEqual(output.frames.count, renderCount)
        scheduler.fire(1)
        XCTAssertNil(coordinator.activeJump)
        XCTAssertNil(try XCTUnwrap(output.frames.last).activeJump)
    }

    func testRepeatedEventDoesNotRestartAfterRestore() async {
        let vm = makeViewModel()
        let scheduler = ManualRestoreScheduler()
        let output = RenderOutput()
        let coordinator = makeCoordinator(vm: vm, scheduler: scheduler, output: output)
        defer { coordinator.stop() }
        coordinator.start()
        coordinator.start()
        let jump = event(.two)
        vm.lastJump = jump
        await drainObservation()
        scheduler.fire(0)
        vm.lastJump = nil
        await drainObservation()
        vm.lastJump = jump
        await drainObservation()
        XCTAssertEqual(scheduler.pending.count, 1)
        XCTAssertNil(coordinator.activeJump)
    }

    func testFallbackSizeIsCapturedPerEventForSplitAndLegacy() async throws {
        for size in [NSSize(width: 18, height: 18), NSSize(width: 72, height: 22), NSSize(width: 22, height: 22)] {
            let vm = makeViewModel()
            let scheduler = ManualRestoreScheduler()
            let output = RenderOutput()
            output.readout = nil
            output.fallbackSize = size
            let coordinator = makeCoordinator(vm: vm, scheduler: scheduler, output: output)
            defer { coordinator.stop() }
            coordinator.start()
            vm.lastJump = event(.one)
            await drainObservation()
            XCTAssertEqual(coordinator.activeJump?.fallbackSize, size)
            XCTAssertEqual(try XCTUnwrap(output.frames.last).size, size)
            output.fallbackSize = NSSize(width: 99, height: 22)
            coordinator.redraw()
            XCTAssertEqual(try XCTUnwrap(output.frames.last).size, size)
            XCTAssertEqual(scheduler.pending.map(\.delay), [6])
        }
    }

    private func makeViewModel() -> UsageViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let vm = UsageViewModel(apiClient: CursorAPIClient(configuration: config),
            notificationManager: NotificationManager(requestAuthorization: { false }, deliver: { _ in }))
        vm.updateCheckRunner = { .upToDate }
        vm.keychainDeleteHandler = {}
        vm.sessionExpiredNotifier = {}
        vm.authState = .loggedIn
        vm.jumpEffectEnabled = true
        vm.jumpIntensity = .normal
        vm.jumpGlyphStyle = .classic
        return vm
    }

    private func makeCoordinator(vm: UsageViewModel, scheduler: ManualRestoreScheduler,
                                 output: RenderOutput) -> JumpEffectCoordinator {
        JumpEffectCoordinator(viewModel: vm, render: { output.render($0) },
            fallbackImageSize: { output.fallbackSize }, scheduleRestore: { delay, action in
                scheduler.schedule(delay: delay, action: action)
            })
    }

    private func event(_ tier: JumpEvent.Tier, sequence: Int = 1) -> JumpEvent {
        JumpEvent(tier: tier, deltaCanonical: Double(sequence), deltaPct: 15,
                  mode: .percent, displayDelta: "+15.0%", timestamp: Date(timeIntervalSince1970: Double(sequence)))
    }

    private func drainObservation() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @MainActor
    private final class ManualRestoreScheduler {
        struct Pending {
            let delay: TimeInterval
            let action: @MainActor @Sendable () -> Void
            var cancellations = 0
        }
        var pending: [Pending] = []

        func schedule(delay: TimeInterval, action: @escaping @MainActor @Sendable () -> Void) -> @MainActor () -> Void {
            let index = pending.count
            pending.append(Pending(delay: delay, action: action))
            return { self.pending[index].cancellations += 1 }
        }

        func fire(_ index: Int) { pending[index].action() }
    }

    @MainActor
    private final class RenderOutput {
        struct Frame {
            let activeJump: ActiveJump?
            let readout: SplitMenuBarReadout?
            let size: NSSize
        }
        var fallbackSize = NSSize(width: 18, height: 18)
        var readout: SplitMenuBarReadout? = .init(upper: "42.0%", lower: "12.0%")
        var frames: [Frame] = []

        func render(_ activeJump: ActiveJump?) {
            let icon = activeJump.map {
                CircularProgressIcon.makeEmojiImage(emoji: $0.emoji, size: $0.fallbackSize, glow: $0.glow)
            } ?? CircularProgressIcon.makeSplitImage(cursorPercent: 12, otherPercent: 42)
            let image = readout.map { SplitMenuBarRenderer.image(icon: icon, readout: $0) } ?? icon
            frames.append(Frame(activeJump: activeJump, readout: readout, size: image.size))
        }
    }

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

    func testJumpGlyphStylePersists() {
        UserDefaults.standard.removeObject(forKey: "jumpGlyphStyle")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let vm = UsageViewModel(apiClient: CursorAPIClient(configuration: config))
        vm.updateCheckRunner = { .upToDate }
        XCTAssertEqual(vm.jumpGlyphStyle, .classic, "default is classic for back-compat")

        vm.setJumpGlyphStyle(.dollar)
        XCTAssertEqual(UserDefaults.standard.integer(forKey: "jumpGlyphStyle"), JumpGlyphStyle.dollar.rawValue)

        let reloaded = UsageViewModel(apiClient: CursorAPIClient(configuration: config))
        reloaded.updateCheckRunner = { .upToDate }
        XCTAssertEqual(reloaded.jumpGlyphStyle, .dollar)

        UserDefaults.standard.removeObject(forKey: "jumpGlyphStyle")
    }
}
