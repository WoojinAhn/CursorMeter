# Hide Empty Prepaid UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this cohesive task. Steps use checkbox syntax for tracking.

**Goal:** Remove empty prepaid meter presentation from the installed app when the current verified remaining balance is zero, including exhausted wallets.

**Architecture:** Centralize visibility in SharedUsagePresentation and consume it in the popover, status item, and Display settings. Add an explicit omitted-center rendering path and a vertically centered single percentage. Keep billing data collection, legacy rendering, and persisted preferences intact.

**Tech Stack:** Swift 6, AppKit, XCTest; no dependencies.

---

## Accepted behavior

The user explicitly requests implementation and local installation. The before/after preview is `docs/mockup-150.html`. Keep the existing outer ring geometry, typography and layout; remove unused elements and their spacing. Do not add a no-purchases or exhausted message. Keep Manage Credits visible for shared weekly accounts even at zero balance, as explicitly clarified by the user. No additional design approval is needed for this requested removal.

| Input | Credit presentation |
| --- | --- |
| Current balance zero, any purchase history | Hidden everywhere |
| Positive balance, known or unknown total | Existing presentation |
| Missing or stale credit | Existing unavailable/stale presentation; never infer zero |
| Zero plus monthly paid > 0 or reached paid cap | Preserve meaningful monthly paid/cap line |
| Zero plus Auto Top-up enabled | Preserve meaningful enabled status; paid-period reset belongs only to a visible monthly paid line |
| Zero plus monthly paid zero and Auto Top-up off/unknown | Omit irrelevant billing lines and paid reset |

## Task 1: Visibility and connected surfaces

**Files:** `SharedUsagePresentation.swift`, `CircularProgressIcon.swift`, `SplitMenuBarPresentation.swift`, `SplitMenuBarRenderer.swift`, `CursorMeterApp.swift`, `MenuBarView.swift`, `SettingsAppearanceTabViewController.swift`; tests in `SharedUsageUITests.swift`, `SharedUsageUIFixture.swift`, and renderer tests if needed.

- [x] Compare origin/main and installed d23e9bd; isolated branch `bugfix/150-hide-empty-prepaid` preserves the installed authentication fix. Baseline: 1,341 tests, zero failures.
- [x] Render and inspect the before/after HTML preview with Playwright.
- [x] Write failing tests for the behavior table. For zero balance, assert no prepaid/credit/top-up text across visible popover, status tooltip/accessibility and Display preview, while asserting Manage Credits remains present; assert both 18pt and 112pt icons have no central drawing. Test same-view zero → positive → zero transitions, stale/unknown data, meaningful paid details, jump icon restoration, percent toggle, and unchanged legacy two-pool rendering.
- [x] Run the focused suite and record expected failing assertions before implementation.
- [x] Implement one visibility decision, equivalent to `mode == .sharedWeekly && snapshot.credit.availability == .current && snapshot.credit.value?.remainingCents == 0` for hiding; preserve optional/stale semantics. Feed it into all title, row, tooltip, AX, preview and icon paths. Single readouts must be vertically centered, not a blank lower string with stacked layout.
- [x] Run focused and full `swift test`; run `swift build -c release`. Final results: 1,351 tests passed, release build succeeded.
- [x] Capture and inspect AppKit synthetic light/dark artifacts for empty, funded, exhausted and unknown states; cover transitions with view tests. Refresh affected public screenshots with synthetic identities only.
- [x] Independent specification review passed. Gemini Neon design findings were reproduced/adjudicated and corrected; a fresh Gemini Neon XHigh final static review approved the candidate with no blocking defects. The coordinator verified tests and renders separately. GitHub Bugbot remains pending user acceptance of usage-based billing; no Grok CLI calls.

## Task 2: Delivery

**Files:** four localized READMEs, `docs/screenshots/popover-shared-no-purchases.png`, `docs/screenshots/settings-shared-no-purchases.png`, issue #150 evidence. Coordinator owns documentation and delivery; implementer may edit only Sources and Tests.

- [x] Synchronize the shared behavior note in all four READMEs and sweep obsolete no-purchases presentation copy. Historical plans remain historical.
- [ ] Commit/push with #150, open a focused PR against the installed authentication branch, and inspect the resulting CI and GitHub review.
- [ ] Fetch origin/main before packaging, preserve the installed signing identity, back up the installed app and preferences, replace with the verified dev artifact and relaunch.
- [ ] Verify signature/hash/build marker/settings; use native AX paths to check the actual zero-credit UI and successful authentication. Keep account screenshots private. Update #150 with measured evidence and any limits.

No purchase, paid validation inference, auth changes, merge, public release or issue closure is included. The user separately authorized GitHub Grok review integration and a PR.
