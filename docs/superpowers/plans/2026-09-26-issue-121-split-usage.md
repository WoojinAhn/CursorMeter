# Split usage implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development for execution and superpowers:verification-before-completion before declaring a task complete. The user explicitly selected parallel development: run only disjoint workstreams concurrently, with coordinator-owned integration and shared docs. This overrides the generic skill's sequential-only suggestion.

**Goal:** Implement issue #121 according to the reviewed split-usage specification, preserving existing settings, authentication and ordinary dollar-sensitive Bold notifications.

**Architecture:** Keep the existing main-actor view model and refresh admission. Add optional split display values, a bounded independent monthly collector with exact monetary DTOs and a separate cache, and a scoped event policy. Publish summary first; enrich later without replaying notifications. Keep the existing legacy path intact. Native AppKit surfaces consume one coherent presentation formatter.

**Tech Stack:** Swift 6, AppKit, Foundation/Decimal, UserNotifications and existing macOS SDKs only; XCTest with injected boundaries. No dependencies.

**Specification:** `docs/superpowers/specs/2026-09-26-issue-121-split-usage-design.md`.

## Execution and ownership

All work is on `feature/121-split-usage`; preserve pre-existing untracked artifacts and `.gitignore` edits. No install/relaunch/defaults mutation/native live capture. Coordinator alone owns `UsageViewModel.swift`, `CursorMeterApp.swift`, `SplitUsageController.swift`, `CycleCollectionSchedule.swift`, their integration/scheduling tests, shared docs, issue updates and commits. Workers do not edit README/AGENTS/central integration, commit, or reset another worker's changes.

Review checkpoint A must finish and material findings be reconciled before feature implementation. Each implementation worker receives its exact contract and file ownership, writes meaningful failing tests before feature code, verifies red/green, and returns tests plus concerns. Coordinator checks spec compliance, then code quality. Three external models repeat at core checkpoint B and final checkpoint C.

## Task 0 — Baseline and review A

- [x] Fetch/compare baseline and create feature branch.
- [x] Recover exact prior Cursor model identifiers.
- [x] Capture untouched baseline test failure under installed Swift 6.4.
- [x] Minimal build prerequisite: remove `nonisolated` from the `@MainActor` application's static main. Existing 642 tests pass; retain this separate from feature behavior.
- [x] Complete Muse/Grok/Opus specification reviews and record resolutions.
- [x] Finalize implementable contracts and checkpoint specification commit.

## Task 1 — Data and cycle amount domain (worker A)

Owned files: `UsageModels.swift`, `CursorAPIClient.swift`; new `SplitUsageModels.swift`, `CycleUsageModels.swift`, `CycleUsageCollector.swift`, `CycleUsageStore.swift`; dedicated tests `SplitUsageModelsTests.swift`, `CycleUsageCollectorTests.swift`, `CycleUsageStoreTests.swift`, `CycleUsageAPITests.swift`. Existing weekly/recent DTOs are not repurposed.

- [x] Add boundary-tolerant optional pool fields and period endpoint; legacy initializers keep defaults.
- [x] Define stable pool identities, split snapshot and eligibility helpers; prove personal paid capability and legacy exclusions with fixtures.
- [x] Decode monthly costs into Decimal; define classification with source/version, explicit kind handling and Bot precedence.
- [x] Implement complete-cycle traversal with exact budget/coverage/order/overlap/stability evidence and one bounded retry.
- [x] Implement raw-total reconciliation and conditional effective-limit estimates with explicit provisional attribution.
- [x] Implement aggregate-only atomic bounded scope-bound cache, injectable/no default disk opening in tests.
- [x] Tests cover boundary values, page mutation/termination, classification traps, fractional cents, unknowns, stale snapshots, ownership and budget exhaustion.
- [x] Publish final public signatures to coordinator and UI worker before integration edits.

## Task 2 — Scoped event policy and notification delivery (worker B)

Owned files: `NotificationManager.swift`; new `SplitUsageAlerts.swift`, `SplitUsageAlertStore.swift`; tests `SplitUsageAlertsTests.swift`, `SplitUsageAlertStoreTests.swift` and directly affected notification tests. Do not edit view model, coordinator or app delegate.

- [x] Implement the nonblocking VM-owned bounded dispatcher with independent threshold/Bold cancellation and injected delivery.
- [x] Pure accepted-observation input with ownership identity and independent included/cursor/other/paid signals, without depending on async history.
- [x] Threshold scope/target/value identities, highest severity, successful-delivery recording and bounded persistence.
- [x] High-water/continuity jump policy, exact 5/30 cent and 5/15 pp triggers, paid cap/enabled transitions and recovery baseline.
- [x] One event batch combines independently gated threshold and Bold events, with honest unattributed aggregate text.
- [x] Inject permission/submission/store; protect in-flight work across scope and policy changes; retry failed delivery without duplicate successes.
- [x] Keep legacy API paths; remove guessed Max-mode cause; add current-popover click mapping.
- [x] Tests for race/interleaving, restart, failure/retry, targets vs Bold independence, aggregate .20+.20, high-water rebound, delayed enrichment exclusion.
- [x] Publish adapter API and event-to-legacy-emoji tier bridge to coordinator.

