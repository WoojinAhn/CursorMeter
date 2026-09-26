# Issue 121 Usability Review Record

## Gate A

- Muse: job-muicfk8d-auux, muse-spark-1.3-max, FAILED with CLI exit code 1 and no findings. This is not a successful review. No retry or substitution. The separately planned code-and-spec integration review will still use this exact model.
- Grok: job-muicftqr-g92m, grok-4.7-xhigh, completed. Five contract-clarity findings.
- Opus: job-muicg2fd-uijj, claude-opus-5-5-max, completed after the observation deadline. Six specification/integration blockers reviewed below.

### Grok dispositions

1. Threshold migration: clarify eager one-time materialization in view model; preserve
   pure engine fallback for compatibility. Reject lazy fallback recommendation because
   unrelated later shared edits must not alter untouched migrated scope preferences.
   Accept separate scope/shared setters and effective-policy cancellation comparison.
2. Copy consistency: update old spec prose as well as section 9. English matches the
   existing app and accepted mock; reject retaining the superseded Korean-only branch
   wording. Keep actual threshold/current value and high-water meaning.
3. Estimate gating: accept all existing validity checks plus opt-in, whole-dollar limit
   formatting, and suppression of estimate-only statuses while disabled.
4. Capability: accept no invented dollar data for request/percent-only/checking states.
   Do not prohibit the requested mode selection on legacy monetary data; real server
   limits do not depend on estimate opt-in. Team split eligibility remains unchanged.
5. Help/controls: transient accessible NSPopover, persisted first-show acknowledgement,
   existing segments and dual-thumb gauge. Escape/Close restores info-button focus;
   outside-click focus follows the destination instead of stealing focus back.

The baseline 841 tests passed before the new intentional RED preference contract test.
No feature code was implemented before Gate A reconciliation.

Implementation proceeded after Grok dispositions with the review limitations explicitly
reported to the user. No claim of three-model Gate A approval is made.

## Gate B

- Muse: job-muidb8kd-1iwl, muse-spark-1.3-max, failed with CLI exit code 1 and no findings; separate planned code review, not a retry of Gate A.
- Alerts integration: 48 tests, zero failures (`/tmp/121-alerts-integrated.log`).

### Late Opus Gate A dispositions

1. Accepted missing manual collection recovery: shared user refresh now retries only
   a cycle-budget stop, preserving cooldown/429 and all collector admission guards.
   Controller regression test covers stopped recovery versus unchanged complete data.
2. Migration ambiguity: already resolved to eager copy, scoped plist dictionaries,
   pair normalization and explicit preference restoration. Lazy alternative declined.
3. Legacy ambiguity: monetary modes supported with real limits; nonmonetary accounts
   retain units. Legacy alerts use shared setters, split controls hide when irrelevant.
4. Attribution ambiguity: preserve existing safe pool-cost gates, not the suggested
   display of unresolved provisional subtotals. Included total remains independent.
5. Pro kinds: explicitly unverified; no guessed allowlist entries or claim of complete
   monetary compatibility. Capability-eligible percentage and alert behavior retained.
6. Shared APIs/ownership: root supplied VM and observation plumbing; workers had separate
   tests and source ownership. All integrated code compiled; 864 tests initially passed.

Additional fixes: pool-label clipping caught by inspected native rendering and width
assertions; Alerts viewport bounds for short screens; scope-specific accessibility
thumb names; notification permission rechecked when returning to visible Settings.

Gate B Opus: job-muiddqcp-j7oc; Grok: job-muidekid-euh1. Both completed at the requested levels; dispositions below.

## Integrated validation (before final external findings)

- Initial integrated Swift suite: 866 tests, zero failures. The final log was subsequently replaced by the 871-test run after late findings.
- Installer/script suite: 12 tests, OK (`.Codex/usability-script-tests.log`).
- Release build: succeeded (`.Codex/usability-release-build.log`).
- Native AppKit render inspected in light/dark: 112pt dual meter, all three readout
  modes, optional limits, Display, Alerts, Recent, and information-popover content.
- Pool-label width and Recent USD-column clipping were reproduced with failing
  geometric assertions and corrected; repeat native captures show full text.
- HTML mock: nine Playwright checks for segments and help behavior passed.
- Synthetic data only; installed app was not stopped or replaced. Native window
  chrome/actual menu-bar interaction and real outside-click dismissal remain manual.
- Source-kind support on other plans remains capability- and observation-dependent;
  this work adds no universal Ultra/Pro dollar entitlement.

### Native capture references

- [Popover](../../screenshots/popover-weekly.png)
- [Dollar mode](../../screenshots/popover-dollars.png)
- [Estimated limits enabled](../../screenshots/popover-estimated.png)
- [Display](../../screenshots/settings-display.png)
- [Alerts](../../screenshots/settings-alerts.png)
- [Recent](../../screenshots/settings-usage.png)
- [Estimate help](../../screenshots/estimated-limits-help.png)


