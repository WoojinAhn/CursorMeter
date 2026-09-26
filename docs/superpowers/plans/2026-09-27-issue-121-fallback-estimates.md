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
- [x] ARM/Intel CI passed for 8b607a5: run 36257025760.
- [x] Packaged, strictly verified and replaced the authorized local app with 8b607a5-dirty; prior bundle backed up.
- [x] Owner completed the macOS Keychain prompt; native popover accessibility shows both inferred limits with the saved dollar mode and estimate opt-in.
- [x] Delivery checks complete; release task-owned caffeine at the end of the response.

## Evidence

- Regression RED: `.Codex/estimate-fallback-red.log` (2 tests, 16 assertions).
- Collector/presentation GREEN: `.Codex/estimate-fallback-green.log` (43 tests).
- Cache restart GREEN: `.Codex/estimate-restart-cache-test.log` (1 test).
- Full GREEN: `.Codex/estimate-fallback-full-tests.log` (873 tests).
- Independent review found no issues; retired catalog-required test expectations updated.

## Native verification boundary

The installed process starts but is waiting inside `SecItemCopyMatching` for Keychain
authorization. Computer Use refuses access to SecurityAgent; the owner was asked to
handle the system prompt directly. No credential or Keychain access policy was changed,
and live estimated-limit display was not marked verified while startup waited.

After the owner confirmed authorization, the fresh disk snapshot contained both
estimated limits and the native popover exposed both amounts with `~` denominators.
The saved display mode and opt-in preference were unchanged. Actual account values
and identity are deliberately excluded from repository evidence.
