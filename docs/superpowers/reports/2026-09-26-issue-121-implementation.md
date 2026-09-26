# CursorMeter split usage implementation report

**Status: development, requested review checkpoints and automated validation complete. Native installation and live verification remain the owner’s next-morning handoff.**

CursorMeter now represents Cursor Models and Other Models independently in its menu bar, hover details, popover, settings and alerts. The legacy included-dollar limit no longer defines a combined split-plan percentage. Dollar activity is retained with source time, coverage and conditional estimates. Included-dollar jump messages remain aggregate; per-pool dollar attribution for individual polling intervals is deferred.

- Branch: `feature/121-split-usage`
- Issue: [#121](https://github.com/WoojinAhn/CursorMeter/issues/121)
- Draft PR: [#122](https://github.com/WoojinAhn/CursorMeter/pull/122)
- Contract: [design](../specs/2026-09-26-issue-121-split-usage-design.md), [source evidence](../specs/2026-09-26-issue-121-source-contract.md)

## Behavior

The default C icon puts Other Models in the outer ring and Cursor Models in the center. Placement is configurable without changing identity, thresholds or notification history. Split usage remains icon-only, preserving the saved single-pool text preference for legacy plans. Both percentages, unavailable/stale state and dated amount details are available on native hover and through the popover.

The amount collector is independent of the primary refresh. It uses exact Decimal cents, bounded traversal, source rechecks and included-total reconciliation. Model-family attribution stays provisional. Unknown data, ambiguous history, spillover and insufficient percentage precision prevent confident limit estimates. Bot activity and paid history stay separate; no fixed Ultra multiplier or $400 replacement is introduced. Coherent period-only percentages retain their own source time and are display-only; threshold/jump events use primary summary measurements.

Both emoji pairs and Quiet/Normal/Bold remain. Split jumps retain $0.05/$0.30 sensitivity alongside +5/+15 percentage points. Bold and threshold settings remain independent, while a single dispatcher combines eligible events. Repeated values, corrections, wake/recovery, late enrichment and account changes do not become repeated consumption notifications.

Display, Alerts and Usage settings now expose placement, individual targets and Summary/Recent views. Recent 30, time zone, polling, activity refresh, weekly chart, authentication and General settings retain their existing paths. A split summary failure keeps the previous dated split snapshot instead of silently reverting to a monetary-ratio meter.

## Review checkpoints

| Checkpoint | Muse | Grok | Opus | Disposition |
| --- | --- | --- | --- | --- |
| A: specification | Complete | Complete | Complete | Material findings resolved before parallel development |
| B: core implementation | Complete | Complete | Complete | Material findings resolved; 820 tests passed |
| C: integrated branch | Complete | Complete | Complete | Six confirmed defects corrected across integrated and focused passes; final Grok confirmation passed |

Exact requested configurations: `muse-spark-1.3-max` (Muse Spark 1.3 300K Max), `grok-4.7-xhigh` (Grok 4.7 256K Extra High), and `claude-opus-5-5-max` (Claude Opus 5.5 300K Max). Review dispositions and job references are retained in [the review record](../reviews/2026-09-26-issue-121.md). The final two retry corrections received a targeted continuation of the originating Grok review at `9287e0a`, with no remaining material finding. No AI review is treated as a substitute for the owner’s live native checks.

## Validation

- Baseline after the separate Swift 6.4 entry-point compatibility fix: 642 existing tests passed; initial draft-PR ARM and Intel CI passed.
- Combined core checkpoint: 753 tests passed; debug build passed.
- After all review and CI corrections: `swift test` — **838 tests, 0 failures** (11.519 seconds), with no compiler warnings.
- CI exposed a formatter compatibility issue and Display overflow on a small screen. The corrected Display scrolls within available space; a 681 pt screen fixture verifies top/bottom access and dynamic visibility. Both ARM/Intel passed [run 36174991247](https://github.com/WoojinAhn/CursorMeter/actions/runs/36174991247) for `24335fb`. Both architectures also passed [final code run 36177344104](https://github.com/WoojinAhn/CursorMeter/actions/runs/36177344104) for `9287e0a`.
- `swift build` passed (0.23 seconds); the final dev bundle release build passed (9.15 seconds), followed by strict ad-hoc signature verification.
- Installer checks: **12 tests, OK** (9.787 seconds). Compiler: Apple Swift 6.4.
- Synthetic offscreen AppKit fixtures covered Display, Alerts, Summary and the split popover, including missing values, placement, partial cached details, bounded scrolling and reset dates. Additional Summary captures verify automatic-pause and sleeping captions fit at 440 × 498 pt with the correct retry-button state.
- README and SECURITY English/Korean pairs have matching heading structure.

These are automated/offscreen results. The running application, installed bundle and native preferences were not deliberately changed for live verification. Real hover timing, system notification delivery, VoiceOver, display scale and installation remain the owner's checks. Existing repository screenshots are explicitly identified as the single-pool interface until native captures are refreshed.

Gate C corrections cover delayed coherent period values across equal revisions, cancellation before system sleep, rejection of unreconciled source-end history, request-scope adoption before split publication, instability retained when a reconciliation retry exhausts its budget, and a hard-limit pause preserved across cancelled/failed manual attempts. Each confirmed defect has a failing reproducer and passing regression coverage.

## Development bundle

The local arm64 candidate is `output/issue121-dev-9287e0a/CursorMeter.app`.
It is version `0.1.0`, with Settings marker **`9287e0a-dirty`** and automatic release
checks disabled. The marker's dirty suffix comes from preserved unrelated local
files; all tracked app build inputs matched source commit
`9287e0a461850012948bfb709229dcc84cef3b32`. It was neither installed nor launched.
Later documentation-only commits do not change this binary.

Executable SHA-256: `603ec87e455739ade5e6d84be5fa3c5353c80af99f9ce11f5feea3694e81d9fc`.
The sibling `build-provenance.json` records source, build time and validation links.
Earlier candidate directories are superseded by this one.

## Manual handoff and limits

Follow [the native verification checklist](../plans/2026-09-26-issue-121-manual-verification.md). It covers percentages against the same-cycle dashboard, both emoji styles, ordinary dollar-sensitive Bold, target independence, disabled/no-cap paid spending, placement, wake/reconnect, cached/partial states and legacy preference restoration.

Cursor endpoints remain undocumented. A stable traversal is evidence of consistency, not a server-side atomic snapshot guarantee. Model membership is not proof of the historical charged quota. Dollar estimates are conditional observations, not guaranteed subscription entitlements. Caches and ledgers are local and bounded; there is no device synchronization. This branch is not automatically merged or released.
