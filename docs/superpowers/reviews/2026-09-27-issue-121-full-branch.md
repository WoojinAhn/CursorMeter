# Issue 121: whole-branch review, 2026-09-27

## Scope

The owner requested another whole-branch review after the accumulated UI revisions,
followed by corrections and a push to the existing feature branch. No merge or release
is authorized. Review the complete committed diff from `origin/main` to
`dfc0694c9dd6b060f3aaff1d6c8b27136ab718ff`; exclude unrelated local files and private data.
The diff contains 26 production files (+3,114/-195 lines), 22 test files
(+4,396/-16), and 32 documentation/image files (including nine binary images).

## Review jobs

Each model receives the full branch scope and current design contract in an independent,
fresh, read-only Cursor session. Requested configurations match the earlier review.

| Model | Requested ID | Cursor job | Status |
| --- | --- | --- | --- |
| Muse | `muse-spark-1.3-max` | `job-mujvveu8-2t0u` | Failed: CLI exit code 1, no findings returned |
| Grok | `grok-4.7-xhigh` | `job-mujvvwz9-iwn5` | Completed; findings triaged below |
| Opus | `claude-opus-5-5-max` | `job-mujvwho0-6jxy` | Completed; findings triaged below |
| Muse retry | `muse-spark-1.3-max` | `job-mujzxojt-tea2` | Running; same configuration, explicitly authorized |

## Tasks

- [x] Fetch remote baseline and freeze review scope.
- [x] Dispatch all three independent reviews.
- [ ] Triage concrete findings against source and approved requirements.
- [ ] Correct confirmed defects with appropriate regression evidence.
- [ ] Complete validation and push changes to `feature/121-split-usage`; check CI.
- [ ] Summarize final findings and stop the owned caffeine assertion.

## Existing evidence

