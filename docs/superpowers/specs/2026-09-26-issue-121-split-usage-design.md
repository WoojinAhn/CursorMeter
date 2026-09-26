# CursorMeter split usage reform — issue 121

Status: implemented and validated through Muse / Grok / Opus specification, core and
integrated review gates, with final findings reconciled. Source commit `9287e0a`.
Native installation and live verification remain the owner’s handoff.
Baseline: `origin/main` at `c0225f7`; branch: `feature/121-split-usage`.
Issue: https://github.com/WoojinAhn/CursorMeter/issues/121

The user authorized implementation, parallel development, repeated three-model review,
and automated validation on 2026-09-26. Do not install, replace, launch, or alter the
running CursorMeter app or its persisted preferences. Native interaction verification
belongs to the user's next-morning handoff. Keep the task-owned sleep assertion until
work is complete. No release, major version change, main merge, or issue closure is part
of this work.

This is the authoritative implementation contract. Earlier
`design-121-settings-alerts.md` and `design-121-app-wide.md` are discussion drafts;
this document supersedes their design-only status and unresolved proposals. The HTML
mocks show synthetic scenarios, not native pixel parity or guaranteed plan allowances.

## 1. Problem and selected product behavior

The single `plan.used / plan.limit` meter can imply one allowance where Cursor exposes
two independent consumption percentages. Included model usage, paid spending, and
historical event costs are different measurements. Neither `$400` nor an inferred sum
of pool allowances is a valid denominator for both model pools.

- Use one 18-point C icon: a central filled pie and an outer progress ring, each encoding
  its own authoritative percentage. Default outer = Other Models, center = Cursor
  Models. A persisted placement preference swaps identities; never reorder by usage.
- Split accounts use icon-only menu-bar presentation regardless of stored text mode;
  never overwrite the stored None/Ratio/Percent value, which resumes for unsplit plans. A read-only native tooltip and
  accessibility description contain both names and percentages, with eligible dollar
  details and concise unavailable/stale status, without raw source timestamps. No request on hover.
- Clicking either mouse button retains the existing popover toggle. Popover enlarges the same central-pie/outer-ring meter and shows both pools,
  reset, actual paid spending separately, and existing chart/status/actions. Display
  settings select Percentage, Dollars, or Both (default); no unit toggle lives in the
  popover. Dollar readings show recorded family costs; pairing with inferred limits requires
  the separate Show estimated limits preference, default off.
- Keep both emoji pairs: Classic `⚡ / 🚀`, Dollar `💲 / 💸`. Keep 6/15-second temporary
  replacement and Quiet/Normal/Bold semantics. Restore the newest icon after effects;
  tooltip, accessibility and Settings still update while the image is owned by an effect.
- Retain `$0.05 / $0.30` included-dollar jump thresholds and add independent pool
  `+5 / +15 percentage point` triggers. Bold tier-2 notifications remain independent
  of the usage-threshold master switch and target selection.
- Preserve unsplit credit/request/percent-only/enterprise behavior and saved legacy
  text preferences. Existing authentication and refresh-admission architecture stays.

## 2. Source contract and capability

The pre-implementation verification and synthetic wire shapes are recorded in
[`2026-09-26-issue-121-source-contract.md`](2026-09-26-issue-121-source-contract.md).
The auto/api mapping and personal period endpoint were observed against the dashboard
and matching captures; they are not inferred from field names or from current code,
which has not yet decoded these fields. No new live-account capture is required to
repeat that already completed evidence, and private captures remain uncommitted.

All endpoints are undocumented. Decode new optional fields without making absent or
malformed optional additions invalidate otherwise usable legacy responses. Validate
numeric values at the boundary; missing, negative, or nonfinite measurements are
unavailable, never zero.

| Source | Fields | Authority |
| --- | --- | --- |
| GET `/api/usage-summary` | `billingCycleStart`, `billingCycleEnd`; `individualUsage.plan.autoPercentUsed`, `apiPercentUsed`, `used`, `limit` | Primary Cursor / Other percentages; included total cents; legacy monetary limit only |
| POST `/api/dashboard/get-current-period-usage`, `{}`, existing Origin header | root cycle dates; `planUsage.autoPercentUsed`, `apiPercentUsed`, `includedSpend`; root `autoBucketModels` | Coherent supplementary percentages and model membership; cents and dates checked against summary |
| Existing filtered events POST | `teamId`, optional non-null `userId`, `page` starting at 1, `pageSize:100` | Historical event cost, model and kind; complete-cycle aggregate only after coverage checks |
| Existing summary on-demand fields | enabled, used cents, cap cents | Paid spending; positive cap permits budget percentage |

Primary summary wins when available. Supplement a missing measurement only when both
endpoint cycle boundaries agree and summary `plan.used` agrees with period
`planUsage.includedSpend` within one cent. `totalSpend` is not a substitute for missing
`includedSpend`; its equality was observed with paid spending disabled, not guaranteed;
otherwise keep it unavailable. Do not average percentages. Fetch period metadata only during an eligible cycle
collection or to fill missing summary pool fields, at most once per 60 seconds for the
latter and never on hover. It participates in enrichment backoff, not every normal poll. `totalPercentUsed` is not a
substitute for either pool. The period endpoint is optional enrichment, not a new credential authority. Only the
existing three primary endpoints participate in `hasUnauthorized`. Period/monthly
401, empty 2xx, 403 or network errors fail that enrichment only; they cannot erase a
good summary, delete credentials or log out the user. A coherent period measurement
can be displayed before history completes, including when history later fails. Retain
it across identical canonical primary fingerprints for at most ten minutes, under the
same account/scope/credential generation, with its original period source timestamp.
A delayed result may fill an unchanged newer local revision under those same checks;
keep that newer primary identity and never replace raw primary event evidence.
A changed fingerprint or expired measurement requires fresh validation. Primary and
period precision histories remain separate. Period-only fallback is display enrichment:
threshold and jump evaluation uses primary summary measurements, so late enrichment
never creates or replays a consumption event. When period metadata is unavailable at
both collection boundaries, retain provisional exact family sums using the bounded
classifier, but do not infer limits. A 429 still stops enrichment and establishes shared
server backoff.

