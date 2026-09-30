# IDE profile 404 mitigation specification

Status: Frozen v0.4 for implementation. The v0.3 three-model spec gate is closed;
Grok and Opus approved the D2 unbound-owner clarification, with Astra consent.
Implementation and checkpoint reviews must follow this contract.
Date: 2026-09-30. Issue: [#128](https://github.com/WoojinAhn/CursorMeter/issues/128).
Baseline: `f71a1d374bfda929c3150b05fab843631b5fbb75` (`origin/main`).
Branch: `bugfix/128-ide-profile-404`.

## Goal and authority

Restore current usage from a successful usage-summary batch when the IDE profile
request returns exactly HTTP 404, without inventing authenticated identity or
weakening account isolation. This is mitigation; the upstream 404 may remain.

The owner's 2026-09-30 implementation instruction takes precedence over the issue's
broader legacy-only acceptance: **usage-summary success is mandatory**. A successful
`/api/usage` alone does not qualify. Do not silently implement that broader path.
This narrowing is an explicit owner instruction, not a new coordinator assumption.

Review and execution checkpoints: (1) this spec, (2) implemented ownership/gating
and focused tests, (3) final integrated diff and full validation. At each checkpoint
use the live-roster variants of the same Grok, Muse, and Opus families and report
actual requested/reported IDs. The present exact keys are `grok-4.7-xhigh`,
`muse-spark-1.3-max`, and `claude-opus-5-5-max` (non-Fast).

The owner clarified that **Boss means Astra, the coordinator of this session**.
Every spec amendment requires explicit agreement from at least two review models
AND Astra. No external Boss approval is sought. Without both conditions, do not
change the spec or expand scope; present the proposal and evidence and stop the
dependent work. Reviewer suggestions alone do not authorize changes. Keep each
reviewed revision and its hash. The owner's non-goals remain binding.

## Scope and non-goals

In scope: the IDE credential/batch profile decision, exact-credential account
ownership during degraded refreshes, successful usage presentation, identity-
dependent feature isolation, persistence/notification transition correctness,
critical regression tests, and documentation matching those behaviors.

Out of scope: issue #127 (including edits, probes or experiments), GetMe requests
or integration, cookie-prefix rewrites, blanket identity migration, JWT signature
infrastructure, additional IDE database keys, refresh-token handling, live account
or Keychain reads, application replacement, merge, release, and unrelated UI work.
Do not copy PR #114's broad authentication fallback or cached IDE profile reads.
Do not change the working browser path or add 404 fallthrough to a saved account.

## D1. Exact gate and precedence

Evaluate outcomes from the same structured refresh batch after the existing
unauthorized sweep and current-generation/credential-context checks:

| Credential / profile / summary | Behavior |
|---|---|
| IDE / exact HTTP 404 / successfully decoded usable summary | Apply successful identity-independent usage through degraded-profile mode. |
| IDE / exact HTTP 404 / missing, failed, malformed or unusable summary | Retain profile-error behavior, even if legacy usage succeeded. |
| Browser / HTTP 404 | Existing error behavior. |
| Either source / profile 401, 204/empty, 403, 429, 5xx, transport or decode failure | Existing unauthorized or failure behavior; never use the new 404 exception. |
| Any primary response is unauthorized | Existing credential fallback/expiry handling takes precedence over the exception. |
| Profile success | Existing healthy behavior, with necessary ownership bookkeeping only. |

Success is not merely status 200: an empty decoded `{}` must not unlock fabricated
zero usage. A decoded summary qualifies through one of these existing representations:

1. `SplitUsageEligibility.evaluate` returns `.eligible` using the same-batch legacy
   response and the **effective enterprise scope this batch actually passes to
   `SplitUsageController.accept`**. Compute scope under existing policy, accounting
   for a pending D2 retirement or existing plan-scope reset; do not mutate owned
   state merely to evaluate eligibility. `.checking` alone does not qualify.
   This branch permits missing `plan.used`; zero family percent is valid. If only
   this branch qualifies, render split percentages, keep missing included amounts
   unavailable, and emit no legacy credit meter or legacy threshold alert.
   Do not override same-credential enterprise scope only for a 404. If effective
   scope makes rendering legacy, this branch fails and branches 2-3 decide.
2. Coalesce `used = plan.used ?? overall.used` and
   `limit = plan.limit ?? overall.limit`, matching the existing display factory.
   A positive limit requires an existing, non-negative used amount.
3. If that coalesced limit is absent or non-positive, a finite non-negative
   `plan.totalPercentUsed` or the existing display-message percentage parser
   supplies the measurement. The displayed measurement must be the valid one
   that qualified the batch.

Retain the qualifying measurement/representation, not only a Boolean. On the new
404 path, split qualification renders split usage; summary credit qualification
uses the measured used/limit; percent-only qualification renders the validated
percentage. Per-seat hard-limit enrichment and legacy request-count precedence must
not override that primary representation. In particular, a missing used amount must
not become fabricated `$0` through an added positive limit. Try the message parser
when raw totalPercentUsed is negative or non-finite. Healthy-profile rendering is
unchanged. Token-based accounts qualifying only through percent may temporarily show
percent instead of an enriched dollar ratio while their profile remains unavailable.

Empty, metadata-only, on-demand-only and otherwise unmeasured summaries fail.
Hard-limit, team-spend and cached values cannot qualify a summary. Legitimate
measured zero qualifies; missing is not zero. Legacy data can supplement the
summary or rule out split mode, but cannot qualify on its own. Profile-success
handling retains its existing behavior.
Do not gate on provider name, numeric suffix, body text, or `activeAuthSource` from
a previous successful refresh. Pass the selected source explicitly with the attempt.

## D2. Identity and exact-credential ownership

Keep these concepts distinct:

- Fresh profile: the authenticated `/api/auth/me` result from this attempt.
- Previously authenticated profile: at most the last successful profile retained
  in memory and bound to the exact outbound credential and session lifecycle.
- Degraded profile: current HTTP 404, with no fresh authenticated subject.

No JWT subject, suffix, cached IDE email/name, guessed numeric ID, or success of an
unrelated usage request may fill a verified identity slot. No new identity source
or credential parser fields are needed for this design. An exact credential digest
is a continuity boundary, not proof of account identity, and must never be logged.

For a same-exact-credential transient 404, a previously authenticated profile may
be retained for display and in-memory ownership continuity only. It must not be
passed as a fresh verified subject to persistence, cross-credential Recent restore,
or new identity-dependent team-member discovery. A profile-less cold start remains
profile-less even if a similar email, JWT subject, or disk snapshot exists.

Track two in-memory values, never persisted or logged:

- `ownerCredential`: absent before any applied batch or after full logout, exact
  existing credential digest after a bindable applied batch, or unbound after a
  successful batch for which that existing digest is unavailable. An unbound
  owner grants no optimistic reuse or retained-profile continuity and never
  becomes a persistence key, authenticated subject, or logged value.
- `retainedProfile`: the last fresh authenticated profile bound to that digest.

For a changed unresolved credential (including token rotation), when an existing
owner is unbound or its exact digest differs, retire previous-account state once
before applying qualifying usage: clear
retained profile, last-account identity and team/user/per-seat discovery; reset
per-account state and adopt the session. Record the new owner so repeated unknown
refreshes do not repeat retirement. An absent owner at cold start or after logout
owns nothing: do not retire/adopt and revoke valid exact-credential Recent data.
A successful batch with an unbindable header is not absent. Healthy-profile batches
still use only existing authenticated account/scope checks; non-qualifying profile
failures do not trigger this retirement. Clear retained profile if a fresh success
cannot bind it to an exact digest. No new cookie parsing or normalization is added.

Unknown-credential adoption retires memory, discovery and generation, but invalidates
Recent with `revokePersisted: false` before reselecting the new credential. It must
not rotate the Recent validity token or delete a valid exact-cookie snapshot solely
because an unknown credential changed. Mismatched files remain hidden without a
fresh authenticated subject and matching scope. Existing logout, expiry, verified
identity-conflict and authenticated scope-change revocation remain unchanged.

Retained profile clears on startSession, expiry, logout or a different degraded
credential. Owner state survives partial startSession/expiry cleanup, whose
remaining baselines/latch must be retired if a different unknown credential arrives;
it clears at full logout. A fresh success records both values, while existing
authenticated account/scope checks remain authoritative. This does not include
a general redesign of healthy-login cleanup.

Before primary results arrive, a credential differing from the last applied owner
must not launch optimistic weekly/hard-limit requests using old team/user IDs.
Discarding results later is insufficient. Healthy profile success can use existing
sequential discovery afterward. Do not use JWT equality to bypass this boundary.

Degraded identity sinks are explicit: do not call the authenticated account-switch
check with synthetic identity; pass nil subject to both Recent identity-validation
sites and nil email to new roster matching. Retained profile is display/memory only.
Already-owned same-credential team IDs and limits may remain in memory, but cannot
cross an unknown credential boundary. Split memory account identity and fresh
persistent subject authority are separate inputs.

Returning to a fresh verified profile may recover verified authority only from
that response. Existing authenticated account/scope-change checks remain in force.
Logout, expiry, reconnect and selected-credential replacement must invalidate the
appropriate remembered profile context and all obsolete asynchronous publication.

## D3. Independent features and display

A qualifying summary updates existing meter percentages, amounts supplied by that
summary, plan/cycle information, refresh success state and eligible usage alerts.
Personal history and amount enrichment may continue under their existing
credential-scoped requests and generation checks; no guessed user/team identity.
Failure of optional identity-dependent enrichment must not discard successful usage.
Unknown enterprise identity must not select a roster member from cached local email
or reuse a previous credential's optimistic team/user requests or per-seat limits.

After the degraded decision, start no new team/member/per-seat discovery: no new
fetchTeams, roster match or sequential hard-limit resolution. Personal team-0 history
and amount collection remain available. Same-exact-credential cached team/user scope
may continue weekly/history, and already-owned limits remain memory-only inputs where
compatible with D1. Same-cookie optimistic work launched before profile results may
finish, but cannot establish identity authority or override the qualifying primary
measurement. Missing enterprise scope/member disables that optional enrichment only.

Retain existing layouts and existing missing-profile display fallback. Same exact
credential may display its previously authenticated name/email in memory; otherwise
use current neutral missing values, never another account's text. No new diagnostics
panel, technical status paragraphs, or profile-fetch error banner is introduced
for an otherwise successful qualifying refresh. The existing formatting policy
(percent precision, USD amounts, circles) is unchanged.

## D4. Persistence and notification authority transitions

A degraded refresh has **no fresh subject authority** even when an earlier profile
is retained for in-memory continuity. It must not create cycle-amount or split-alert
persistent writes or expand cross-credential restoration. The existing Recent
exact-credential restore behavior remains available; any fresh Recent publication
on the degraded path must not claim a newly verified subject.

A fresh-to-degraded transition must retire in-flight amount collectors/store leases
and obsolete notification work that captured prior persistent authority. Merely
setting the next snapshot's subject to nil is insufficient. Reestablish eligible
current-credential work in memory without erasing already-owned displayed data
solely because the profile is temporarily unavailable.

The transition boundary is the **acknowledged store/dispatcher authority fence**,
before publishing degraded state or starting replacement collection. Re-check the
refresh context after awaits. Writes already committed before that boundary remain;
no retroactive rollback is promised. Old activation, load, save and delivery-record
operations executing afterward must not restore or use retired persistent authority.
Recovery must not revive old writers. Cancellation alone is not this guarantee:
store activation also needs an authority epoch check, not just generation checks
on later load/save. Use the smallest extension to existing fences that proves it.

Preserve in-process threshold deduplication across same-credential authority loss
and recovery. If the alert store's session and persistent paths are separate, carry
only already-authorized same-account/scope/cycle delivery knowledge into the session
path; do not load or write another identity's file to manufacture continuity.
Successful delivered IDs remain distinct from pending/failed notifications. Repeated
404 refreshes must not emit the same delivered threshold repeatedly. Bold baselines
must never span a credential/account/scope reset. After a cold restart without
verified identity, cross-restart deduplication is not promised.

Downgrade adds no fresh ledger-file read, write or deletion. Carry only already-loaded
or acknowledged delivery knowledge. Recovery uses the union of authorized persisted
IDs and session memory for suppression; that union is not a new delivery and must
not itself be persisted. New successful deliveries under fresh authority may persist.

A same-account/scope/cycle submission that succeeds after the downgrade boundary
still records its delivery in session memory, including when the receipt was known
before the boundary but its append was delayed. Retired persistent authority blocks
the disk append, not this same-owner memory receipt. Account/scope change or logout
still rejects late receipts; failed or pending submissions are never recorded as
delivered. Therefore lifecycle rejection and persistent-authority retirement must
remain distinct. Continuity from a never-verified session to first verified identity,
across credential rotation, or across unknown-identity cold restart is not promised.

Use the existing ordering and operation/generation fences; avoid a general storage
redesign. Any additional mechanism must trace directly to this transition's tests.

## D5. Critical tests selected before implementation

Use existing URLProtocol/seam infrastructure, synthetic credentials and temporary
stores. Never access the real Keychain, IDE database, or UNUserNotificationCenter
from SPM tests.

1. IDE profile 404 + usable summary: current meter is applied, auth remains IDE,
   no whole-refresh error, browser request or Keychain deletion.
2. Summary missing/failing/malformed/empty + profile 404, even with successful legacy
   usage: no mitigation. Include legitimate summary zero usage and nonzero usage.
3. Browser 404; profile 403/429/5xx/network/decode errors: existing behavior.
4. Profile 404 plus unauthorized summary or legacy result; profile 401/204/empty:
   existing unauthorized precedence, fallback and expiry, no duplicate notifications.
5. A freshly verified profile followed by same-cookie 404 then recovery: current
   usage progresses, display/ownership continuity holds, fresh persistence authority
   is absent during 404 and restored only by a fresh successful profile.
6. Verified A -> unknown B; unknown B -> unknown C; synthetic provider subjects with
   equal suffixes: no inherited profile, amounts, team IDs, alert history or jumps.
7. Same unresolved credential repeatedly: stable session ownership; delivered
   threshold not repeated. Rotated credential is conservatively reset without
   restoring by unverified claims; no guarantee of cross-rotation alert continuity.
8. Logout/reconnect/credential replacement while primary, history, collector or
   notification work waits: old completions cannot publish or persist into new state.
9. Existing Recent exact-credential restore still works; no unverified rotated-
   credential restore; no new cycle/alert files while degraded.
10. Authority downgrade while collector/delivery is queued: old operation cannot
    write under retired authority; same-credential dedup survives downgrade/upgrade.
11. Enterprise identity unavailable: no stale-email member match, guessed userId or
    wrong optimistic scope; successful primary usage remains visible where supported.
12. Browser reconnect while available IDE credential still 404s: selected IDE batch
    is mitigated, rather than silently showing a different saved browser account.

Additional cases required by the reviewed amendments:

- Predicate table: all three D1 branches, measured zero, split percentages without
  used, `.checking` rejection, same-credential cached enterprise scope and changed
  unknown credential retirement. The qualifying representation must be rendered.
- Stale selected-source state in both directions: IDE success then IDE401/browser404
  must not mitigate; browser success then IDE404 may mitigate.
- Verified browser A to unknown IDE B after normal refresh, expiry and Connect:
  one retirement, no old-ID optimistic requests, profile, limits, amounts or deltas.
- Cold-start exact-cookie Recent cache plus failed history remains visible, with
  unchanged validity and no file revocation caused by the 404 path.
- Same-cookie downgrade retains displayed split amounts, has nil persistent subject
  and new Recent subject binding, and creates/modifies no cycle or alert file.
- Paused collection and successful notification completion across downgrade/recovery:
  no post-fence old-authority file operation, retained same-owner amounts and no
  duplicate delivery. Direct old-token store calls after the fence deterministically
  test stale activation/load/save/append, without assuming actor queue ordering.
- A percent-qualified summary plus hard-limit or legacy request metadata retains its
  validated percent; invalid raw total may fall back to a valid message percentage.
  Credit qualification retains summary used/limit rather than legacy request counts.
- Persisted exact-cookie B data survives verified A to unknown B adoption when new
  history fails; A's mismatched file stays hidden under B or an unverified rotation.
- No new enterprise discovery after the degraded decision; known same-cookie scope
  history and personal history still work independently of profile availability.
- A successful synthetic unbindable browser batch followed by qualifying exact-
  digest IDE 404 retires old enterprise IDs, profile, latch, baselines and alert
  history once. Repeated IDE batches do not repeat retirement. This test proves
  the local transition only, not that Cursor accepts such headers in production.

## D6. Validation and completion

Before implementation, record each model's spec verdict and proposed amendments;
resolve blockers under the two-reviewer plus Astra rule. Keep raw model transcripts
local in `.Codex/issue-128/`; publish only the concise specification/review decisions
if committing. Coordinator owns shared specs, README and SECURITY pairs.

Run focused business/integration regressions at the first implementation checkpoint,
then the full Swift test suite and release build at the final checkpoint. Three-model
cross-review is required at both checkpoints. Re-run affected checks after fixes,
not indiscriminate repeats. Update paired English/Korean security documentation for
any actual contract clarification; do not claim a fresh identity from a cached one.

No layout change is planned. If a new visual design becomes necessary, first provide
the repository-required before/after mockup and obtain owner alignment; that is not
permission to stop fulfilling unchanged backend work. Do not replace the installed
application or expose personal account data for screenshots.

Completion means an isolated, tested implementation matching the reviewed spec,
three-model final findings adjudicated, and a report stating actual validation and
remaining live-account limitations. Static/mock validation is not live validation;
no #127 root-cause claim, merge, issue closure or release is implied by this goal.

## Review decisions and provenance

[PR #114](https://github.com/WoojinAhn/CursorMeter/pull/114), proposed by @vjonas
at head `0e33292`, combined split-quota UI work with an IDE profile-404 mitigation
attempt. Its auth fallback is not transplanted here. Root-cause diagnosis remains
in [#127](https://github.com/WoojinAhn/CursorMeter/issues/127), untouched by this work.

| Amendment | Grok | Opus | Astra |
| --- | --- | --- | --- |
| D1 usable representations with actual effective scope | Approved final scope correction | Proposed/approved scope correction | Approved; avoids a 404-only scope-policy change |
| D2 ownership lifecycle and identity sinks | Approved | Approved | Approved; cold-start restore and isolation stay distinct |
| Pre-launch optimistic-request guard | Approved | Approved | Approved; result discard alone is too late |
| D4 acknowledged authority fence | Approved | Approved; withdrew issued-write exception | Approved; only pre-boundary committed writes remain |
| D4 same-owner late-success session receipt | Proposed/approved exact alternative | Approved with separate persistence/lifecycle fences | Approved; no disk authority or logout bypass |
| D5 focused regressions | Approved | Approved | Approved |

Evidence is local under `.Codex/issue-128/`: initial review results, consolidated
ballot results, and `spec-grok-final-scope-result.txt`. Revision v0.1 is preserved
there with SHA-256 `485b310afc6108ffab07a7e16f73efc39465f8ace0501bfcb4071e9bae50b88a`.
Muse's first run failed without a final report and supplies no vote. The owner-approved
fresh retry (`muse-spark-1.3-max`, reported Muse Spark 1.3 300K Max) completed against
v0.2. Its repeated identity/fence concerns are already explicit above; the following
additional corrections were independently approved by Grok and Opus and by Astra:

| Correction | Decision |
| --- | --- |
| Keep the qualifying primary measurement in degraded display | Accepted; prevents enrichment or legacy metadata fabricating or replacing usage |
| Preserve exact-cookie Recent files during unknown adoption | Accepted; memory/generation isolation remains and no unverified cross-cookie restore opens |
| Skip new enterprise discovery after a degraded decision | Accepted with the measurement rule; retain known-scope and personal independent features |

Muse's proposed narrowing of general expiry revocation was not adopted; existing
expiry behavior is outside this correction. Retained authenticated profile may still
provide the already-approved memory account digest, never persistent authority.
Grok and Opus reports are `spec-grok-muse-adjudication-result.txt` and
`spec-opus-muse-adjudication-result.txt`; Muse's is `spec-muse-v02-result.txt` locally.
Revision v0.2 is preserved locally with SHA-256
`c96ab49a3ca4fa05a18da8e7e8d7d3aa45933a329653f10a02a35d5597a4d085`.
This closes the spec-review gate; the implementation and final three-model gates
remain mandatory and open.

## v0.4 ownership clarification

Intermediate Opus review identified successful owned state with a nil existing
credential digest being conflated with cold-start absence. Synthetic integration
reproduction confirmed old enterprise request IDs and latch could cross the next
qualifying IDE credential boundary; live incidence remains unknown. Grok
(`unbound-owner-grok-result.txt`) and Opus (`unbound-owner-opus-result.txt`) explicitly
approved the narrow three-state ownership contract, and Astra approved it before
implementation. The prior v0.3 text remains local with SHA-256
`b2ad090ccaab57d5da5b1f10ede6d2e03d456e5022a1e3ae83f4317daa1c5618`.
This amendment changes only D2 ownership bookkeeping and its D5 regression.
No authentication fallback, cookie rewrite, live experiment or #127 work is added.
