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
| Opus | `claude-opus-5-5-max` | `job-mujvwho0-6jxy` | Running |

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

Opus is pending. Muse did not return a review; its failed run is not a pass.
The owner has been asked whether to retry the same Muse configuration; no automatic
retry or model substitution has been started.

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