For a verified personal token-based paid scope, presence of a valid pool field
establishes split capability for the accepted account/cycle/product scope; a companion
missing field remains unavailable. Require a positive reported included-plan monetary limit and a successfully decoded
current `/api/usage` response with no request limit before initial activation; a failed
usage call is not proof of a token plan. Split evidence with pending plan verification
shows an unavailable/checking meter and suppresses legacy ratio alerts until resolved. Free/zero-limit and enterprise
semantics are not validated by the personal Ultra audit; retain their current behavior
even if they expose similarly named fields. Membership name alone never establishes capability, and activation is not Ultra-only.
Personal eligibility also rejects `limitType:team`, nonempty team-usage data, enterprise/
business membership, overall-only contracts or a previously discovered enterprise
request scope. Do not add a mandatory teams call: personal accounts can legitimately
reject that endpoint. Unsupported or contradictory scope remains on the legacy path. Latch capability within that scope through
transient missing fields, then re-evaluate on a verified account, cycle, plan or team
scope change. If no split evidence exists, keep existing legacy paths and fixtures. Once split is
latched for a verified scope, an unusable summary is a meter failure even if `/api/usage`
succeeds. Do not publish `from(usage:)` or advance split success time; retain the last
split snapshot with its original time, expose stale/failure state, count meter failure
and rebaseline split jumps on the next good summary. Recent may still succeed separately.
Request-based/enterprise scopes must not inherit personal-period data: initially
collect period metadata and cycle model amounts only for verified personal scope.
Team usage retains existing scoped behavior; never attach personal `{}` metadata to
team usage. Future split support for free/request/team plans requires separate source
validation, rather than silently interpreting their old auto/api fields as paid pools.

Use value types for `UsagePoolID` (cursor/other), `SplitUsageSnapshot`,
`UsageRevisionIdentity`, `CycleAmountSnapshot`, amount status/attribution, and alert
scope. Do not overload legacy `percentUsed` with max/sum/average. Optional additions to
`UsageDisplayData` must have compatibility defaults for existing initializers/tests.
`withOnDemandActive` must preserve every new field, using a value copy or explicitly
forwarded fields plus a regression test. Silent reset to default nil is not acceptable.

## 3. Accepted revisions and ownership

Publish the fast summary-derived snapshot before history work. An accepted revision
has a monotonic local ID, captured timestamp, credential generation, verified opaque
account identifier, team/user scope, cycle interval, membership/capability and values.
Define account digest as SHA256 of `subject:` + trimmed nonempty subject, otherwise
`email:` + trimmed lowercased nonempty email. Empty/Unknown identity is session-only.
Use existing request-scope digest semantics in a distinct namespace. Cycle key uses
canonical parsed start/end epoch milliseconds with start < end; either missing boundary
means session-only alert persistence and no full-cycle amount inference. Email fallback
identity separates in-memory accounts only; without subject, create no new cache or ledger file. Use the subject from the current
validated identity response, never a cached previous account subject when the current
response omits it.
Use the existing subject-based identity where possible; hash a normalized fallback identity for in-memory isolation and never persist raw email, cookie or token
in new stores. Persistent cycle caches and ledgers require a nonempty verified subject
digest; an email fallback is session-only. Unknown identity can
use isolated session state but cannot load persistent private state.

Every successful usable primary snapshot receives a new local revision even if values
are unchanged. Process eligible threshold/jump events once per accepted revision. A repeated equal
snapshot updates freshness but produces no new delta. Enrichment belongs to its source
revision and is never a second consumption event. Before every asynchronous publish or
delivery, revalidate generation, account, scope, cycle and policy ownership. A matching identity alone does not excuse a changed membership or collection generation.
Plan identity is normalized membership plus reported included plan limit. A verified
plan change invalidates amount evidence and resets split signal continuity/high-water;
transiently absent identity fields do not establish a new plan. The initial plan key
remains stable when previously missing membership is merely discovered; a known-to-known
plan change still establishes a new ownership scope.

Cancel amount work and clear visible private state on logout/expiry/account transition.
Credential renewal preserves same-account delivered alert identities only after fresh
identity validation. Explicit logout attempts to remove the verified account's caches
and delivered ledger, preserves preferences, and continues to suppress IDE automatic
relogin. Without a verified subject in the current process (for example, a cold offline
start), old unidentified files remain unread and are not guessed to belong to that
account. File removal is best effort, not secure erasure.

Keep primary refresh admission (3 seconds), shared in-flight joining and feedback
(1.3-second progress, 0.65-second result). Preserve polling 1/2/5/15 minutes, activity
watcher debounce and cooldown, recent 30 and weekly collector. Monthly monetary work must not hold primary completion, next refresh, or valid percent
alerts behind a month scan. Preserve existing weekly/Recent participation in shared
refresh feedback and admission; this change does not require rewriting their task
lifetimes. Split alert/jump evaluation moves before awaiting that existing weekly path.
The new cycle collector is never awaited by the primary refresh completion path.

## 4. Complete-cycle dollars, classification and estimates

### Collection

Personal cycle collector is separate from the weekly five-page collector. Iterate
newest-first `[cycleStart, cycleEnd)` with cancellation between awaits. Decode monthly monetary JSON numbers directly into Decimal in a dedicated DTO;
preserve raw fractional cents until display rounding. Do not round-trip weekly Double
values as a substitute for the exact monthly path. Track page count, event count, byte count,
oldest/newest dates, total-count consistency, termination and reconciliation evidence.

