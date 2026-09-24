# Usage Density Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** Apply the approved compact Usage layout from `docs/mockup-120.html` for #120.

**Architecture:** Keep the existing AppKit table, refresh coordinator, and cache. Remove the reserved status row and represent cached failures beside their original timestamp; initial failures use the existing empty-state detail.

**Tech Stack:** Swift 6, AppKit, XCTest; no new dependencies.

## Approved design

- Width 440 pt; rows 44 pt; fixed 264 pt viewport showing six rows; up to 30 requests unchanged.
- Remove the 32 pt status host, including redundant Updating and saved-data text. Expected native window height is approximately 548 pt, subject to native measurement.
- Keep timestamp and timezone. Cached failure appends ` · Update failed`; retain this hint until retry/success as appropriate without changing window height. Updating is communicated only by the refresh button.
- Initial failure uses `Unable to load recent usage.` and `Try again later.`. Preserve loading, empty, and disconnected placeholders.
- Model lines truncate with tooltip and full accessibility value. Keep tokens and amount columns readable. Preserve scroll position during feedback changes.
- Keep all networking, 30-row cap, local caching, timezone semantics, 1.3-second minimum feedback, and shared 3-second cooldown unchanged.

### Task 1: Update existing state and layout tests, then implementation

**Files:** `Tests/CursorMeterTests/RecentUsageUITests.swift`, `Sources/CursorMeter/SettingsUsageTabViewController.swift`.

- [x] Change existing layout assertions to `rowHeight == 44`, `scroll.frame.height == 264`, and `view.fittingSize.width == 440`.
- [x] Change cached-failure assertions to original cache text plus ` · Update failed`; verify rows and original timestamp survive, and no standalone Updating text appears. Verify the button reports Updating and remains disabled during an active attempt.
- [x] Change initial-failure detail assertion to `Try again later.`; continue checking that unknown count/time is not fabricated.
- [x] Run `python3 .Codex/bin/test-swift.py --filter RecentUsageUITests`; record expected failures before changing source. This private compatibility mirror alters only the copied application entrypoint for local Xcode compatibility; CI tests original source.
- [x] Set native geometry to 440/44/264, first column initial width 233, model top inset 7 and detail spacing 2. Delete statusLabel/statusHost and their update branch. Set `placeholderDetail.stringValue = "Try again later."` in the initial failure branch. Append the short cached error suffix only for cached failure, without duplicating button progress text. Keep normal timestamp styling and use a warning style for the suffix if it fits cleanly.
- [x] Rerun focused tests; then perform fresh spec compliance and code quality reviews. Resolve actionable findings and rerun affected checks.

### Task 2: Verify the native layout and update its screenshot

**Files:** `docs/screenshots/settings-usage.png`, this plan, `docs/mockup-120.html`.

- [x] Build the unmodified production source with CLT Swift 6.2.4 and SDK 26.2. Run the full compatibility-mirror suite.
- [x] Rebuild the existing synthetic native fixture from the changed production files. Capture and inspect dark/light current, cached-failure, and initial-failure states using accessibility paths. Measure 440 pt width, 44 pt rows and 264 pt viewport; verify header text fits and no status gap remains.
- [x] Inspect the synthetic Usage capture for personal data before replacing the published screenshot.
- [ ] Request focused Grok, Muse, and Opus Cursor reviews at this implementation checkpoint; resolve substantiated findings.
- [ ] Check diff scope and stale UI strings. Commit the code/tests/mock/asset/plan with issue #120 and Codex attribution after reviews.

### Task 3: Integrate and verify the installed application

- [ ] Fetch origin; fast-forward local main without losing unrelated local files; push main and feature branch.
- [ ] Wait for the exact commit's macOS ARM and Intel CI jobs (Swift and installer tests).
- [ ] Package a clean normal development app, back up the current installed bundle, install it, and verify the actual Usage window via accessibility. Keep real account data private.
- [ ] Record the installed commit and verification evidence. Close #120 and list remaining open issues.
- [ ] Release only the caffeine assertion owned by this task and mark its private runtime record inactive.

Post-commit integration and installation completion is tracked in issue #120.

## Verification record

- Focused local compatibility-mirror run: 12 tests; 9 expected failures before implementation, 0 after it.
- Full local compatibility-mirror run: 642 tests, 0 failures. The original source also builds with CLT Swift 6.2.4; CI remains the original-source test gate.
- Native synthetic fixture captures: light/dark current, light/dark cached failure, initial failure, updating, and empty. Accessibility measured 440 × 548 pt in every case.
- Header spacing is 6 pt; numeric time zones GMT+12:45/GMT-09:30 fit with the cached-failure suffix. No separate progress/status row remains.
- Published screenshot uses synthetic entries. The normal installed app is verified separately after integration; operational completion is recorded on [issue #120](https://github.com/WoojinAhn/CursorMeter/issues/120).
- Additional native AX checks: GMT+12:45 cached failure survives the button reset; retry shows Updating without the old hint; successful recovery clears the hint and retains 30 rows.
- Review corrections: hide initial failure advice while retrying; match the approved light warning color (#956124); assert text/button separation and failed-retry completion. Focused red 12/3 -> green 12/0; full suite remains 642/0. Final native initial-retry and light/dark failure captures pass.
- Muse specification review and independent code-quality re-review pass. Opus findings 1–4 are addressed and re-reviewed independently; its targeted follow-up and the original Grok review remain in flight at this implementation checkpoint. Final model results are recorded in issue #120.
