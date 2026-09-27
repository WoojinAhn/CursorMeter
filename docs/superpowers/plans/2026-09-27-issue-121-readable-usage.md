# Issue 121: Readable usage values and copy

## Scope

Use at most one decimal for split-pool percentages and percentage-point jump text.
Keep small positive values and either side of 100 distinguishable, without rounding
stored measurements, circle geometry, thresholds, estimation or freshness comparison.
Existing whole-percent legacy presentation remains unchanged. Simplify new internal
state wording, notification labels and settings/help copy; preserve controls and actions.
Recent history says Updated with its original timestamp, not a new time after cache load.

## Tasks

- [x] Audit user-facing formatters and developer-oriented copy; fetch remote baseline.
- [x] Show before/after mock for the requested polish.
- [x] Add meaningful numeric boundary and raw-value regression tests; implement shared formatter.
- [x] Update settings/help/Recent wording in parallel, retaining user preferences.
- [x] Independent review, full tests, inspected native/HTML capture and ARM/Intel CI.
- [x] Package and apply the authorized local update.
- [ ] Complete live UI verification after the owner handles the macOS Keychain prompt; stop owned caffeine.

## Verification

- New boundary, raw-threshold and exact snapshot-matching regressions failed before
  implementation (3 tests, 20 assertion failures) and passed after it.
- Full `swift test`: 876 tests, 0 failures (2026-09-27).
- Independent code review found no blocking issue. Existing whole-percent legacy
  formatting is intentionally unchanged.
- Dark and light AppKit capture tests passed. Inspected fractional percentages,
  Display, Recent, estimate help and all documented popover modes; the refreshed
  screenshots contain only synthetic Demo User data.
- Playwright verified typical, small-positive and around-100% HTML scenarios;
  inspected full-page captures are retained locally under `output/playwright/`.
- Source/UI stale-copy sweep and `git diff --check` passed.
- [ARM and Intel CI passed](https://github.com/WoojinAhn/CursorMeter/actions/runs/36323114672)
  for source `755eb69`.
- Release packaging passed in 8.17 seconds; strict ad-hoc signature verification and
  installed/source SHA-256 comparison passed. Authorized local replacement preserved
  preferences and backed up the prior bundle. The new dev marker is `755eb69-dirty`;
  tracked build inputs match the source commit, with unrelated files preserved.
- Native synthetic captures verify presentation. Live account UI verification is
  currently waiting for the owner to handle the macOS Keychain confirmation. Process
  sampling confirmed startup waits in `KeychainStore.loadCookieHeader` /
  `SecItemCopyMatching`; the security dialog is not automated.