Initial hard budgets: 100 pages / 10,000 events, 16 MiB response data across pages,
60 seconds wall-clock task duration, one collector per scope. System sleep retires an
active collector as cancellation before suspension; primary completion cannot start
new amount work while asleep. Wake restores normal admission with cancellation
cooldown and actual retired-page accounting. A real hard partial exposes that automatic
collection is paused and manual retry remains available after cooldown. Exceeded budgets
produce a partial state; they never silently establish complete coverage. Reject a single oversized response before decoding; aggregate response-byte accounting
belongs in a separate history-page result without changing weekly semantics. This is a
decoded/retained payload budget: existing URLSession.data(for:) still buffers one response
first, so do not claim a streaming transport-memory cap.

Within-page identical rows are counted as separate observations; only cross-page
exact duplicates on fingerprint fields flag ambiguous overlap, and no rows are dropped.
Valid empty termination is an explicit empty array consistent with the reported total
(or no total), or an omitted array with total zero. Explicit/omitted empty data while a
nonzero reported total remains unreached is incomplete. Stable total means unchanged
reported count across traversal/head recheck and an exactly matching visited count;
reaching before cycle start is independently valid window coverage. In that case
visited < reported total is expected because older account history lies outside the
cycle; it is not a count inconsistency. Counts changing during traversal, visited > total
or empty termination below total before reaching the cycle boundary remain invalid.

Completion requires explicit evidence: a valid empty page, reaching a stable reported
total, or reaching before the cycle start in monotonically ordered pages. An omitted
event array with nonzero unreached count is not an empty-cycle proof. Never infer
completion solely from a short page. Reject invalid timestamps, inconsistent counts,
repeated page fingerprints, or cross-page ambiguous identical records for confident
amount inference. Do not silently deduplicate rows: two legitimate equal events can
exist. Flag ambiguous overlap instead. Content fingerprints hash canonical ordered relevant
row fields (timestamp/model/kind/exact cost/chargeability), not the requested page number;
otherwise a repeated page under a new number would evade detection. Equal timestamps
are allowed; reversed chronological order is not. Changed total, head fingerprint,
cycle, included total, pool percentages or model membership invalidates that attempt.
Discard rejected aggregates immediately, including before any retry budget check.

Compare summary/period and first-page fingerprints before and after collection; allow
one bounded retry for page/head/period changes, under the same total budget. A changed
primary summary returns unstable immediately: another walk cannot validate the original
accepted revision. Canonical fingerprints compare parsed cycle dates and normalized
membership, not equivalent ISO string spellings. Timestamp fingerprints preserve exact
numeric values without a Double round trip. The source has no atomic
snapshot guarantee. Expose uncertainty even after checks; do not call a delta the cost
of the last request. Collection scheduling is result-aware and separate from primary refresh:

| Last result | Automatic next attempt | Explicit stopped-collection retry |
| --- | --- | --- |
| Complete/stable (including attribution unavailable) | At least 10 minutes later, and only when primary fingerprint changed | Uses automatic admission; no manual bypass |
| Partial because a hard page/event/byte/time budget was exhausted | Paused for this cycle until an explicit manual scan completes successfully or the cycle/scope resets; cancellation or failed manual work cannot clear this pause | 60-second cooldown; explain the same limit may remain |
| Unstable snapshot after bounded retry | Backoff 5, 10, 20, then 60 minutes; two consecutive identical full primary fingerprints can permit retry after at least 60 seconds | Uses automatic admission; no manual bypass |
| Transport/5xx | Exponential 60-second backoff capped at 30 minutes | Uses automatic admission; no manual bypass |
| 429 | Respect Retry-After, minimum 60 seconds; missing/invalid header means 30 minutes | Same server backoff; manual action cannot bypass it |
| Other endpoint/decode failure | 30-minute backoff | Uses automatic admission; no manual bypass |

Primary fingerprint includes cycle, included used, both percentages, membership and plan
limit. Coalesce all callers onto at most one collector. All automatic collection pages,
including verification/retry pages, share a rolling 300-page/hour session budget. A new
cycle resets same-cycle terminal partial state but does not bypass server retry time.
Automatic work waits until a full 100-page attempt allowance is available; a depleted
hourly allowance is a temporary wait, never a terminal cycle partial. Cancelled work
reserves its allowance until completion reports actual attempted pages, then charges
only that cost. A later partial result does not replace an existing complete dated
snapshot; retain its provenance internally and show a concise old-cost qualifier when needed.
The existing popover refresh action requests amount work under the same admission
rules. Show a short pending/error state only when relevant; do not add a Summary tab
or a separate diagnostics disclosure to expose collection internals.
General Refresh remains a primary refresh with 3-second admission and requests amount
work subject to its own limits; it never waits for amount completion. A single page's
decoded payload cannot exceed the remaining 16 MiB cycle budget. API results expose
actual Data.count; 429 metadata is captured only in the new enrichment path so legacy
error behavior stays intact.


### Classification version 2

Revised after the usability review: the model-family partition is Cursor vs Other,
with explicit Bot activity separated. Do not maintain an Other-provider allowlist.

Order matters:
1. Missing or blank model names remain unresolved; they cannot establish a family.
2. Explicit `grok-bot-` names are Bot cycle activity, regardless of server membership.
3. Exact normalized membership in current `autoBucketModels` is server Cursor evidence.
4. A bounded table of observed names/variants for Composer 2.5 and Cursor Grok 4.5,
   4.6, 4.7 supplies a **provisional correction** where metadata lags. Unit tests
   enumerate accepted actual spellings and ensure future versions/substring traps
   do not acquire Cursor status through this correction alone.