### Gate B dispositions

- Grok completed with five findings. Removed the scheduler-pause presentation flag;
  capability-checking presentation now suppresses unverified cost/estimate statuses.
  Active on-demand legacy data retains the requested monetary modes and now exposes
  the matching Display control (rather than silently disabling the saved mode).
- Accepted mixed blank catalog normalization: retain nonempty server names, treat an
  empty filtered list as missing. RED showed five attribution/limit assertions failing;
  collector plus supplement suites passed 43 tests after correction.
- Declined the help-acknowledgement finding: the integrated contract explicitly counts
  any successful prior info display, avoiding redundant first-enable help. Failed
  presentation never consumes acknowledgement. Explicit info remains available.
- Independent native code review caught a supplement/manual-retry race. Retry now
  awaits the existing supplement and rechecks task ownership before collection.
  Generation/account/reset/sleep/cancellation/429/coalesced-click cases covered;
  controller suite passed 27 tests. The paid-mode regression also reproduced RED.
- Muse Gate B failed with CLI exit code 1 and no findings after its observation deadline.
  This is not review approval. No retry or model substitution was performed.
- Opus Gate B completed late; its accepted fixes are recorded below.


### Late Opus Gate B dispositions

Opus completed with no blocking regression, one Medium and several Low findings.
Accepted partial/unreconciled Bot suppression; cost statuses now use one precedence-
selected line and name cost refresh failures explicitly. Hidden pool costs no longer
produce an old-cost qualifier, and estimate-not-ready does not stack with an error.
Legacy monetary capability is shared by Settings and Popover and requires a valid
paid denominator when on-demand is active. Baseline menu-text settings remain visible
without data. The info button explicitly uses image-only positioning. Alerts uses an
equality guard for preferred size and hides the legacy gauge during split checking.
The enlarged meter is decorative to accessibility, while each named pool is one spoken
static element with no repeated child readout. Removed orphan Summary VM wrappers.

Declined copy-only renaming of On-demand: jump messages describe spending, while
threshold cards describe its budget; changing every scope title would confuse the
meaning. Nested card chrome was initially left unchanged after screenshot inspection; Gate C
confirmed two coincident translucent backgrounds in source, so the inner card was
replaced by a plain stack.

## Gate C: frozen-code final reviews

Base: 93db9f1..7dd3d66. Subsequent late Gate B fixes are recorded above and validated
separately; a review of this base is not a claim to have inspected a newer commit.

- Muse: job-muie4or4-x7in, muse-spark-1.3-max, completed; reported Muse Spark 1.3 300K Max. No remaining concrete bugs. The reviewer also checked df4a0ff fixes. Its quoted 870-test figure came from the review prompt; the separately verified final local run is 871 tests.
- Grok: job-muie4qfs-935b, grok-4.7-xhigh, completed; reported Grok 4.7 256K Extra High. No findings in the scoped final contracts.
- Opus: job-muie575k-re5i, claude-opus-5-5-max, completed; reported Claude Opus 5.5 300K Max. Also reviewed df4a0ff. One low visual finding: nested Menu Bar card background, corrected and recaptured.

## Final local verification

- HEAD df4a0ff: `swift test` passed 871 tests with zero failures (`.Codex/usability-final-tests.log`).
- Final dark native fixture capture passed and was visually inspected; synthetic names only.
- One cost-status line, partial Bot suppression, monetary-capability parity and nonduplicated pool accessibility are included in this revision.
- Release package and strict ad-hoc verification passed for df4a0ff (`.Codex/usability-final-package.log`); separate dev bundle, installed app untouched.

### CI environment regression

Run 36244065397 failed on ARM and Intel: the Recent USD column ended at 382pt
while the legacy scrollbar reduced the viewport to 367pt. Explicit legacy-scroller
testing reproduced the same issue locally (365pt on the local SDK). The table now
sizes to its actual clip-view width during layout; existing first-column-only
autosizing preserves the token and USD columns. The new test switches legacy →
overlay → legacy without overriding the user's OS preference.

- RED: `.Codex/usability-scroller-red.log`.
- Focused GREEN: 13 Recent tests, zero failures.
- Full GREEN after scrollbar and card fixes: 872 tests, zero failures.

The first viewport fix at d90a93c still failed the original test on both CI runners
(run 36244393957), despite the explicit-style test passing. Controller-level layout
was therefore insufficient; the final correction must follow the scroll view's actual
viewport layout rather than weakening the visibility assertion.

The original borderless-window test now explicitly selects legacy scrollers before
attachment and reproduced RED locally (382 > 365). The final fix moves fitting to
`RecentUsageScrollView.tile()` after `super.tile()` resolves the viewport. It skips
unchanged widths and retains OS preferences and fixed numeric columns. Both focused
13-test and full 872-test suites pass; independent code review found no further issues.
