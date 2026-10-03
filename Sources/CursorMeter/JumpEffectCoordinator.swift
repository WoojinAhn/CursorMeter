import AppKit
import Observation

struct ActiveJump: Equatable {
    let emoji: String
    let glow: Bool
    let fallbackSize: NSSize
}

/// Owns the transient glyph and deadline; the renderer reads current usage on every redraw.
@MainActor
final class JumpEffectCoordinator {
    typealias CancelRestore = @MainActor () -> Void
    typealias ScheduleRestore = @MainActor (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> CancelRestore

    private let viewModel: UsageViewModel
    private let render: @MainActor (ActiveJump?) -> Void
    private let fallbackImageSize: @MainActor () -> NSSize
    private let scheduleRestore: ScheduleRestore

    private var cancelRestore: CancelRestore?
    private var restoreGeneration: UInt64 = 0
    private var isObserving = false
    private var handledEvent: JumpEvent?
    private(set) var activeJump: ActiveJump?

    var isSwapping: Bool { activeJump != nil }

    init(
        viewModel: UsageViewModel,
        render: @escaping @MainActor (ActiveJump?) -> Void,
        fallbackImageSize: @escaping @MainActor () -> NSSize,
        scheduleRestore: ScheduleRestore? = nil
    ) {
        self.viewModel = viewModel
        self.render = render
        self.fallbackImageSize = fallbackImageSize
        self.scheduleRestore = scheduleRestore ?? { delay, action in
            let timer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
                Task { @MainActor in action() }
            }
            return { timer.invalidate() }
        }
    }

    /// Begin observing `viewModel.lastJump`. Idempotent — calling twice is a no-op.
    func start() {
        guard !isObserving else { return }
        isObserving = true
        observeLastJump()
    }

    /// Cancel pending restore timer and stop re-arming the observer. Note: an
    /// already-armed `withObservationTracking` callback may still fire once after
    /// `stop()` (Observation has no public cancellation), but it will see
    /// `isObserving == false` and bail out.
    func stop() {
        isObserving = false
        restore()
    }

    func redraw() { render(activeJump) }

    // MARK: - Observation (Combine-free, @Observable-compatible)

    private func observeLastJump() {
        withObservationTracking {
            _ = viewModel.lastJump
            _ = viewModel.jumpEffectEnabled
            _ = viewModel.authState
        } onChange: { [weak self] in
            // onChange is invoked on an arbitrary thread; bounce to MainActor.
            Task { @MainActor [weak self] in
                guard let self, self.isObserving else { return }
                self.handleLastJumpChange()
                self.observeLastJump() // re-arm for the next mutation
            }
        }
    }

    private func handleLastJumpChange() {
        guard viewModel.jumpEffectEnabled, viewModel.authState == .loggedIn else {
            restore()
            handledEvent = viewModel.lastJump
            return
        }
        guard let event = viewModel.lastJump, event != handledEvent else { return }
        handledEvent = event

        guard Self.shouldFire(intensity: viewModel.jumpIntensity, tier: event.tier) else { return }

        let (emoji, glow, durationMs) = Self.swapParams(for: event.tier, style: viewModel.jumpGlyphStyle)
        performSwap(emoji: emoji, glow: glow, durationMs: durationMs)

    }

    // MARK: - Image swap

    private func performSwap(emoji: String, glow: Bool, durationMs: Int) {
        cancelScheduledRestore()
        activeJump = ActiveJump(emoji: emoji, glow: glow, fallbackSize: fallbackImageSize())
        redraw()
        let generation = restoreGeneration
        cancelRestore = scheduleRestore(TimeInterval(durationMs) / 1000) { [weak self] in
            guard let self, self.restoreGeneration == generation else { return }
            self.restore()
        }
    }

    private func restore() {
        cancelScheduledRestore()
        activeJump = nil
        redraw()
    }

    private func cancelScheduledRestore() {
        restoreGeneration &+= 1
        cancelRestore?()
        cancelRestore = nil
    }

    // MARK: - Intensity policy (pure, testable)

    /// Decides whether a jump tier should trigger the icon swap.
    ///
    /// Policy (per Issue #55 Final spec):
    /// - `quiet`:  only `tier == .two` fires the swap. Tier 0/1 ignored.
    /// - `normal` and `bold`: tier 1 and tier 2 fire the swap.
    /// - `tier == .zero` is always a no-op regardless of intensity.
    nonisolated static func shouldFire(
        intensity: JumpIntensity,
        tier: JumpEvent.Tier
    ) -> Bool {
        switch tier {
        case .zero:
            return false
        case .one:
            switch intensity {
            case .quiet: return false
            case .normal, .bold: return true
            }
        case .two:
            return true
        }
    }

    /// Maps a tier + glyph style to its visual swap parameters. Pure function —
    /// exposed for testing. Tier 0 returns degenerate values; callers should
    /// gate via `shouldFire` first. `glow` and `durationMs` are style-agnostic.
    nonisolated static func swapParams(
        for tier: JumpEvent.Tier,
        style: JumpGlyphStyle = .classic
    ) -> (emoji: String, glow: Bool, durationMs: Int) {
        // Durations sized to the refresh cadence: the minimum auto-refresh
        // interval is 60 s, so up to 15 s of tier-2 indication still leaves
        // the icon on its normal ring most of the time. 1.5–3 s in the prior
        // iteration was reliably missed by users not staring at the menu bar.
        let (tier1Emoji, tier2Emoji) = Self.glyphs(for: style)
        switch tier {
        case .zero: return ("", false, 0)
        case .one:  return (tier1Emoji, false, 6000)
        case .two:  return (tier2Emoji, true, 15000)
        }
    }

    /// Returns the (tier-1, tier-2) emoji pair for the active style.
    nonisolated static func glyphs(for style: JumpGlyphStyle) -> (tier1: String, tier2: String) {
        switch style {
        case .classic: return ("⚡", "🚀")
        case .dollar:  return ("💲", "💸")
        }
    }
}
