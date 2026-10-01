# Today usage highlight in the popover circle

Date: 2026-10-02

Status: Frozen v1.1 after three-model review and the Opus/Gemini/Astra zero-use help clarification.

Issue: [#130](https://github.com/WoojinAhn/CursorMeter/issues/130)

Source baseline: `origin/main` at `9f19ec1`

Local visual companion: `docs/mockup-130.html` (synthetic data; not an implementation artifact).

## Outcome and scope

Distinguish today's contribution within the existing large popover circle using
the selected **B treatment: a brighter segment plus a thin boundary**. Retain the
current total filled angle, severity colors, pool names, percentages, dollar
readouts, and circular layout.

Owner decisions from the design interview:

- Apply this to the **large popover circle only**. The menu-bar icon and settings
  preview retain their current appearance.
- Determine today from **server event timestamps**, using **KST midnight** as
  the boundary. App launch time and local observation history do not define today.
- Use visual option B. A (brightness only) and C (dim earlier usage) remain
  comparison options in the local mockup, not additional app settings.
- Refresh today's supporting records when a normal refresh observes new requests.
  An unchanged displayed percentage must not suppress a new-request update.

The owner authorized implementation after three-model specification review.
Installation, merge, and release remain separate from this development task.
Do not add another ring, a daily chart, permanent explanatory paragraphs, a new
display-mode selector, or a new notification family. Existing single-pool plans
retain their current display. The initial feature applies where split-pool data
and eligible cost attribution are available, without an Ultra-only assumption.

## What the data establishes

`SplitUsageSnapshot` supplies the two cycle-to-date percentages. It does not
supply per-day pool percentages. `CycleUsageEvent` supplies a server timestamp,
model, kind, and charged amount. The existing full-cycle collector classifies
included costs by model family and checks coverage, stability, and reconciliation.

The proposed split therefore estimates **the visual share attributable to
today's recorded included costs**. It does not turn event dollars into an
official daily quota measurement. Model-family attribution can differ from
consumed-pool attribution, particularly after spillover. Completion and successful
reconciliation establish a usable snapshot; they do not prove proportional
cost-to-quota behavior for every model or future policy.

Do not use the existing weekly bar totals as the numerator: they combine model
families and include categories that do not belong in these included-usage pools.
Do not infer a daily percentage from rounded UI text, the old $400 allowance,
an undocumented plan table, or notification high-water state.

Relevant seams:

| Area | Current responsibility | Design change |
| --- | --- | --- |
| `CycleUsageCollector.swift` | Full-cycle classification, coverage, reconciliation | Accumulate today's included cents during the same event traversal |
| `CycleUsageModels.swift` | Aggregate snapshot and source percentages | Optional KST-day aggregate and source included-total evidence |
| `CycleCollectionSchedule.swift` | Admission, coalescing, cooldown, backoff | Day-aware demand identity; cadence decision below |
| `SplitUsageController.swift` | Receipt ownership and publication | Preserve existing fences for the new aggregate |
| `CycleUsageStore.swift` | Verified-owner persistence | Validate optional day metadata without changing authority |
| `SplitUsagePresentation.swift` / `MenuBarView.swift` | Popover values and large meter | Derive a popover-only today overlay and concise help |
| `CircularProgressIcon.swift` | Shared split renderer | Optional pool-keyed overlay input; existing callers remain unchanged |
| `CursorMeterApp.swift` | Observation and view updates | Observe overlay inputs so an open popover redraws |

## KST day contract

Use a Gregorian calendar with `TimeZone(identifier: "Asia/Seoul")`. Given the
current instant, identify the KST day interval `[dayStart, nextDayStart)`.
Include only eligible events within both that interval and the current billing
cycle. Exactly 00:00 belongs to the new day; an event immediately before midnight
belongs to the previous day. Respect the existing exclusive cycle-end boundary.

This is deliberately a **KST day**, including on a Mac configured for another
time zone. The Recent usage Local/UTC setting does not change it. Use the text
`Today (KST)` wherever a day label is exposed. A timezone preference or changing
the weekly chart's local-day behavior is outside this issue.

Pass one captured day interval into a collection attempt. Do not let pages
silently change their day interpretation while collection crosses midnight.
Capture that interval at admission and use it for both the attempt's demand and
the collector. Refresh a deferred, not-yet-started demand's day before admission;
never change the day of an already-running attempt.
Retain only one day's aggregate; no raw-event ledger or multi-day history is
required by this feature.

## Allocation contract

For each pool, using a coherent observation:

```text
P = server-reported cycle usage percentage for this pool
C = recorded included cost for this pool in the billing cycle
T = the subset of C whose server timestamps fall in today's KST interval

todayShare = T / C
todayPercentagePoints = P * todayShare
earlierPercentagePoints = P - todayPercentagePoints
```

`P` is the exact effective `Double` passed to the circle, including a currently
accepted period supplement for a missing summary field. Source-percentage matching
and the two-pool 100% rule use those same effective values, never formatted text.

Calculate cost sums with `Decimal`; round only for presentation. The ratio must
be finite, `C > 0`, and `0 <= T <= C`. Do not repair invalid inputs by treating
them as zero. A verified `T == 0` is different from missing evidence. When the
reported total is zero there is no filled segment to subdivide.

Both the numerator and denominator use the **same classification and collection**.
Preserve the collector's included-kind rules, including its existing accepted
`USAGE_EVENT_KIND_FREE_CREDIT` handling; do not invent a different exclusion for
today's numerator. Bot and on-demand spending stay separate. Existing uncharged
error/zero-cost handling remains unchanged, and unresolved attribution prevents
a claimed valid split. Do not introduce a second model-name classifier.

Example: reported usage 42%, cycle included cost $210, today's included cost $40.
The estimated today part spans 8 percentage points of the full circle; earlier
usage spans 34. The total still ends at the official 42%. These are explanatory
numbers, not a new user-facing numerical readout.

This computation does not require an estimated dollar limit and must not depend
on the `Estimated limits` preference or reuse a displayed rounded limit. It is
nevertheless an estimate, which the help and accessibility descriptions disclose.
It never changes alert eligibility, budget calculations, jump detection, or the
official total percentage.

## Eligibility and unavailable states

The strict candidate requires all of the following:

- Complete, stable collection and successful existing reconciliation; no
  unresolved attribution. Invalid/missing cost data remains unavailable.
- Same account, scope, cycle, plan, classifier version, and permitted receipt
  ownership. Preserve credential-generation, task, and logout fences.
- A current, non-stale primary snapshot. Match both raw source percentages and
  the source included total, not their formatted strings. Percent equality alone
  can miss an amount change beneath the reported percentage precision.
- Day metadata matching the current KST date, valid bounded amounts, and valid
  source evidence. An old cached record is not a fresh current-day observation.
- A successful current-generation collection for the latest admitted demand,
  including its event revision or per-refresh fallback token. A changed fallback
  token also withholds the old overlay until its supporting collection succeeds.
- Both reported pool percentages below 100%. With either pool at or beyond its
  allowance, withhold both overlays because model-family costs cannot establish
  consumed-pool attribution after spillover. This is a conservative app policy,
  not a claim that the server mandates it.

These conditions govern the optional highlight. They must not prevent the
existing total meter, costs, recent requests, or successful primary usage from
displaying. Do not add error banners or diagnostic collection details for an
unavailable highlight.
Unresolved attribution, invalid event costs, or failed reconciliation withholds
both pools. Independent per-pool unavailability below applies only after the
whole receipt has passed those shared gates, such as a verified zero denominator.
If a pool reports positive usage but its recorded cycle cost is zero, withhold
both overlays: the other pool's costs could contain misclassified events. A pool
with both zero usage and zero cost simply has no subdivision of its own.

| Situation | Circle behavior |
| --- | --- |
| Eligible partial-day contribution | Earlier fill, brighter today fill, boundary between them |
| Verified no usage today | Existing fill; no artificial sliver or boundary |
| All cycle usage happened today | All filled area is the brighter shade; no internal boundary |
| Tiny contribution | Preserve its true angle; omit an overpowering boundary when necessary |
| Missing/invalid/stale evidence | Existing total circle; omit the optional subdivision |
| Midnight without a new eligible collection | Discard yesterday's highlight; retain the total circle |
| One pool has zero usage and zero cost | Omit that pool's highlight; the other can still qualify |
| One pool has positive usage but zero cost | Omit both highlights because family attribution is inconsistent |
| Either pool at 100% or higher | Preserve current clipping/readouts; omit both today overlays |

## Selected visual treatment

Continue the renderer's 12-o'clock origin and clockwise progress. Earlier usage
occupies the beginning of the filled region; today's portion occupies its end.
Draw the boundary at their shared angle, not at the official total endpoint.
The outer ring's thickness, center pie radius, separation, track, and missing-data
appearance are unchanged. Never enlarge a small contribution to a minimum angle.

Use each pool's **current cumulative severity color** for both sections. Do not
color earlier usage green and today red simply because the total crossed a
threshold. Preserve the existing fixed 70% / 90% color policy independently of
user-configured alert thresholds.

The mockup uses a 32% blend toward white for today's shade and a 0.75-point adaptive
boundary. These are native verification targets, not a claim that CSS colors
exactly match AppKit semantic colors. Validate light/dark appearance and increased
contrast before implementation sign-off. Draw the separator within the existing
filled geometry by clipping the stroke to it; use no boundary when earlier or
today is zero. Omit the separator when either side spans less than 0.5 percentage
points of the circle. This handles both tiny today usage and almost-all-today
usage without letting a stroke dominate a slice or cross the 12-o'clock origin.
Use a dark hairline in light appearance and a light hairline in dark appearance;
also verify the corresponding increased-contrast appearances. The today fill
remains the brighter variant of its existing severity color.

Keep the overlay keyed by `UsagePoolID`. Swapping outer/center placement must
move the correct daily values with their pool. Introduce an optional explicit
renderer argument rather than inferring behavior from image dimensions. Only
the popover passes it; menu-bar and settings-preview call sites keep the existing
default rendering.

The existing % / $ / Both preference still controls the adjacent values. Do not
add daily figures beside them. Suggested circle help is two short lines:

```text
Lighter segment: today (KST).
Estimated from included usage costs.
```

The native image remains excluded from duplicate accessibility traversal. Use
popover-only help/accessibility helpers; do not add text to shared `pool.line` or
`SplitUsagePresentation.tooltip`. Replace the circle's tooltip with the two lines
above when an eligible overlay has at least one finite positive today portion;
otherwise retain its existing total tooltip, including when both today portions
are verified zero. Known-zero row accessibility still reports 0.0 below.
Do not add an unavailable message. Append to each eligible pool row:
`Today (KST): about 8.0 percentage points, estimated from included costs.`
Use P*T/C, one decimal place (including 0.0), or `less than 0.1 percentage points`
for positive values below 0.1. Preserve the existing spoken total and money values.

## Collection cadence and request cost

The owner selected refreshed records rather than either a ten-minute mismatch
window or applying an older daily ratio to newer usage. A normal admitted refresh
that observes new requests must invalidate the prior daily allocation and request
a supporting collection. This applies to the shared data flow even if the popover
is closed; merely opening the popover must not become the only new-request trigger.

Reuse the existing session-start, periodic, activity, and manual refresh triggers.
Do not add a new polling loop, websocket, or a network request for every rendered
frame. A new request is discoverable when an existing refresh observes it; this
does not promise instantaneous server push or observation while the app is quit.

Collection demand must consider:

1. The existing raw summary fingerprint, including included total and pool data.
2. The current KST day.
3. A content revision of the latest validated live event receipt. Derive this
   from stable event identity/content and available total-count evidence, not
   collection time, formatted text, or the display percentage. Reuse data from
   the existing history request rather than adding a separate discovery call.

Retain this small revision alongside the admitted receipt before weekly/recent
projection discards the original shape. It is a **change signal**, not evidence
of complete daily or cycle costs. A cached, failed, unresolved-scope, or old-session
receipt must not advertise a new live revision. If an event change signal cannot
be obtained, do not equate that absence with a proven unchanged history: create
one fallback demand per newly admitted primary refresh ID. This fallback token
is not an event-content revision. Coalesce duplicate demand within that refresh
and retain only the latest pending fallback while collection is active. Apply
the same 60-second admission, backoff, and budgets. This avoids treating every
unknown-revision refresh as the same permanently suppressed nil key. A known changed
revision or day must bypass the old `.unchanged` suppression even when all shown
percentages and rounded included totals are unchanged.
Each new per-primary-refresh fallback token also bypasses `.unchanged`; its lack
of a content revision does not make consecutive fallback demands identical.

Make this decision after the current refresh's history collection concludes and
its first-page candidate passes the existing receipt/context/scope admission.
Primary usage can publish earlier; only supporting collection admission waits.
Keep original event content and available total-count evidence before the Recent
30-row or weekly projections. A failed paginated collection uses the fallback even
when its successful first page remains usable in Recent; this conservative choice
can create more fallback attempts but does not label a failed collection current.
Never substitute a previous batch's live revision for the current batch's failure.
If a history lookup is skipped, decide the fallback at that batch's history exit.
Store the admitted primary identity with pending demand. Before starting, require
that exact primary localID, scope and credential generation still to be current;
otherwise wait for the newer batch's own history decision. Pass the captured
snapshot and summary together. This admission-only localID check does not replace
the existing scope/generation completion fences for an already-running collection.

Coalesce identical demand keys and allow only one active cycle collection. Keep
the newest pending demand when further requests arrive in flight. Once the active
attempt completes and admission permits it, process that demand without requiring
another distinct change event. Preserve valid same-owner cycle receipts, but do
not publish an older-demand daily overlay as if it incorporated the newest known
requests. The existing collection still verifies its own stable head, summaries,
and reconciliation before publication.
When a today attempt returns complete coverage but failed reconciliation, treat
it as unstable for scheduling. If an existing same-owner, same-source-fingerprint
receipt is reconciled, retain its cycle amounts instead of replacing them with
unavailable attribution; mark those retained costs as earlier using the existing
cost presentation, and withhold the overlay. Other successful features stay usable.

Consume a pending demand when its attempt starts. An identical in-flight demand
coalesces into that attempt. A failure does not re-enqueue itself: a later admitted
primary refresh can request another attempt under backoff. Only a genuinely newer
pending demand drains after completion. This prevents zero-page failures from
creating a self-sustaining retry loop. Drain after supplementary-period work ends
as well as after full-cycle work; neither may swallow a pending demand.

For today's admitted demand, replace the successful-collection 600-second cooldown
with a **60-second minimum between starts**, aligned with the existing activity
throttle. Rapid manual refreshes must not bypass it. Keep any existing collection
without today's demand on its current scheduling contract. When a pending attempt
is deferred, schedule at most one cancellable wake-up at the next allowed time;
this is demand draining, not periodic polling. Stop it on logout or scope change.
Normal refreshes, including the refresh button, use automatic budget and failure
protections for today's demand. The existing explicit retry of stopped cost
collection remains a legacy cost-only operation; it does not fulfill today's
demand or grant a new overlay. Keep its existing availability text and behavior
consistent. Sleep cancels the deferred wake-up while the
latest requested demand is retained as intent under its existing owner. An active
attempt cancelled for sleep becomes that intent. On wake, invalidate yesterday's
presentation and wait for the next normal admitted primary/history refresh to
replace sleep-era request data before draining. Do not fetch against a sleep-era
summary merely because the Mac woke. Ordinary failures still never re-enqueue
themselves. Logout and scope retirement discard pending intent.

The faster today cadence applies only when both effective percentages exist and
are below 100%, and the last complete collection in this scope did not establish
unresolved/invalid attribution or a positive-percentage/zero-cost contradiction.
Otherwise retain the existing 600-second, changed-summary cost collection path
and any needed period supplementation. A later valid collection re-enables today
cadence; a real scope/cycle change resets this local eligibility evidence. Failed
reconciliation remains transient and uses unstable backoff, not a permanent latch.

Preserve the current collector budgets: 100 pages, 10,000 events, 16 MiB, and
60 seconds per attempt; the automatic history-page budget is 300 per hour. Keep
transport backoff, unstable-source backoff, endpoint-failure backoff, and 429
Retry-After handling. A new event revision is not permission to bypass these
failure protections. Budget exhaustion or an unstable server response can still
temporarily remove the optional highlight; the official total remains visible.

This choice increases requests. For N history pages, an ordinary complete attempt
uses approximately N+4 endpoint calls, including period checks, summary recheck,
and first-page verification. Four history pages are therefore about eight calls;
retries can cost more. The 300-page budget is not a cap on all endpoint calls.

Current weekly receipts cannot replace that full collection: they stop at a
seven-day boundary or page limit and do not prove a complete cycle denominator
or the same stability checks. Reusing them as a cheap, fully validated daily
breakdown is not promised. Incremental ledgers or broader shared-fetch redesign
need a separately reviewed design rather than an unverified optimization here.

## Midnight, persistence, and lifecycle

Represent the optional day detail using its KST interval, evidence timestamp,
Cursor/Other included cents, and source included total. Reuse the parent
snapshot's cycle amounts, source percentages, identity, and classifier version.
Legacy caches without the optional field keep their existing amount behavior
but provide no today highlight. Keep the existing envelope version; decode the
day detail optionally and discard invalid day metadata independently of valid
parent amounts. Do not elevate JWT subjects or cached email to verified
persistence authority. The evidence timestamp records attempt admission (the
instant selecting its KST interval); it is not a TTL or permission to reuse an
older ratio against newer source data.
After restart, restored costs keep their existing display rules, but the today
overlay waits for a supporting collection admitted in the current session.
Matching cached percentages alone must not make old day detail appear refreshed.

Use a separate collection demand identity containing `(summaryFingerprint,
KST dayStart, eventEvidence)`, where event evidence is either a validated content
revision or the explicit admitted-primary-refresh fallback token described above.
Do not mutate the original summary fingerprint used for source
stability checks. A day change must allow collection even when the cumulative
summary is unchanged, subject to the selected scheduling policy and existing
transport backoff.
Keep `schedule.observe` on the raw summary fingerprint for its existing stable
observation counter; use the separate demand key only for today coalescing and
unchanged suppression. Today admission measures 60 seconds between starts;
legacy cost-only manual retry retains its existing 60 seconds after completion.

Continuous changes can make the collector unstable and temporarily suppress the
highlight until a stable collection succeeds. The frequency is not measured, so
there is no guaranteed highlight latency. Preserve existing unstable backoff and
its two-equal-summary early-retry rule rather than introducing a new superseded
outcome or weakening source validation in this issue.

Re-evaluate the KST day on refresh, wake, and popover opening. While the popover
is visible, schedule a one-shot next-KST-midnight invalidation so an open circle
does not retain yesterday's highlight. This timer invalidates presentation; it
does not independently authorize network calls. Cancel it when no longer needed.
Do not depend on a Mac-local day-change notification to represent KST midnight.

A collection crossing midnight may still produce a valid cycle-cost receipt,
but its earlier-day detail is ineligible for the new day's overlay. Do not erase
that otherwise useful receipt. Likewise preserve #128's same-owner in-flight
alert delivery receipt continuity through presentation-only split-to-credit-to-split
transitions. That existing contract does not extend cycle-amount collection across
a retired split presentation. Actual account/scope/cycle/generation changes and
logout retain their fences.

## Verification and implementation boundary

Select focused tests before changing application code:

- KST 23:59:59 versus 00:00:00; non-KST Mac timezone; Recent Local/UTC preference;
  billing cycle starting or ending within the day; collection across midnight.
- Correct per-pool included sums and existing exclusions; zero versus missing;
  invalid amounts, unresolved events, partial pages, unstable history, failed
  reconciliation, and a positive percentage with no usable denominator.
- Raw percentage and included-total mismatch, cache restoration, expired day,
  matching evidence after successful collection, and the selected cadence policy.
- New event receipt with unchanged displayed/raw percentages and included total;
  identical receipt suppression; unavailable revision fallback; multiple arrivals
  during one collection; deferred newest-demand execution and preserved backoff.
- Consecutive admitted refreshes without an event revision can each request a
  fallback after admission allows it; repeated callbacks within one refresh cannot.
- Normal/warning/critical, no/all/almost-all/tiny today usage, one unavailable pool, swapped
  placement, total zero, and 100%-or-higher withholding.
- Identical total endpoint, track, and non-popover rendering; readable light/dark
  and increased-contrast appearance; concise help and meaningful row accessibility.
- Account/scope/cycle/generation/logout rejection; same-owner presentation changes
  preserving valid receipts; fresh UI observation after an async result.
- New primary acceptance before deferred drain; wake with changed usage/cycle;
  impossible-overlay legacy cadence, transient reconciliation retention/backoff,
  fallback invalidation, and retry attempts resetting daily sums.

Use the existing split-renderer and collector/scheduler tests rather than adding
a parallel rendering or fetching stack. Native screenshot checks should use AX
paths and sanitized account data. Refresh affected product screenshots only as
part of implementation. Keep the HTML comparison local; version this English
specification with the implementation. Do not change the installed app or user
settings as part of automated verification.
