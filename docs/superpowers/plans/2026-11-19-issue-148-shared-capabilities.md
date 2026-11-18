# Shared Subscription Capabilities Implementation Plan

> **For agentic workers:** Use Superpowers subagent-driven development and test-driven development. Complete specification review before quality review. The coordinator owns documentation and integration.

**Goal:** Restore existing features supported by verified shared-subscription inputs and accurately distinguish remaining unavailable data.

**Architecture:** Keep shared billing and legacy monthly state separate. Replace blanket capability suppression with shared weekly notification/jump processing using current, owner-bound weekly observations. Enable history-dependent features only after the current subscription's event source is verified; an HTTP 200 containing old-plan events is insufficient.

**Tech Stack:** Swift 6, AppKit, Foundation, existing notification and observation infrastructure; no new dependencies or login mechanism.

## Evidence and boundary

- Base: `676c037`, based on current `origin/main` with zero commits behind.
- Installed build `8997357` disables usage alerts, jump controls, chart/Today and recent history, confirmed through native accessibility paths.
- Source resets legacy activity on every shared refresh and returns before notification/jump/history processing. Existing tests incorrectly require this blanket suppression.
- A bounded authenticated DashboardService `GetFilteredUsageEvents` read succeeds, but a last-seven-days request returns no events. Do not use this old ledger for shared activity.
- Fresh current-dashboard reads at `https://cursor.com/api/dashboard/v2/` succeeded with the existing Cursor cookie: `usage-status`, `query-billing-items`, and `query-daily-usage`. The primary profile matched the selected credential. No redirects, new login or inference were involved.
- Daily points are UTC-midnight buckets even when the requested start uses a local offset. Preserve UTC day labels and explicitly identify that chart timezone; never relabel a UTC total as a local-day total.
- Preserve weekly outer/prepaid inner meanings and user preferences. Monthly dollar estimates and unsupported billing mutations remain outside this restoration.

## Task 1: Restore weekly alerts and jump effects

**Files:** `UsageViewModel.swift`, a focused shared-activity helper if needed, `NotificationManager.swift`, `CursorMeterApp.swift`, `SettingsNotificationsTabViewController.swift`, `SettingsAppearanceTabViewController.swift`, associated shared refresh/UI/jump tests.

- [x] Reproduce disabled controls in the installed app and locate the blanket guard.
- [x] Add failing regression cases for current shared weekly threshold delivery, duplicate suppression, consecutive-sample jump detection, and enabled settings.
- [x] Include first observation, weekly rollover, account/credential changes, stale/missing weekly data, percentage decreases and top-up-only changes. None may generate a false jump; weekly rollover re-arms thresholds.
- [x] Restore existing alert preferences, warning/critical thresholds, jump intensity/style and notification permission behavior with explicit weekly wording. Do not derive weekly jumps from wallet ratios.
- [x] Render the transient jump glyph while retaining shared numeric text and restoring the latest shared ring state afterward.
- [x] Verify focused regression and independent specification review, then quality review. Commit `201465a`; full regression 1,262 tests / zero failures. Native installation and final external reviews remain separate acceptance steps.

## Task 2: Resolve history-dependent capabilities from evidence

**Files:** a focused shared-activity API/model/controller, `UsageViewModel.swift`, `WeeklyUsageModels.swift`, `WeeklyUsageChartView.swift`, `MenuBarView.swift`, `SettingsAppearanceTabViewController.swift`, `SettingsUsageTabViewController.swift`, `CursorMeterApp.swift`, shared activity/refresh/UI tests, `docs/API_REFERENCE.md`.

- [x] Inspect installed official endpoint schemas and read the documented existing-auth candidate without inference or billing mutation.
- [x] Establish current multi-product event and daily-summary reads using the official unified activity path.
- [x] Select failing tests for precise USD/ISO parsing, unavailable/malformed fields, token counts, recent rows, history failures, owner changes, partial pagination and UTC day labels before implementation.
- [x] Load recent events independently of daily aggregates and monthly reset, bound each to the same verified owner, and prevent late responses from republishing after a session change. Use independent stale states; an activity failure must not invalidate primary authentication or healthy meters.
- [x] Restore Recent usage and its time-zone control using current events. Preserve product/model context without exporting principal identifiers; distinguish usage, grants and adjustments. Never relabel `usageType:credits` as purchased credit.
- [x] Restore the seven-day chart and Today bar-style control with USD contracted cost and token metrics. Keep the existing layout and persisted legacy metric preference; map the shared alternate metric to tokens rather than weighted usage units. Sum only the server-ranked series for the selected metric plus `other`, and label UTC bucket semantics.
- [x] Display the server's independent monthly `resetsAt`; never substitute weekly or subscription cycle dates. Correct eligible prepaid responses with omitted Auto Top-up to Off based on the official Cursor mapping; malformed/failed/ineligible data remains unavailable.
- [x] Keep fixed ring meanings and unsupported monthly dollar estimates unchanged. Daily chart Today emphasis is supported; a Today percentage overlay on the shared allowance is not derivable and must not be invented.

## Task 3: Review and deliver

- [x] Run focused and full `swift test`, release build and diff checks. Full regression: 1,287 tests, zero failures; post-capture presentation checks: 21 tests, zero failures. Release build passed.
- [ ] Complete independent specification and Argon High / Grok XHigh reviews of the material candidate; report static review separately from executed tests.
- [ ] Package after refreshing the remote baseline, retain existing signing choice, back up the installed app/settings and replace the local app.
- [ ] Verify enabled controls and source/rendered values with native AX paths; do not trigger real threshold notifications or spend on inference merely to test.
- [ ] Update issue #148 with sanitized evidence and exact remaining limitations. Do not close or release as part of this work.