5. Every remaining nonblank model is provisionally Other, including newly observed
   providers. Record `nonCursorRemainder` provenance rather than claiming a known provider.

Version-1 snapshots must be discarded in full and recollected: their family subtotals,
not only their estimated limits, can be wrong. Preserve the legacy provenance enum
value only to decode and reject those snapshots. Regression tests cover Muse, GLM,
Kimi, a future provider, server-list precedence, Bot precedence, blank model names,
and separate included/paid/billing-error handling. A missing or lagging Cursor catalog
can still misattribute an unrecognized Cursor alias to Other; these remain provisional
model-family amounts rather than confirmed charged-pool amounts.

Classification reports both family and provenance. The exact monthly kind allowlist and chargeability rules in the source-contract
appendix are normative. Cost-bearing CUSTOM_SUBSCRIPTION/free and unknown kinds remain
excluded/uncertain and block limits. A cost-bearing isChargeable:false row is an
unresolved contradiction; do not zero it or silently include it. Kind identifies
included vs paid vs non-chargeable events; do not classify every unknown kind as included. Preserve weekly
legacy behavior separately. Allow only observed included kind codes, explicit paid
`USAGE_EVENT_KIND_USAGE_BASED`, explicit errored-not-charged exclusion. Missing amounts
on chargeable rows are incomplete; known non-chargeable rows may contribute zero.

Model family is not a guaranteed charged pool: Bot helper calls and spillover can use
ordinary models. Complete total reconciliation is necessary but insufficient proof of
allocation. Show provisional family amounts as **estimated attribution**, not confirmed
per-pool accounting. Unknown/missing/ambiguous or spillover evidence blocks inferred
pool limits. At/above either 100% also blocks new inferred limits because spillover is
plausible. Keep authoritative percentages regardless.

Reconcile sum of included non-Bot raw costs against the coherent summary included
cents with at most 1 cent absolute tolerance (an app policy, not a guaranteed server rounding rule). Keep Bot/paid/unknown subtotals separate.
Round each displayed subtotal independently; do not force residual into a pool or drop
fractional cents to manufacture agreement. Keep residual and coverage in internal diagnostics, outside normal user-facing views.

An estimated effective limit is `attributable included cents / (poolPercent / 100)`.

**User opt-in (2026-09-26 usability revision):** add the persisted Display > Popover
preference **Show estimated limits**, default off, independent of Percentage / Dollars /
Both. Off hides inferred denominators everywhere without hiding recorded costs or
changing reported percentages, circle geometry, alert thresholds, or paid budget caps.
Explicit server-provided limits are not estimates and are unaffected. Enabling the
preference permits display only after the eligibility checks below pass; it must not
force a denominator or treat request count alone as sufficient evidence. Keep `~` on
every inferred denominator. Revalidate on account, cycle, or plan changes and withhold
inference when spillover or contradictory data prevents reliable attribution.

Present an accessible information button beside Show estimated limits. Clicking it
opens a small transient help popover; the first transition from off to on opens the
same popover if it has not already been viewed. Any successful showing, including an
explicit information-button activation, records that it has been shown. Escape and outside clicks close
it, and keyboard users can open it and return focus. Do not require confirmation or
show permanent explanatory paragraphs. Help content:
- Unofficial limits estimated from sufficient matching usage and cost history.
- Plan changes or usage spilling into another pool can require revalidation.
- Circles and alerts use reported percentages.
Keep the explanation out of the main usage popover. Enabled but ineligible inference
may show one short Estimate not ready status. Disabled inference is an ordinary
amount-only view. Preserve the preference while hiding controls on unsupported accounts.

Require complete stable reconciled coverage, same scope/cycle/plan/revision values,
positive pool amount, percentage >= 0.1 and < 100, sufficiently precise source resolution, no unresolved classifications or
charge routing contradictions. Server list plus bounded correction is still an
estimate: label inferred limits with `~`; keep explanatory detail in the estimate help
popover instead of repeating a permanent caption. Round inferred limits to whole USD for display while preserving
full precision internally; retain cents for recorded usage. Do not snap the calculation
to predetermined plan amounts. Do not present estimates as official contractual allowances.
Track observed fractional decimal places per pool/source/scope, conservatively capped
at three places; no observed fractional precision means resolution 1 percentage point.
Let resolution q = 10^(-observedPlaces). In addition to the percentage floor, require
(q / 2) / percentage <= 0.05. With integer-only evidence, 1% and 3% withhold a limit,
10% and 50% qualify; observed three-place evidence permits smaller percentages. Carry
resolution/provenance with the amount snapshot; never infer precision from the dashboard
rounded label. This is an uncertainty policy, not proof of a server rounding algorithm.
If an amount snapshot's source percentage differs from the current pool percentage,
withhold that pool's old inferred limit while retaining the dated amount. Missing or
at/above-100 current values in either pool block both inferred limits. Empty or blank
server model lists do not count as usable membership evidence.
At zero/tiny/insufficiently precise percentage, show amount if otherwise eligible, no
inferred denominator.
An absent server model list still permits provisional family subtotals from the
classifier, but blocks inferred pool limits until coherent metadata exists. Hide attributed pool costs when unresolved records or reconciliation failures prevent
estimated attribution; keep the authoritative included total and a concise costs-unavailable status. Do not show a permanent Unknown
category when all records have been assigned. One unknown cost-bearing row blocks
limits for both pools. Do not add unknown billing/amount errors to included totals.
The one-cent rule compares cents-valued Decimal residual against `1`, not `0.01`.
Never use `$400`, a fixed Ultra multiplier, or this user's measured caps as fallback.

