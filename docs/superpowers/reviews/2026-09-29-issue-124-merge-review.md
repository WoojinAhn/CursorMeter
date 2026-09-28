# Split usage and notification UX merge review

Date: 2026-09-29. Issues: #121 and #124. Pull requests: #122 and #125.

The owner authorized main integration after notification cleanup and four
flagship-model reviews. The code baseline was `c0225f7b92dba99ab78bfedf8e0ef7bdc70de1e5`.
All four reviewed the same frozen candidate, `e8c8462c026a26202faa78b3d8cf680d15338ba5`,
which includes parent split-usage head `5477ddbd8e039fcc53877ede9fc36dfd4d96c44a`.
These are source/test reviews, not native macOS visual verification.

## Independent Cursor review outcomes

| Requested configuration | Reported model | Outcome |
|---|---|---|
| `claude-fable-5-1-thinking-max` | Claude Fable 5.1 300K Max | No P0/P1/P2; accepted attribution, specification and orphan-code refinements. |
| `grok-4.7-xhigh` | Grok 4.7 256K Extra High | No P0/P1; one reproduced P2 in authorization-wait coalescing, corrected below. |
| `gemini-3.1-pro` | Gemini 3.1 Pro | No P0/P1/P2; native stacking and retained view-model event noted as limitations. |
| `muse-spark-1.3-max` | Muse Spark 1.3 300K Max | No P0/P1/P2; native/system behavior and preserved legacy policies noted. |

Every job completed. Expiry of a worker's 15-minute observation window did not
mean its detached Cursor job failed: results were retrieved from the same jobs,
without restarting inference. This successful Muse review is distinct from the
historical failed Muse attempts recorded during #121. Model conclusions are
review evidence, not proof that every execution or OS layout is covered.

## Accepted corrections

1. **Keep a newer threshold and Bold together.** With warning 50 and critical
   100, Cursor 40→55 opens authorization; 55→70 arrives before permission is
   granted. The old active batch previously consumed the 70% warning, causing
   the matching 55→70 increase to arrive in a second banner. A queued batch now
   uses only its own observation revision's threshold. The latest batch sends
   exactly one 70% warning with 55→70, and the old increase is retired.
   Same-revision value replacement, critical promotion, policy cancellation,
   original occurrence-time expiry and successful-submission acknowledgement
   remain covered.
2. **Keep value attribution explicit.** A same-scope increase omits its label
   only when the sole preceding body row describes that title's alert level.
   After another threshold or increase, it names its scope. Both ambiguous
   permutations have regression tests; the simple two-row case stays concise.
3. **Keep specifications consistent.** The #121 retention section explicitly
   defers to #124 when a newer undelivered threshold replaces an older Bold.
   Already-delivered thresholds do not erase otherwise valid pending increases.
4. **Remove the obsolete notification decision from the icon coordinator.**
   Its helper returns only icon eligibility. All nine intensity/tier combinations
   remain covered; actual Bold gates stay in the refresh/split pipelines.

Grok resumed the same review session on the frozen corrective diff, now committed
as `30ead793421db31e38dd7356e61c856e92e1819d`, and confirmed the P2 resolved with no
new correction-induced defect. It also checked explicit scope labels and the
unchanged production Bold gates.
An independent focused code review found no additional P0/P1/P2 in the correction.
The source/test diff from `e8c8462` had SHA-256
`37253479d3ac009a31850806e1637a040772a132b448369d54d87c06eeedf158`;
its contents stayed unchanged during follow-up review and validation.

## Validation

- The authorization-wait regression failed before correction with two payloads.
- Both scope-attribution regressions failed before correction.
- Corrective dispatcher/composer/coordinator suites: **65 tests, 0 failures**.
- Final full Swift suite: **926 tests, 0 failures**.
- Installer suite: **12 tests, OK**; installer source did not change afterward.
- Final release build: **Build complete**.
- The original candidate passed [ARM/Intel CI](https://github.com/WoojinAhn/CursorMeter/actions/runs/36439801651).
  Corrected-head and final main CI are checked during integration and linked in
  the PR/issue completion records.

Earlier implementation regressions also reproduced actual-versus-configured
legacy percentages, mixed-revision split copy and blocked refresh during a
Bold-only authorization wait. The final code preserves independent settings,
immutable captured values, split ownership leases, bounded pending work and
per-signal eligibility. Legacy acknowledgement and continuity policies remain
explicitly outside the new split-ledger contract.

## Delivery and limits

The [notification specification](../specs/2026-09-28-notification-ux-design.md)
is versioned. New HTML mockups, screenshots and raw review transcripts remain
local. No private account values or credentials are included in this report.

No new installed-app replacement, signing/Keychain change, tag or release is part
of this merge. Native banner wrapping, Notification Center stacking, VoiceOver,
real permission prompts and sleep/disk behavior are not established by payload
tests or the local HTML. Once an OS submission has begun, a subsequent observation
can legitimately produce a separate notification; the coalescing correction
covers work still waiting for authorization. Stable development signing remains
separate in #123.
