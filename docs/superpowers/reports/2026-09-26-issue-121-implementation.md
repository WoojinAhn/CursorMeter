# CursorMeter split usage implementation report

**Status: checkpoint B resolved and implementation committed; final review and feature CI pending.**

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
| C: integrated branch | Pending | Pending | Pending | Pending |

Exact requested configurations: `muse-spark-1.3-max` (Muse Spark 1.3 300K Max), `grok-4.7-xhigh` (Grok 4.7 256K Extra High), and `claude-opus-5-5-max` (Claude Opus 5.5 300K Max). Review dispositions and job references are retained in [the review record](../reviews/2026-09-26-issue-121.md).

## Validation

- Baseline after the separate Swift 6.4 entry-point compatibility fix: 642 existing tests passed; initial draft-PR ARM and Intel CI passed.
- Combined core checkpoint: 753 tests passed; debug build passed.
- After Gate B and CI corrections: `swift test` — **820 tests, 0 failures** (11.396 seconds), with no compiler warnings.
- CI exposed a formatter compatibility issue and Display overflow on a small screen. The corrected Display scrolls within available space; a 681 pt screen fixture verifies top/bottom access and dynamic visibility. The replacement ARM/Intel run is pending.
- `swift build` passed (0.23 seconds); `swift build -c release` passed (12.53 seconds).
- Installer checks: **12 tests, OK** (9.787 seconds). Compiler: Apple Swift 6.4.
- Synthetic offscreen AppKit fixtures covered Display, Alerts, Summary and the split popover, including missing values, placement, partial cached details, bounded scrolling and reset dates.
- README and SECURITY English/Korean pairs have matching heading structure.

These are automated/offscreen results. The running application, installed bundle and native preferences were not deliberately changed for live verification. Real hover timing, system notification delivery, VoiceOver, display scale and installation remain the owner's checks. Existing repository screenshots are explicitly identified as the single-pool interface until native captures are refreshed.

## Manual handoff and limits

Follow [the native verification checklist](../plans/2026-09-26-issue-121-manual-verification.md). It covers percentages against the same-cycle dashboard, both emoji styles, ordinary dollar-sensitive Bold, target independence, disabled/no-cap paid spending, placement, wake/reconnect, cached/partial states and legacy preference restoration.

Cursor endpoints remain undocumented. A stable traversal is evidence of consistency, not a server-side atomic snapshot guarantee. Model membership is not proof of the historical charged quota. Dollar estimates are conditional observations, not guaranteed subscription entitlements. Caches and ledgers are local and bounded; there is no device synchronization. This branch is not automatically merged or released.