Cache only aggregate provenance, not raw monthly events, in a separate versioned
atomic file capped at 1 MiB, permission 0600, current cycle, max age 24 hours, loaded
only after identity validation. Cache values are labeled cached; they never seed jump baselines, high-water or delivery
ledger, cannot generate alerts and cannot be paired with a newer percentage to recompute a fresh estimate. Format dollar values by dividing cents
by 100 and decimal-rounding to two USD places using `.plain` (half up for nonnegative
amounts); format inferred caps to whole USD with `~`. Never round the ledger itself. Recent's
version-1 256 KiB/30-row store and keys remain unchanged. Changing classifier version
invalidates inferred limits until recollection.

## 5. Notifications and jumps

### Dispatcher ownership and nonblocking delivery

The view-model-owned split controller creates one pure event batch per accepted revision
and enqueues it in one main-actor dispatcher; primary refresh never awaits authorization,
delivery or ledger I/O. There is one shared NotificationManager instance injected into
the view model and app delegate. For split events the glyph coordinator is visual-only;
it must not send a second Bold banner. Legacy entry points remain available.

The dispatcher bounds work to one active batch and one newest pending batch, coalescing
replaced pending work without marking it delivered. Each batch has independent threshold
and Bold policy revisions. A threshold master/target/value edit invalidates only its
threshold component; a jump enabled/intensity edit invalidates only its Bold component.
Changing glyph style alone changes presentation and does not cancel eligible Bold.
Account/cycle/plan/scope transition invalidates both. After authorization, before submit,
revalidate ownership and filter invalid components. After successful submission,
record the exact submitted threshold identities if ownership and the store lease remain
valid, even if a later policy edit or correction arrives during delivery. The banner
has already been delivered; omitting its identity would permit a duplicate. Deliver any still-valid component; one setting must not cancel the other's
eligible event. Release reservations for dropped/failed components. Do not replay stale
queued jumps: drop jump components older than the continuity ceiling; a later fresh
threshold can still be evaluated. An equal newer primary revision preserves an already
pending valid Bold event with its original occurrence time; a newer qualifying Bold
replaces it. Revalidate ownership before asynchronous store writes
so old completions cannot resurrect a logged-out ledger.

Permission state for Settings is read through an injected async provider, wired only in
production. Creating any Settings controller in tests never accesses the real notification
center or requests authorization. Default test controllers are memory-only.

### Thresholds

When split capability is active, never enter the legacy sticky on-demand latch and
never inject `isOnDemandActive:true` or call legacy single-ratio `checkAndNotify`.
`wouldActivateOnDemand` cannot replace either pool. Paid is a separate row and scope;
legacy unsplit latch behavior remains unchanged.

Keep the existing master and app-status settings. Each Cursor/Other card has its own
enabled state and warning/critical pair. Initialize new pairs from the saved shared
values, preserving user customization; untouched defaults remain 80/90. Keep a
separate paid-budget card only when spending is enabled with a positive cap. The
master switch preserves all individual choices. Reuse the existing single-track,
dual-thumb gauge in each card, including W/C chips, zone colors, ticks, and legend;
do not split Warning and Critical into separate slider rows. Use the existing slider
range 0–100, step 5, minimum separation 5, with one shared normalizer for loading,
editing and evaluation. Persisted 95/100 must remain 95/100 on relaunch; invalid values
are clamped consistently. Do not silently rewrite valid legacy preference values.

Evaluate fresh valid pool percentages, including true >100 values. Positive enabled
paid cap adds an independent paid scope. Highest newly crossed threshold per scope;
successful critical covers warning too. Group scopes discovered in one revision into
one banner; include current usage and threshold separately. Changing placement has no
notification effect. Threshold/target edits apply at the next fresh revision.

Dedup identity: opaque account + request/plan scope + cycle + pool/budget identity +
threshold kind/value. A verified plan transition creates a new plan scope; placement
does not. Persist successful
submissions only, separately from usage cache; in-flight reservations prevent duplicate
awaits. Persisted ledger contains no balances, raw identity or credentials. Prune previous cycles only when their cycle end is more than 7 days old; never prune
a current-cycle record merely because delivery was 8 days ago. Cap the file at 1 MiB
and 4096 records; oversized/invalid stores are ignored and use session-only state.
Do not delete the current same-account ledger at launch or verified credential renewal. Permission denied/delivery error does not mark
success. Invalidate pending ownership on account/cycle change and the corresponding component
on any master/target/threshold or jump enabled/intensity edit, including while awaiting
permission; use the component rules above, not blanket cancellation. New split/combined bodies use concise English matching the existing app and approved
mock, with stable pool names and unit symbols. Legacy bodies otherwise retain their
existing language; the unsupported Max-mode clause is removed. First fresh snapshot may notify once if already over threshold. Recovery means the
first fresh result after sleep/network failure or a retry after denied/failed delivery,
and is eligible only for a not-yet-delivered identity. A dip below the threshold and
rebound never rearms it. Negative corrections do not remove delivered identities. Unknown cycle uses session-only ledger.

### Jump detection

All new continuity/high-water rules in this subsection apply to split signals only.
Legacy request/credit/percent-only/on-demand calculations keep their existing absolute
OR limit-relative rules, last-accepted baselines, failure/gap behavior and mode-change
reset. Only removal of the unsupported Max-mode cause and injectable submission are
shared changes.

Included total delta uses fresh `plan.used`, never divided by `plan.limit`. Independently
measure Cursor and Other percentage-point deltas and enabled actual paid-dollar deltas.
A tier is the maximum of eligible signals: tier 1 >=5 cents OR >=5 pp; tier 2 >=30 cents
OR >=15 pp. Included aggregate `.20 + .20 = .40` still yields tier 2. A positive paid
cap additionally allows the existing 5%/15% cap-relative signal. Missing cap does not
block an observed paid dollar delta. Keep included and paid scopes distinct in text.