`dfc0694`: 876 local Swift tests pass; [ARM/Intel CI](https://github.com/WoojinAhn/CursorMeter/actions/runs/36324057613)
passes. Release packaging, strict ad-hoc signature and installed/source hash checks
pass. Synthetic dark/light renders and actual native help/Display/Recent were inspected
for fixed decimals, concise pool labels and row inset. The installed dev build is
`dfc0694-dirty`; tracked build inputs match this commit and unrelated files are preserved.

## Findings and disposition

The first Muse run did not return a review; its failed run is not a pass. The owner
explicitly authorized a fresh retry with the same Muse configuration on 2026-09-28.
The retry remains read-only and reviews pinned production source so concurrent fixes
do not change its review target.

### Grok: collection verification consumes the traversal budget

Not accepted as a defect. The approved collection contract counts verification and
retry pages inside the same 100-page / 10,000-event hard budget. It does not promise
completion for 10,000 unique events. A stable walk with 99 full data pages and one
head recheck uses 100 requests and exactly 10,000 fetched events. The report's claim
that this exceeds the event cap is an arithmetic error. A walk requiring an extra
empty termination page has one fewer data page available.

`CycleUsageCollector.page()` enforces that shared budget; the existing
`testInitialBudgetExhaustionStillReturnsGenuinePartial` verifies that a walk without
verification allowance remains partial. The design explicitly permits manual retry
to encounter the same limit again. Raising the cap or excluding verification requests
would change approved policy, so no code or budget change was made.

### Grok: early period percentages survive an unstable history attempt

Not accepted as a defect under the current display contract. A coherent period
measurement may be shown before history completes and retained for ten minutes under
the same primary fingerprint, account, scope and credential generation, with its
original timestamp. An end-period fingerprint change invalidates the cost aggregate;
it does not establish that the earlier coherent percentage was false. Model-catalog
changes alone can also produce this outcome.

`CycleUsageSupplementTests` and `SplitUsageControllerTests` cover early supplement
retention after history failure and primary evidence remaining unchanged. The report
also overstates retry blocking: two identical primary observations separated by the
required interval can permit collection during unstable backoff. Publishing a newer
coherent end-period measurement could improve freshness, but is a policy improvement,
not a demonstrated breach of the accepted retention contract. No blanket rollback was
added.

### Grok: source-contract appendix describes retired classification rules

Accepted documentation defect. The appendix still described version-1 unknown-provider
handling and treated an unavailable catalog as a blanket inference blocker. Updated it
to the approved version-2 Cursor evidence / nonblank Other remainder policy, retained
Bot and blank-model exceptions, and documented fallback eligibility plus its alias
misattribution risk. Coverage, reconciliation, precision and spillover checks still apply.
The main design's endpoint section had the same outdated restriction. It now describes
matching period failure signatures at both collection boundaries and eligible primary
summary percentages. `CycleUsageSupplementTests` already verifies successful collection
and estimation when both period calls return 401; no runtime behavior changed.

Coordinator documentation audit: the original implementation report still opened
with an unqualified not-yet-installed handoff status and described the superseded
Summary UI. Marked that report explicitly as a historical checkpoint and linked the
current design/verification records; retained its original evidence and candidate hashes.

### Opus: end-summary errors lose enrichment retry classification

Accepted and corrected. The production end-summary closure used
the primary `fetchUsageSummary` path, whose `APIError` bypassed the collector's typed
enrichment handling. A network or 5xx error therefore became `endpointFailure`
(30-minute backoff), and 429 lost shared server backoff and Retry-After information.
The primary authentication path is unchanged. A collection-only summary GET now uses
the existing enrichment HTTP handling. Regression validation uses the actual production
controller/API boundary, not only a manually injected typed error: network/503 waits
60 seconds initially; 429 preserves Retry-After (minimum 60 seconds, fallback 1,800)
and blocks both manual/automatic work; 400/401/403 preserve the primary snapshot and
use endpoint backoff. Cancellation remains cancellation.

### Opus: legacy and paid alert labels

Accepted legacy labeling defect: its hardcoded `Included usage` card can control
request-quota or on-demand percentages. The neutral `Usage` title preserves the existing
card and gauge and gives its accessibility labels the correct scope.

Paid naming is a copy consistency improvement, not a numeric defect. Keep `Paid budget`
for cap-based thresholds and `Paid spending` for recorded dollar increases. This retains
the useful difference between Settings' budget and the popover's spending, including
spending without a cap. Use sentence case `Included usage`; stored scope identifiers,
calculations and legacy `On-demand` notifications do not change.

### Opus: documentation and historical references

Accepted API reference drift: classifier version 2 uses the nonblank Other remainder,
and optional catalog absence alone does not prohibit estimates. Updated the reference.
The native checklist now links the current build record instead of directing the owner
to `efdf60c`, and expects concise period-enriched hover text without retired provenance
annotations. The spec status also points to current review evidence and accurately
records the later local-install authorization.

README request-count wording now distinguishes single-pool plans, and the existing
legacy menu-bar image is labeled as such in both English and Korean. Split screenshots
remain below it. `CLAUDE.md` is migration source material under repository policy, not
the authoritative instruction or current architecture reference; it was not rewritten
as part of this branch review.

Opus found no P0–P2 defect. Its additional continuity observations describe conservative
retirement of pending jump banners after continuity loss; no stale banner replay or
incorrect measurement was demonstrated. No lifecycle change was made. Native tooltip
timing, VoiceOver and notification delivery remain manual checks. The cited unknown CI
state is resolved by the linked successful `dfc0694` run and the later successful
documentation-only `14f923a` run; the draft PR triggers CI for branch pushes.

## Follow-up verification, 2026-09-28

- Production-path retry regression: 3 tests / 11 failed assertions before the fix;
  targeted API, collector, controller and schedule suite: 115 tests, 0 failures after it.
- Alert-label and existing behavior suite: 25 tests, 0 failures.
- Complete `swift test`: 882 tests, 0 failures in 11.463 seconds.
- `swift build -c release`: succeeded in 9.79 seconds; no compiler warnings in these logs.
- Independent code review of the corrective diff: no further findings.
- Synthetic native legacy Alerts rendered and visually inspected in light/dark;
  neutral Usage label and the existing dual-thumb gauge fit. The corresponding HTML
  single-plan mock was checked with Playwright and matches the one master-toggle path.
- Active API/spec/checklist stale-term sweep and `git diff --check` passed. README
  changes are paired in English/Korean with matching section counts.

The running installed app is still the previously verified `dfc0694-dirty` build.
These review fixes have not replaced it. Muse's retry remains pending; final review
completion and the caffeine release must not be inferred from passing local checks.
