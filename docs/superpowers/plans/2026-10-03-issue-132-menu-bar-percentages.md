# Optional stacked menu-bar percentages implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development for bounded
> helper tasks and superpowers:executing-plans for coordinator-owned integration.
> Execute continuously under the owner's explicit issue → development → reviewed
> PR → merge authorization. Do not ask for permission again at ordinary checkpoints.

**Goal:** Implement [#132](https://github.com/WoojinAhn/CursorMeter/issues/132) using
the reviewed layout A and independent default-off Settings control.

**Architecture:** A pure optional readout derives the two ordered percentage
strings under the existing split/auth/data gate. A measured AppKit compositor
joins an 18 pt icon and that readout. The jump coordinator owns only transient
glyph/timing state and requests a current-state redraw through an injected sink;
it never saves numeric text or a composite bitmap for restoration.

**Tech stack:** Swift 6, AppKit, Foundation, Observation, XCTest; no new dependencies.

**Scope authority:** The 2026-10-03 owner instruction authorizes implementation,
GitHub issue/PR writes, push, reviews, and merge. It supersedes the spec's earlier
documentation-stage stop. Functional requirements remain unchanged. No release,
local app replacement, live credential experiment, or unrelated fix is authorized.

**Workspace:** `.Codex/worktrees/issue-132`, branch
`feature/132-menu-bar-percentages`, based on `origin/main` `8c71cbb` plus reviewed
spec commit `fdf88e4`. Preserve all unrelated files in the original checkout.

## Test selection and safe baseline

- [x] Fetch/compare `origin/main` and create issue before application changes.
- [x] Preserve approved local HTML as `docs/mockup-132.html`; do not commit it.
- [x] Baseline: 1050 tests, zero failures. Two pre-existing tests that save real
  Keychain credentials are excluded locally; CI runs the full suite on ephemeral
  runners. These exclusions are not permission to repair unrelated auth tests.

Local broad regression command (verified against installed `swift test --help`):

```sh
swift test --skip 'CredentialChainTests/testBrowserLoginClearsSuppression|IDESignInGuidanceTests/test_watch_stopsWhenLoggedInViaBrowser'
```

Focused groups: new readout/compositor tests, new jump orchestration tests, settings
and split presentation/UI tests, existing jump policy and profile-404 ownership
regressions. Never call the production app delegate's launch method in SPM; it
instantiates the real notification center. Never access the real Keychain or IDE DB.

## Task 1: Readout and native compositor

**Files:**
- Create `Sources/CursorMeter/SplitMenuBarPresentation.swift`.
- Create `Sources/CursorMeter/SplitMenuBarRenderer.swift`.
- Create `Tests/CursorMeterTests/SplitMenuBarPresentationTests.swift`.
- Create `Tests/CursorMeterTests/SplitMenuBarRendererTests.swift`.

- [x] Write focused failing tests for the visibility truth table, ordered pool
  strings, checking fallback, formatter boundaries, and independence from Dollars/
  Both. Use synthetic `SplitUsageSnapshot` fixtures copied in shape from existing
  `SplitUsagePresentationTests`, not real account/cycle values.
- [x] Implement the pure state seam using this contract:

```swift
struct SplitMenuBarReadout: Equatable, Sendable {
    let upper: String
    let lower: String

    static func make(
        enabled: Bool, isLoggedIn: Bool, hasUsageData: Bool,
        suppressesLegacyMeter: Bool, presentation: SplitUsagePresentation?
    ) -> Self? {
        guard enabled, isLoggedIn, hasUsageData, suppressesLegacyMeter else {
            return nil
        }
        guard let presentation else { return Self(upper: "—", lower: "—") }
        return Self(upper: presentation.pools[0].percentText,
                    lower: presentation.pools[1].percentText)
    }
}
```

Representative truth-table expectation:

```swift
XCTAssertNil(SplitMenuBarReadout.make(
    enabled: true, isLoggedIn: false, hasUsageData: true,
    suppressesLegacyMeter: true, presentation: nil))
XCTAssertEqual(SplitMenuBarReadout.make(
    enabled: true, isLoggedIn: true, hasUsageData: true,
    suppressesLegacyMeter: true, presentation: nil),
    SplitMenuBarReadout(upper: "—", lower: "—"))
```

- [x] Add a renderer with `image(icon: NSImage, readout: SplitMenuBarReadout) ->
  NSImage` and a pure measured layout description. Use an 18 pt icon slot, 4 pt gap,
  22 pt height, 10 pt medium monospaced digits, complete formatter strings, and
  trailing-aligned rows. Measure ordinary + boundary reserve strings using the same
  font; take max(reserve, upper width, lower width). Add optical end padding if
  native glyph bounds require it. Use the existing NSImage drawing-handler pattern
  and current dynamic label color.
- [x] Add geometry and rendered-ink tests at available 1×/2× scales: stable ordinary
  width; larger value expansion; nil/zero distinction; both rows inside canvas;
  ordinary and high-contrast light/dark appearances; icon pixels do not extend into
  text. Do not assert OS-specific exact glyph bitmaps or reuse the legacy integer
  formatter.
- [x] Run `swift test --filter 'SplitMenuBar(Presentation|Renderer)Tests'` and verify
  passing assertions. Keep the new helper files independent of networking/persistence.
- [x] Coordinator checks spec compliance, then code quality before committing the
  coherent tested unit with `[#132] feat: add compact split menu-bar rendering`.

## Task 2: Narrow jump ownership and deterministic orchestration tests

**Files:**
- Modify `Sources/CursorMeter/JumpEffectCoordinator.swift`.
- Add orchestration cases to `Tests/CursorMeterTests/JumpEffectCoordinatorTests.swift`.
- Modify the constructor wiring in `Sources/CursorMeter/CursorMeterApp.swift` only
  as needed to keep the build coherent before the later integration task.

- [x] Introduce a small active-glyph value (emoji, glow, captured fallback size).
  It must contain no snapshot, percentage strings, account identity, or composite.
- [x] Replace the concrete status-item dependency with three narrow injected
  operations: `render(activeGlyph?)`, `fallbackImageSize()`, and
  `scheduleRestore(delay, action) -> cancelClosure`. Use MainActor closures and a
  production Timer scheduler; use a captured action/cancellation counter in tests.
- [x] Add `redraw()` to call `render(activeGlyph)` without touching the timer.
  `restore()` cancels/clears active state before rendering nil; no recursive image
  provider or stale cached-image restoration. A new jump alone starts a new timer.
- [x] Capture split fallback size as 18×18 at jump start, even when numeric canvas
  is wider. The initial legacy shim captures the existing image; Task 3 replaces
  that sample with the base meter size before wide composites become possible.
- [x] Write a deterministic sequence test using mutable synthetic current readout
  state in the injected renderer:

```swift
// The scheduler records one restore action and returns a cancellation closure.
// Publish a tier-2 jump through the existing view-model jump fixture seam.
// Drain Observation callbacks with Task.yield(), never a real 15-second delay.
// Then mutate current values, placement, and enabled state and call redraw().
XCTAssertEqual(scheduleCount, 1)
XCTAssertEqual(cancelCount, 0)
// Invoke the saved restore action: the final rendering must use current values.
```

- [x] Cover disabled effects/auth cancellation, logged-in ownership retirement
  clearing numeric data while the glyph keeps its deadline, repeated event
  deduplication, fallback size, and restoring after preference off/on. Keep all
  existing tier/style/duration tests.
- [x] Run `swift test --filter 'JumpEffectCoordinatorTests|SplitMenuBar'`.
- [x] Coordinator compliance/quality pass, then **Checkpoint A:** fresh read-only
  Grok `grok-4.7-xhigh`, Gemini `gemini-3.8-flash-high`, and Opus
  `claude-opus-5-5-max` reviews of this core diff plus spec. Resolve factual findings,
  discuss disagreements in targeted follow-ups, and record Astra's disposition.
- [x] Commit the coherent passing integration as `[#132] refactor: preserve split
  readouts during jump effects` once checkpoint findings are closed.

## Task 3: Preference, Settings, and live observation integration

**Files:**
- Modify `Sources/CursorMeter/UsageViewModel.swift` using targeted ranges only.
- Modify `Sources/CursorMeter/SettingsAppearanceTabViewController.swift`.
- Modify `Sources/CursorMeter/CursorMeterApp.swift`.
- Add `Tests/CursorMeterTests/SplitMenuBarSettingsTests.swift` and relevant UI cases.

- [x] Add the new key, default-false property, setter, and load value using existing
  persistence conventions:

```swift
// SettingsKey case: splitMenuBarPercentagesEnabled
private(set) var splitMenuBarPercentagesEnabled = false

func setSplitMenuBarPercentagesEnabled(_ enabled: Bool) {
    splitMenuBarPercentagesEnabled = enabled
    UserDefaults.standard.set(enabled, for: .splitMenuBarPercentagesEnabled)
}
// In loadSettings:
splitMenuBarPercentagesEnabled = defaults.object(for: .splitMenuBarPercentagesEnabled)
    as? Bool ?? false
```

- [x] Add a computed `splitMenuBarReadout` delegating to Task 1's pure maker. Do not
  store current or prior percentages independently. Preserve the setting through
  account/logout resets and legacy fallback.
- [x] Add the switch after Outer ring with label/AX label `Show percentages` and
  existing split-only row visibility. Bind it to the setter. Preview uses the same
  circle/readout renderer, never the active glyph; maintain a 28 pt ring and reserve
  approximately 35 pt container height. Preserve the exact outer/center legend.
- [x] App renderer uses current readout for both normal and active-glyph paths.
  Keep legacy/idle/login base selection intact. All final image writes flow through
  the coordinator redraw sink once initialized; tooltip/AX remains unchanged.
- [x] Checkpoint A refinement (Grok, Gemini, Opus and Astra): legacy jump starts
  measure `currentRingImage().size`, not the button's possibly transient composite.
  Keep the explicit 18 pt split fallback. An existing active glyph retains its
  captured fallback until the next event/restore; a split numeric composition always
  creates a fresh 18 pt slot emoji, even after a wide legacy jump.
- [x] Add the new preference/readout dependencies to BOTH `observeStatusItem()` and
  `observeSettings()` re-arm blocks. Ensure observation handles data retirement
  during a swap without rescheduling it.
- [x] Test default-off/load/save with saved/restored keys in the verified separate
  test-host domain, or an isolated suite if unavailable. Test setting independence,
  legacy-hidden controls, checking-operable control, unchanged tooltip, partial
  missing values, retained no-cookie login-required data, and valid degraded-profile
  data. No production auth changes are needed to create these fixtures.
- [x] Run `swift test --filter 'SplitMenuBar|SplitUsageUI|SplitUsagePresentation|JumpEffectCoordinator'`.
- [x] Coordinator compliance/quality checks, then commit this coherent passing unit
  as `[#132] feat: expose stacked percentages in display settings`.

## Task 4: Native evidence and user documentation

**Files:**
- Update `README.md` and `README.ko.md` together.
- Update `docs/screenshots/settings-display.png` after inspecting for PII.
- Add narrowly scoped synthetic test/capture hooks only if current fixtures cannot
  exercise the new surface safely. Coordinator owns all docs/shared files.

- [ ] Use a synthetic AppKit fixture in its own process/domain, with no production
  startup/auth/session check, to verify a real status item, Settings, and Observation
  wiring. Do not run the installation/capture script that kills/replaces the app.
- [ ] Inspect AX-addressed native captures: toggle off/on, both placements, normal/
  near-100/missing readouts, jump redraw/restore, light/dark/high contrast, available
  backing scales, Settings preview shape, tooltip, and named accessibility value.
  Do not use screen-coordinate clicks. Keep private test captures local.
- [ ] Refresh the committed Display screenshot with synthetic account data, retaining
  current repository screenshot framing and inspecting the image before staging.
- [ ] Update README feature/hover descriptions in both languages; describe the new
  default-off switch and preserve hover. Sweep old icon-only claims and clarify the
  superseding opt-in exception without changing unrelated prior designs.
- [x] Run the safe broad Swift suite, `swift build -c release`, and installer tests.
  Capture exact command results and failures; do not claim native checks from HTML.
- [ ] **Checkpoint B:** the same three fresh Cursor models review the full integrated
  diff, test evidence, and any remaining native limitations. Astra independently
  adjudicates, implements valid findings, and seeks focused agreement as needed.
- [ ] Commit docs/screenshots and any review fixes as meaningful separate commits.

## Task 5: PR, independent review, CI, and merge

- [ ] Push the feature branch and create an English PR closing #132. Include behavior,
  spec link, test counts, native evidence, local Keychain-test exclusions versus CI,
  and scope limits. Keep local HTML/review logs out of the PR.
- [ ] Check the exact head CI on both `macos-15` and `macos-15-intel`.
- [ ] **Checkpoint C:** all three Cursor models review the complete PR diff versus
  fresh `origin/main`, not merely the latest commit. Astra also performs an
  independent frontier review and posts the adjudicated summary to the PR.
- [ ] Resolve every actionable finding against facts; use targeted tests and review
  follow-ups. Re-run checks for changed code; do not relaunch failed model inference
  silently or substitute models. Recover a proven completed result when runtime
  metadata is stale; record success/exit provenance.
- [ ] Merge only after final evidence supports it and CI is green. The owner already
  authorized Astra to make this decision and execute the merge; no extra approval
  wait is needed. Do not claim a GitHub self-comment is an independent APPROVE event.
- [ ] Verify main contains the merged changes, main CI succeeds, and #132 is closed.
  List remaining open issues per project policy. Preserve original local dirt and
  avoid branch/worktree deletion unless safe and authorized by the completed work.
- [ ] Stop only the task-owned caffeine process, finalize progress, mark /goal
  complete, and report PR/merge/check results concisely in Korean.

## Coordination and review policy

The source spec governs functional choices; exact small helper APIs may be refined
without changing behavior. Material contract changes require evidence and renewed
discussion with the three review models, plus Astra's affirmative judgment. Owner
decisions (A, Settings control, retained hover) are not silently changed. If a
decision genuinely requires the owner, complete independent work first and present
the concrete alternatives rather than guessing.

No cron/heartbeat reports: update progress and the thread on meaningful phase
changes, first Sources/Tests edits, review completion/failure, PR creation, blockers,
and goal completion. The three-model runtime uses native workers; worker capacity
may require reusing an idle worker, never duplicating a started job.