First snapshot, account/cycle/capability change, failed refresh recovery, explicit `NSWorkspace.didWakeNotification`,
or a gap greater than `max(2 * refreshInterval, 120 seconds)` establishes baseline only.
A missing/invalid measurement resets only that signal's continuity. Paid enabled/cap
changes rebaseline paid scope. Disabled residual spend remains visible and never causes
an active-spend/budget notification. Authoritative paid zero means `enabled:true` and valid reported used==0 in the
same resolved paid scope, with unchanged cap/enabled state; a positive cap is not
required for a dollar delta. Such zero followed by positive paid spend is comparable; first positive observation alone is not a jump.

For every split signal (included cents, each pool percentage and enabled paid cents),
retain its own cycle high-water value. Eligible delta =
`max(0, current - max(previousAccepted, highWaterBefore))`. Update high-water afterward.
50→40→56 yields +6 pp, not +16. Correction/rebound text names the high-water reference;
normal monotonic text says "since last refresh". Reset high-water on account, cycle, plan identity, scope or capability transition.
Wake, failed-refresh recovery and long gaps reset comparison continuity only and retain
cycle high-water; then update it as max(prior high-water, current). Placement never
resets either state. This can suppress real consumption after a downward correction;
that is an explicit false-positive tradeoff. Legacy single-pool jump semantics stay intact except removal of the unsupported
guessed Max-mode cause. Existing legacy threshold semantics remain outside the new
persistent split policy; its pre-existing critical-then-warning bug is recorded as
out of scope rather than silently broadened into this change.

Jump enabled controls effects and Bold notifications. Quiet shows tier 2; Normal shows
tiers 1/2; Bold additionally notifies tier 2. Both glyph styles remain available. Disabling the effect cancels an active glyph
and immediately restores current geometry; logout/expiry similarly restores current
auth-state icon. Form
one event batch per revision: combine threshold and Bold messages when both qualify,
without making either's settings a prerequisite for the other. Successfully delivered
threshold identities are recorded even in a combined banner. This implementation titles
included-dollar activity **Included usage increased**, and shows the aggregate delta
and both current primary percentages without a per-pool attribution disclaimer. Monthly scans do not bound each primary polling interval, so the previously
proposed conditional per-pool dollar jump path is deferred; adding it later requires two
coherent per-pool observations of that same interval without delaying or replaying the
event. Never guess a pool from outer position or bigger percentage. Percentage-point
deltas are normalized to the source contract's maximum three fractional places before
5/15 pp tier comparisons; 4.999/14.999 pp remain below their next tier.

Notification click opens the current popover (never an old account snapshot). Preserve
update/auth/connection click handling. All jump submissions, including legacy ones, use the same injectable authorization
and delivery boundaries; no direct notification-center call in a testable jump method.
Do not request notification permission just by opening Settings. Unit tests must use injected permission and submission hooks, never
`UNUserNotificationCenter.current()` in the SPM host.

## 6. App-wide presentation and preferences

Usability revision, 2026-09-26: these requirements supersede the earlier Summary
and diagnostic-heavy UI. The interactive proposal is `docs/mockup-121-usability.html`;
native presentation changes are still pending implementation.

- **Icon:** clamp geometry to 0…100, retain source value in text. Zero has visible track;
  missing has a distinct dashed/neutral unavailable region, not an empty-zero fill.
  Independent regions remain legible in light/dark and without color. Existing
  70%/90% yellow/red boundaries stay independent of 80%/90% alert defaults.
- **Hover/AX:** use native `NSStatusBarButton.toolTip` with structured multiline plain
  text and equivalent accessibility value. Hover never fetches or takes focus; opening
  the popover dismisses it. Include both named pools in saved spatial order. Describe
  actual stale/pending/unavailable conditions briefly without dumping collection timestamps.
- **Popover:** use 300 pt width for split, existing width for legacy. Enlarge the same
  central-pie/outer-ring geometry used in the menu bar. The review mock proposes 112 px;
  verify native fitting rather than treating HTML pixels as exact AppKit parity. Do not
  replace this visualization with two horizontal progress bars. Put exact pool readings
  beside the circle, identified by outer-outline and center-filled markers.
  Percentage mode shows both pool percentages. Dollars mode shows recorded family
  amounts and, only when opted in and eligible, each pool's estimated limit. Both mode
  shows percentages plus recorded costs, with the same opt-in rule for denominators. Circle geometry always uses authoritative pool
  percentages, regardless of text mode. Missing amounts/limits never become zero or
  a fabricated denominator. Do not sum pool limits into a shared allowance.
  Move useful cycle summary information here: recorded included total in monetary
  modes, attributable Bot activity, paid spend/cap (including nonzero spending after
  paid usage is disabled), reset/cycle, and existing chart.
  Keep one cost-status line, selected by failure, availability, old-cost and estimate
  readiness precedence. Do not show partial Bot totals. Do not include Collection details,
  coverage counts, reconciliation residuals, or raw timestamps in the normal UI.
  Preserve identity, membership, refresh, update, Dashboard/Settings/Log Out/Quit,
  `Cmd+,`, and both-button toggle behavior. Fit height dynamically and keep actions
  reachable on small screens. Recent usage opens the existing Usage tab directly.
- **Display settings:** show a working outer-pool selector and preview for split plans.
  Hide irrelevant legacy text controls while preserving their saved preferences; show
  the working None/Ratio/Percent selector only for applicable single-pool plans. Hide
  split placement controls on single-pool plans. A Popover section provides the saved
  Usage values preference: % / $ / Both, default Both, using NSSegmentedControl. This control
  belongs only in Settings, never in the popover. Its preview honors the same amount
  availability, estimate opt-in, and estimated-limit conditions as the popover. Add the
  default-off Show estimated limits switch and information popover specified in section 4
  for eligible split account types. Keep the existing Quiet/Normal/Bold and emoji-style
  NSSegmentedControls; do not replace these with dropdowns. Keep both emoji styles,
  intensity/sensitivity and weekly options. Transient failures do not reset preferences.