## Task 3 — Presentation primitives (worker C, after data interface agreement)

Owned files: `CircularProgressIcon.swift`; new `SplitUsagePresentation.swift`; tests `SplitUsagePresentationTests.swift`, dedicated additions to icon tests. This task does not edit Settings or popover until coordinator confirms data interfaces.

- [x] C icon with independent center/outer progress and missing-vs-zero geometry, stable identity placement, 70/90 colors and 18/20px coverage.
- [x] One formatter supplies hover, AX and per-pool amount/estimate/status/time rows using only coherent published values.
- [x] Presentation states for ready/pending/partial/missing/stale/paid/Bot and no session; no private or raw source information.
- [x] Offscreen AppKit/image and pure text tests; no installed app launch.

## Checkpoint B — Core review and integration contract

- [x] Coordinator checks data/alert/presentation tests and file ownership.
- [x] Run full tests and build on combined core. Initial checkpoint: 753 tests, zero failures, debug build passed; later integration checkpoint: 762 tests, zero failures.
- [x] Muse/Grok/Opus fresh read-only review of core diff and specification; record/fix material findings and rerun affected tests.
- [x] Commit the integrated feature and tests with issue/co-author trailers (`c89e0ba`); the separate prerequisite and reviewed specification commits remain distinct.

## Task 4 — Main-actor integration (coordinator)

Owned files: `UsageViewModel.swift`, `CursorMeterApp.swift`, `JumpEffectCoordinator.swift`; new `SplitUsageController.swift` if needed to keep monthly task ownership out of the large view model; dedicated integration tests.

- [x] Add observed snapshot/amount state and additive preference keys with existing initialization defaults.
- [x] Bind verified personal scope/generation/cycle, fast publish/event evaluation before history, and independently coalesced monthly task with result-specific backoff, changed-input gating and rolling page quota.
- [x] Latched split summary failure is meter failure, never a fresh usage-only legacy fallback. Initial activation requires successful usage decode; preserve split fields in display copies.
- [x] Cache loading after identity validation, ownership validation after each await, cancel/clear on logout/expiry/transition and preserve verified renewal semantics.
- [x] Bypass legacy paid-latch replacement only for split capability; preserve legacy and enterprise paths.
- [x] Apply pure event output to both emoji and one system-notification batch without a second coordinator banner.
- [x] Invalidate policy on settings changes; rebaseline on wake/failure/gaps.
- [x] Wire production-only stores and notification seams; tests never touch Keychain or real notification center.
- [x] Extend observation re-arm lists. Keep title/tooltip/AX current during emoji image ownership.
- [x] Verify primary/amount concurrency, same-account renewal, old-account responses, late enrichment, saved preference restoration and complete existing auth/refresh suite.

## Task 5 — Native app surfaces (UI worker; disjoint from integration)

Owned files: `MenuBarView.swift`, `SettingsAppearanceTabViewController.swift`, `SettingsNotificationsTabViewController.swift`, `SettingsUsageTabViewController.swift`, `SettingsTabViewController.swift` only if needed for observations; dedicated UI tests. Coordinator supplies stable view-model API first.

- [x] Split popover rows and 300pt bounded layout, existing identity/reset/chart/errors/update/footer/actions preserved.
- [x] Display hover/placement/legacy preference, both emoji styles and all weekly controls retained.
- [x] Alerts targets and honest independent Bold explanation; native slider unchanged.
- [x] Usage Summary/Recent with separate freshness, coverage, inferred-limit caveat and retained table/timezone/feedback.
- [x] Offscreen AppKit fitting tests across largest/empty/partial states; do not install/relaunch or capture running app.

## Task 6 — Documentation, issue and final review (coordinator)

- [x] Update five synthetic HTML references and the Bold screenshot; preserve both glyph styles and dollar sensitivity. Final issue text follows the reviewed specification.
- [x] API reference documents exact field provenance and policy vs observed behavior.
- [x] Update README/README.ko and SECURITY/SECURITY.ko together; stale-reference sweep includes UI strings and docs. Native screenshots remain explicitly pending.
- [x] Update test checklist and write next-morning native walkthrough with all changed settings/Bold/hover/auth/loading states.
- [x] Gate B final validation: 819 Swift tests, debug/release builds, 12 installer tests; Swift 6.4. Final review changes require affected checks again.
- [x] Muse/Grok/Opus final branch review with test evidence; reconcile findings and rerun affected tests.
- [x] Final spec compliance and code quality checks, clean intended diff, meaningful commits. Leave branch for user manual validation; no main merge/release.
- [x] Deliver final report with review outcomes, tested boundaries, limitations and manual verification checklist.
Final runtime cleanup: after publication verification, stop only the task-owned caffeine
assertion and mark the goal complete. The cleanup receipt belongs to the task runtime.

Final source: `9287e0a`; 838 local Swift tests passed, ARM/Intel CI passed, all three
review gates completed and the final Grok continuation closed the two retry findings.
See the [implementation report](../reports/2026-09-26-issue-121-implementation.md).
