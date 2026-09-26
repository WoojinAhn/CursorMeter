# Issue 121: Estimate opt-in with fallback classification

## Problem

An enabled Show estimated limits preference has no effect when the server model catalog
is unavailable, even though version-2 classification, complete history and reconciliation
already permit pool costs. The collector retains an extra catalog-presence gate.

## Scope

Remove that additional gate; keep valid server membership precedence, bounded Cursor
corrections, Other remainder and separate Bot/paid activity. Preserve all source,
coverage, reconciliation, precision, spillover and presentation opt-in checks. No fixed
plan limits, cache deletion, preference changes or new diagnostic UI.

## Verification and delivery

- [x] Reproduce missing/empty/blank/failed/incoherent catalog inference failure before the fix.
- [x] Remove the extra collector condition and update the authoritative specification.
- [x] Verify cached nil limits are replaced on the first collection after restart.
- [x] Independent code review and full local tests: 873 tests, zero failures.
- [ ] ARM/Intel CI for the committed fix.
- [ ] Package and replace the authorized local app; verify estimated limits in the actual UI.
- [ ] Stop task-owned caffeine after delivery.

## Evidence

- Regression RED: `.Codex/estimate-fallback-red.log` (2 tests, 16 assertions).
- Collector/presentation GREEN: `.Codex/estimate-fallback-green.log` (43 tests).
- Cache restart GREEN: `.Codex/estimate-restart-cache-test.log` (1 test).
- Full GREEN: `.Codex/estimate-fallback-full-tests.log` (873 tests).
- Independent review found no issues; retired catalog-required test expectations updated.