- **Alerts:** retain the master and independent per-family enable switches and threshold
  pairs. Reuse the existing dual-thumb gauge unchanged. Hide an inapplicable paid card.
  Show OS permission problems only when actionable; no permanent "Allowed" caption.
  Explain Bold only beside its selected intensity in Display; omit cross-tab prose.
- **Usage:** remove the Summary/Recent selector and the duplicate Summary view. Open
  recent individual usage directly, retaining all 30-row/timezone/cache/refresh/error
  behavior and saved timezone. Do not replace this with another cycle overview.
- **General:** existing startup, refresh, update/version/dev provenance unchanged.
- **Observation:** extend every relevant `withObservationTracking` re-arm block in
  app, popover and Settings. Separate image updates from title/tooltip/AX updates.
- **Auth/lifecycle:** keep IDE-first, browser opt-in/whitelist, 401 fallback, 403/network
  semantics, explicit logout suppression, settings controller lifetime and activity
  watcher behavior. No PR114 profile or auth workaround is imported.

## 7. Verification and delivery

Select tests before code and preserve existing fixtures. Required suites:

1. Decode split/partial/zero/invalid fields, coherent fallback vs mismatched cycle,
   capability retention/reset, legacy request/credit/percent-only/enterprise parity.
2. Collector: full/empty/large cycle, short nonterminal pages, missing arrays, unstable
   count/page/head, duplicate ambiguity, invalid dates/money, fractional cents, unknown
   kind/model, explicit Bot precedence, provisional corrections, spillover blocks,
   exact budgets/cancellation, cache ownership/size/age/version/logout.
3. Estimates: coherent ratio, <=1-cent tolerance, rounding residual, zero/tiny/>=100
   percentage, classification uncertainty, cache vs newer percentage, plan transition.
4. Alert state machine: pool independence, simultaneous grouped thresholds, critical
   covers warning, restart, changing targets/thresholds/placement, denied/error retry,
   account/cycle/policy changes during await, session-only fallback, combined Bold.
5. Jump: exact 5/30 cents, 5/15 pp, aggregate .20+.20, unattributed dollars, paid no-cap,
   disabled paid residual, first/wake/failure/gap/missing return/correction/rebound,
   late enrichment/duplicate revisions/estimated-limit changes cause no replay.
6. Integration: primary publishes before history completes; cancellation/identity race,
   rapid refresh/activities coalesce, failure preserves valid percentages and settings;
   both glyph sets/intensities restoration use newest placement/value; legacy tests pass.
7. Presentation: pure text/presentation tests and AppKit offscreen layout/icon checks
   where safe. HTML Playwright screenshot/checks for before/after scenarios and mobile
   report layout. Do not claim HTML verifies native behavior. Native installed-app
   walkthrough, hover positioning, screenshot refresh and VoiceOver are explicitly
   handed to user for tomorrow morning, not silently marked passed.

Review gates use exact prior Cursor models, fresh read-only sessions:
`muse-spark-1.3-max`, `grok-4.7-xhigh`, `claude-opus-5-5-max`.
Gate A: this specification and compatibility commitments. Reconcile all material
findings before implementation. Gate B: data/notification core before final integration.
Gate C: complete branch diff and test evidence; fix material findings and re-review the
changed risk areas. Record acceptance/rejection reasons, not vote counts.

Use parallel independent implementation workstreams with explicit disjoint file
ownership; coordinator owns central integration and shared documentation. Tests may use
separate Swift scratch directories if concurrent builds conflict. No live credentials,
private real usage or PII in fixtures, public issue, screenshots or commits.

The MainActor entry-point prerequisite is a separate coordinator-owned commit. Open
a draft PR to obtain both macOS ARM/Intel CI signals before checkpoint B; do not merge.
Run full `swift test` and debug/release builds. Preserve Swift 6 and zero dependencies.
Update API reference, user docs and English/Korean doc pairs; remove stale single-meter
and guessed Max-mode text. Update issue #121 to match actual contract and correct its
obsolete emoji/percentage-only proposals. Final handoff includes branch/commits,
review outcomes, test/build evidence, known API uncertainty and manual check steps.


### Review-selected additional acceptance cases

- Summary 502 + usage 200 on a latched split scope retains the split snapshot/time and
  counts meter failure; initial usage failure never confirms non-request capability.
- Simulated 60-minute polling with a 12,000-row source or continuously changing source
  respects per-result cooldown and rolling page bounds; manual action respects 429.
- Authorization held open does not block another primary refresh. Editing thresholds
  removes only threshold content; changing Bold removes only Bold; logout prevents a
  completion from reviving disk records.
- Copying display data through `withOnDemandActive` preserves optional split fields.
- Precision gates at integer-only 1/3/10/50 and fractionally observed resolution, plus
  no-fractional-second cycle dates and source endpoint precision ownership.
- End-of-source without crossing the cycle start requires included reconciliation before
  full-cycle labels. A mismatch rejects the aggregate, retries once within the shared
  budget, then follows instability backoff without replacing prior complete evidence.
  If that retry runs out of shared budget, preserve the known instability outcome and
  discard its partial; it must not create a new cycle hard-budget pause.
  Other subtotals remain observed activity with coverage caveats;
  never claim a separately verified Bot weekly or paid-month total from truncation.
- Keep all legacy assertions except deliberately changed Max-mode wording and usage
  notification click routing; update those named tests explicitly. Threshold identifiers
  receive an intentional usage prefix so only usage notifications route to the popover.
