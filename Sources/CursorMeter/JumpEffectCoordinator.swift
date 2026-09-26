import AppKit
import Observation

/// Orchestrates the menu-bar icon swap (and optional system notification) when the
/// `UsageViewModel` publishes a new `lastJump`. Lives outside the view model so that
/// view-model code stays UI/notification free.
///
/// - Observes `viewModel.lastJump` via Swift Observation tracking (re-arm pattern).
/// - On a relevant tier (per `JumpIntensity` policy), swaps `statusItem.button.image`
///   to a fixed-size emoji glyph rendered by `CircularProgressIcon.makeEmojiImage`.
/// - Schedules a `Timer` to restore the original ring image via the injected
///   `restoreImage` closure.
/// - On `Bold + tier 2`, additionally fires `NotificationManager.notifyUsageJump`.
@MainActor
final class JumpEffectCoordinator {
    private let statusItem: NSStatusItem
    private let viewModel: UsageViewModel
    private let notifier: NotificationManager
    private let restoreImage: () -> NSImage

    private var swapTimer: Timer?
    private var isObserving = false
    private var handledEvent: JumpEvent?

    /// True while an emoji is currently displayed in the status item and the
    /// restore timer is still pending. Callers can consult this to avoid
    /// clobbering the emoji with a stale ring image.
    var isSwapping: Bool { swapTimer != nil }

    init(
        statusItem: NSStatusItem,
        viewModel: UsageViewModel,
        notifier: NotificationManager,
        restoreImage: @escaping () -> NSImage
    ) {
        self.statusItem = statusItem
        self.viewModel = viewModel
        self.notifier = notifier
        self.restoreImage = restoreImage
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
        swapTimer?.invalidate()
        swapTimer = nil
    }

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
            swapTimer?.invalidate()
            restore()
            handledEvent = viewModel.lastJump
            return
        }
        guard let event = viewModel.lastJump, event != handledEvent else { return }
        handledEvent = event

        let decision = Self.shouldFire(intensity: viewModel.jumpIntensity, tier: event.tier)
        guard decision.fire else { return }

        let (emoji, glow, durationMs) = Self.swapParams(for: event.tier, style: viewModel.jumpGlyphStyle)
        performSwap(emoji: emoji, glow: glow, durationMs: durationMs)

        if decision.notify && !event.isSplitUsage {
            let delta = event.displayDelta
            let usage = viewModel.usageData?.usageText ?? ""
            Task { @MainActor [notifier] in
                await notifier.notifyUsageJump(displayDelta: delta, currentUsage: usage)
            }
        }
    }

    // MARK: - Image swap

    private func performSwap(emoji: String, glow: Bool, durationMs: Int) {
        guard let button = statusItem.button else { return }
        let size = button.image?.size ?? NSSize(width: 22, height: 22)
        button.image = CircularProgressIcon.makeEmojiImage(emoji: emoji, size: size, glow: glow)

        swapTimer?.invalidate()
        swapTimer = Timer.scheduledTimer(
            withTimeInterval: TimeInterval(durationMs) / 1000.0,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in
                self?.restore()
            }
        }
    }

    private func restore() {
        statusItem.button?.image = restoreImage()
        swapTimer = nil
    }

    // MARK: - Intensity policy (pure, testable)

    /// Decides whether a jump tier should trigger the icon swap and/or a system
    /// notification under the given `JumpIntensity`. Pure function — no side effects.
    ///
    /// Policy (per Issue #55 Final spec):
    /// - `quiet`:  only `tier == .two` fires the swap. Tier 0/1 ignored. Never notifies.
    /// - `normal`: tier 1 and tier 2 fire the swap. Never notifies.
    /// - `bold`:   tier 1 and tier 2 fire the swap. Tier 2 additionally notifies.
    /// - `tier == .zero` is always a no-op regardless of intensity.
    nonisolated static func shouldFire(
        intensity: JumpIntensity,
        tier: JumpEvent.Tier
    ) -> (fire: Bool, notify: Bool) {
        switch tier {
        case .zero:
            return (false, false)
        case .one:
            switch intensity {
            case .quiet:  return (false, false)
            case .normal: return (true, false)
            case .bold:   return (true, false)
            }
        case .two:
            switch intensity {
            case .quiet:  return (true, false)
            case .normal: return (true, false)
            case .bold:   return (true, true)
            }
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
