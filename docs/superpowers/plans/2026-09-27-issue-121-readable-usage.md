# Issue 121: Readable usage values and copy

## Scope

Use exactly one decimal (including trailing zeroes) for split-pool percentages and percentage-point jump text.
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
- [x] Apply the fixed-decimal follow-up and verify the live native interface.
- [x] Stop owned caffeine after the subsequently requested whole-branch review finishes.

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
- At the initial `755eb69` checkpoint, live account UI verification waited for the
  owner to handle macOS Keychain confirmation. The owner subsequently handled it;
  completed live verification of `dfc0694` is recorded below. The security dialog
  was not automated.

## Fixed-decimal follow-up

The owner requested consistent decimal positions: `29.0%` and `23.1%`, including
trailing zeroes. Split-pool values and percentage-point increases now use exactly
one decimal. Tiny positive values remain `<0.1%`; quota boundaries use
`<100.0%` / `>100.0%`. Raw calculations and legacy integer presentation stay intact.
The owner handled the first updated bundle's Keychain prompt; live startup resumed.

The owner also reported text against the Recent list edge. Add an internal leading
inset to model/time rows while preserving existing column widths, amount alignment,
scrolling and the fixed viewport. Check both scrollbar styles and refresh the native
Recent capture alongside the percentage captures.

Hover lines omit the parenthesized outer/center labels at the owner's request.
Pool identity and saved order remain; settings still explains ring placement.

Follow-up verification: fixed-decimal table failed before implementation (9 assertions),
then all 876 tests passed. The existing Recent layout test checks model/time inset,
legacy/overlay scrollers and a $1234.57 amount fitting the viewport. Independent
review found and resolved two accidentally changed legacy expectations; a remaining
AX selector was updated after removal of position labels. Native dark/light captures
and the expanded HTML comparison were inspected; documented screenshots refreshed.

Final follow-up source `dfc0694` passed [ARM/Intel CI](https://github.com/WoojinAhn/CursorMeter/actions/runs/36324057613).
Release packaging and installed/source checksum plus strict signature verification
passed. Live menu-bar help/AX showed one fixed decimal and no positional parentheses;
Display preview matched. The real Recent window was visually inspected with the
new model/time inset and visible right-aligned amounts. No private capture is committed.
The owner then requested a fresh whole-branch Muse/Grok/Opus review before further
delivery. That round's findings, Muse failures and validated corrections are recorded
in [the whole-branch review](../reviews/2026-09-27-issue-121-full-branch.md). The owned
caffeine assertion was released and its process exit verified at the 2026-09-28 handoff.