- Settings creation makes no notification-center call; 95/100 thresholds survive reload;
  amount refresh/period cadence and unsplit disabled placement are tested.

## 9. Accepted usability implementation revision (2026-09-26 evening)

The user authorized native implementation of the revised mock and copy audit. This
section supersedes earlier surface descriptions where they conflict. Existing data
safety, classification-v2, notification deduplication and authentication contracts remain.

- Remove Usage Summary and its diagnostic presentation, retaining the complete existing
  recent-usage table, refresh, cached/error states, row count and timezone behavior.
- Use the enlarged C meter in the popover. Percent/dollar/both is a Settings-only
  preference. Support legacy credit, request and percent-only shapes without inventing
  a second pool or dollar denominators. Existing team exclusions remain; this revision
  does not establish unverified team split support.
- Dollars represent recorded model costs, not subscription payments or invoices.
  Inferred denominators require opt-in and all existing data gates. Never seed them
  from published/community plan amounts. No fixed request-count warmup is required.
- Separate warning/critical pairs per Cursor Models, Other Models and eligible paid
  budget. Copy normalized existing shared thresholds only when a scope has no saved
  pair; retain existing enabled-target preferences. Later shared-setting changes do
  not overwrite explicit per-scope choices. Use the existing ThresholdRangeSlider
  with its dual-thumb layout. Preserve the master switch and per-card switches.
- Apply the copy audit to native Settings, popover, hover, VoiceOver and notifications.
  Keep concise meaningful errors/freshness flags. Hide normal permission, internal
  source/scheduler/coverage/residual states and redundant off/saved captions.
- Bold retains its independent enable semantics, both emoji sets and dollar sensitivity.
  Describe it once at the selected Bold control. Aggregate cost jumps remain Included
  usage; never fabricate a per-pool attribution or mislabel high-water delta as a
  previous-refresh delta.
- Preserve all unrelated controls, existing authentication/refresh/admission, real
  nonzero paid spend, menu actions and accessible labels. New preferences participate
  in the application's observation re-arm paths and reset/migration behavior.

See `../reviews/2026-09-26-issue-121-copy-audit.md` for exact copy dispositions.

### Gate A contract clarifications

- View-model migration materializes and persists all missing cursor/other/onDemand
  threshold pairs from the normalized legacy shared pair once, while preserving saved
  pairs and enabled targets. The engine's empty-map fallback exists for legacy callers
  and tests, not for the migrated view-model policy. Scope edits never write shared
  keys. The legacy single-pool gauge continues using only the shared setters.
- Compare effective per-scope pairs when invalidating pending threshold delivery;
  estimate preferences never invalidate alert or jump state. Gauge edits publish the
  warning/critical pair atomically.
- Estimate opt-in is an additional presentation gate; it never replaces source, scope,
  reconciliation, precision or spillover checks. Off hides all estimate-only statuses.
- Dollar display selection is available for verified split and legacy monetary data.
  Request-only and percent-only accounts keep their existing unit display and do not
  expose dollar controls. Server-reported single-pool limits remain real, unaffected
  by the estimation preference. Checking/unknown capability cannot invent dollar data.
- Information help uses transient NSPopover (not NSAlert). The information button is
  keyboard accessible and labelled About estimated limits. Escape/Close restore focus
  to it; an outside click retains the destination's focus. Any successful show
  records estimateExplanationSeen in UserDefaults; explicit info access
  remains available. No repeated automatic display on later toggles.
- Ignore retired usageSummarySelected storage; Recent is always the Usage destination.
  Do not remove the unrelated Local/UTC segmented control.


### Integrated usability review clarifications

- The accepted threshold migration is eager: first load materializes missing Cursor,
  Other and paid pairs from normalized shared values. Existing pairs survive, and later
  legacy edits do not change them. Preference tests restore every key they write.
- Removing Summary does not remove recovery. Popover and Recent user refresh first run
  the shared primary refresh, then retry monthly collection manually only when the
  automatic schedule is at the cycle-budget stop. The existing 60-second completion
  cooldown, server Retry-After, identity, sleep and freshness gates remain. Ordinary
  clicks do not turn unchanged/history-backoff states into manual scans.
- Recorded pool costs require a matching-scope `estimatedAttribution` snapshot; partial,
  unresolved and unreconciled subtotals remain hidden. This preserves the existing
  collection gate. The authoritative included total may still appear. Cached or source-
  mismatched costs get a brief old-cost qualifier; mere timestamp ordering does not.
- Pro/Pro+ eligibility uses capabilities, not an Ultra name check. Percentages, icons,
  alerts and controls work when eligible. Dollars additionally require observed allowed
  billing kinds and valid attribution. Pro billing kinds remain unverified; do not add
  guessed kinds or promise dollar availability without a live capture.
- Legacy monetary data supports percent/dollars/both using its real server denominator.
  Settings and Popover share the same capability predicate: active paid usage requires
  a reported used amount and a positive paid limit; otherwise credit-based plan data qualifies.
  Request-only and percent-only data retain their supported units and hide dollar
  controls. Legacy thresholds continue using shared preferences, never Other's pair.
- Display and Alerts use bounded scroll viewports. Gauge geometry is unchanged; its
  virtual accessibility thumbs additionally name the pool.
- All new preferences are app-wide and survive logout. The information popover records
  first display only after actual presentation, including an explicit prior info click.
  Escape/Close returns focus to the info button; outside clicks preserve destination focus.
- Review suggestions to restore long captions, Korean-only new notifications, or lazy
  threshold inheritance were declined in favor of the agreed compact English UI and
  eager independent migration. Earlier source-time and allocation-disclaimer wording
  does not override this usability revision.
