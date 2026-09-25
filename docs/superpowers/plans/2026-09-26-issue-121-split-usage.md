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

- [ ] Add boundary-tolerant optional pool fields and period endpoint; legacy initializers keep defaults.
- [ ] Define stable pool identities, split snapshot and eligibility helpers; prove personal paid capability and legacy exclusions with fixtures.
- [ ] Decode monthly costs into Decimal; define classification with source/version, explicit kind handling and Bot precedence.
- [ ] Implement complete-cycle traversal with exact budget/coverage/order/overlap/stability evidence and one bounded retry.
- [ ] Implement raw-total reconciliation and conditional effective-limit estimates with explicit provisional attribution.
- [ ] Implement aggregate-only atomic bounded scope-bound cache, injectable/no default disk opening in tests.
- [ ] Tests cover boundary values, page mutation/termination, classification traps, fractional cents, unknowns, stale snapshots, ownership and budget exhaustion.
- [ ] Publish final public signatures to coordinator and UI worker before integration edits.

## Task 2 — Scoped event policy and notification delivery (worker B)

Owned files: `NotificationManager.swift`; new `SplitUsageAlerts.swift`, `SplitUsageAlertStore.swift`; tests `SplitUsageAlertsTests.swift`, `SplitUsageAlertStoreTests.swift` and directly affected notification tests. Do not edit view model, coordinator or app delegate.

- [ ] Implement the nonblocking VM-owned bounded dispatcher with independent threshold/Bold cancellation and injected delivery.
- [ ] Pure accepted-observation input with ownership identity and independent included/cursor/other/paid signals, without depending on async history.
- [ ] Threshold scope/target/value identities, highest severity, successful-delivery recording and bounded persistence.
- [ ] High-water/continuity jump policy, exact 5/30 cent and 5/15 pp triggers, paid cap/enabled transitions and recovery baseline.
- [ ] One event batch combines independently gated threshold and Bold events, with honest unattributed aggregate text.
- [ ] Inject permission/submission/store; protect in-flight work across scope and policy changes; retry failed delivery without duplicate successes.
- [ ] Keep legacy API paths; remove guessed Max-mode cause; add current-popover click mapping.
- [ ] Tests for race/interleaving, restart, failure/retry, targets vs Bold independence, aggregate .20+.20, high-water rebound, delayed enrichment exclusion.
- [ ] Publish adapter API and event-to-legacy-emoji tier bridge to coordinator.

## Task 3 — Presentation primitives (worker C, after data interface agreement)

Owned files: `CircularProgressIcon.swift`; new `SplitUsagePresentation.swift`; tests `SplitUsagePresentationTests.swift`, dedicated additions to icon tests. This task does not edit Settings or popover until coordinator confirms data interfaces.

- [ ] C icon with independent center/outer progress and missing-vs-zero geometry, stable identity placement, 70/90 colors and 18/20px coverage.
- [ ] One formatter supplies hover, AX and per-pool amount/estimate/status/time rows using only coherent published values.
- [ ] Presentation states for ready/pending/partial/missing/stale/paid/Bot and no session; no private or raw source information.
- [ ] Offscreen AppKit/image and pure text tests; no installed app launch.

## Checkpoint B — Core review and integration contract

- [ ] Coordinator checks data/alert/presentation tests and file ownership.
- [ ] Run full tests and build on combined core.
- [ ] Muse/Grok/Opus fresh read-only review of core diff and specification; record/fix material findings and rerun affected tests.
- [ ] Commit the independently working data and notification domains in meaningful units with issue and co-author trailers.

## Task 4 — Main-actor integration (coordinator)

Owned files: `UsageViewModel.swift`, `CursorMeterApp.swift`, `JumpEffectCoordinator.swift`; new `SplitUsageController.swift` if needed to keep monthly task ownership out of the large view model; dedicated integration tests.

- [ ] Add observed snapshot/amount state and additive preference keys with existing initialization defaults.
- [ ] Bind verified personal scope/generation/cycle, fast publish/event evaluation before history, and independently coalesced monthly task with result-specific backoff, changed-input gating and rolling page quota.
- [ ] Latched split summary failure is meter failure, never a fresh usage-only legacy fallback. Initial activation requires successful usage decode; preserve split fields in display copies.
- [ ] Cache loading after identity validation, ownership validation after each await, cancel/clear on logout/expiry/transition and preserve verified renewal semantics.
- [ ] Bypass legacy paid-latch replacement only for split capability; preserve legacy and enterprise paths.
- [ ] Apply pure event output to both emoji and one system-notification batch without a second coordinator banner.
- [ ] Invalidate policy on settings changes; rebaseline on wake/failure/gaps.
- [ ] Wire production-only stores and notification seams; tests never touch Keychain or real notification center.
- [ ] Extend observation re-arm lists. Keep title/tooltip/AX current during emoji image ownership.
- [ ] Verify primary/amount concurrency, same-account renewal, old-account responses, late enrichment, saved preference restoration and complete existing auth/refresh suite.

## Task 5 — Native app surfaces (UI worker; disjoint from integration)

Owned files: `MenuBarView.swift`, `SettingsAppearanceTabViewController.swift`, `SettingsNotificationsTabViewController.swift`, `SettingsUsageTabViewController.swift`, `SettingsTabViewController.swift` only if needed for observations; dedicated UI tests. Coordinator supplies stable view-model API first.

- [ ] Split popover rows and 300pt bounded layout, existing identity/reset/chart/errors/update/footer/actions preserved.
- [ ] Display hover/placement/legacy preference, both emoji styles and all weekly controls retained.
- [ ] Alerts targets and honest independent Bold explanation; native slider unchanged.
- [ ] Usage Summary/Recent with separate freshness, coverage, inferred-limit caveat and retained table/timezone/feedback.
- [ ] Offscreen AppKit fitting tests across largest/empty/partial states; do not install/relaunch or capture running app.

## Task 6 — Documentation, issue and final review (coordinator)

- [ ] Update synthetic HTML prototypes/screenshots and portable issue #121 contract, remove obsolete emoji-only/pp-only proposal.
- [ ] API reference documents exact field provenance and policy vs observed behavior.
- [ ] Update README/README.ko together; stale-reference sweep includes UI strings and docs. Do not claim native screenshots were refreshed.
- [ ] Update test checklist and write next-morning native walkthrough with all changed settings/Bold/hover/auth/loading states.
- [ ] Full `swift test`, debug/release `swift build`, existing installer tests where relevant; record actual output and compiler versions.
- [ ] Muse/Grok/Opus final branch review with test evidence; reconcile findings and rerun affected tests.
- [ ] Final spec compliance and code quality checks, clean intended diff, meaningful commits. Leave branch for user manual validation; no main merge/release.
- [ ] Deliver final report with review outcomes, tested boundaries, limitations and manual verification checklist.
- [ ] Stop only task-owned caffeine assertion after all authorized work is complete; mark goal complete.
