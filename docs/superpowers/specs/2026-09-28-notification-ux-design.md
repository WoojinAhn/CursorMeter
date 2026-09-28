# Notification UX specification

Status: implementation candidate in #125, pending final model reviews and main
integration. Source baseline: `5477ddb`. Date: 2026-09-28. Implementation: #124.
Related baseline: #121 / #122.

Publishing this specification does not change the behavior shipped by #122.
Implementation is tracked separately in #124 and `feature/124-notification-ux`. HTML mockups,
screenshots and raw model-review transcripts remain local; this document is the
versioned implementation contract and does not require them to interpret its rules.

## Outcome

Use three notification families: configured usage alerts, significant usage
increases, and app status. Put the relevant scope, actual value and severity
first; keep the body short and preserve the meaning of costs and percentages.
Representative payloads and acceptance criteria below define the chosen behavior.

The coordinator selected this policy after independent Cursor rescue reviews by
Fable 5.1 Max Thinking, Grok 4.7 Extra High, Gemini 3.1 Pro and Muse Spark 1.3 Max.
This is an adjudicated recommendation, not a claim of unanimous agreement.

Fable, Grok and Muse reported viewing all five supplied screenshots, with the
compact banner's final visible text matching the coordinator's image inspection.
Gemini reported no image access and contributes a text/structure review only.
All four jobs completed. File-read success alone is not proof of visual access.

## Vocabulary and units

- Preserve `Cursor Models`, `Other Models`, `Included usage`, `Paid budget`, and
  `Paid spending`. Budget means a configured spending cap; spending means an
  additional charge; included usage means allowance consumption.
- `Warning` and `Critical` match the setting controls. Neither word asserts that
  the allowance is exhausted. A threshold of 60% is still just a configured level.
- Use one decimal for measured percentages, including `.0`; configured integer
  alert levels retain their existing whole-number display. Preserve the existing
  `<0.1%`, `<100.0%`, and `>100.0%` boundary format and do not clamp over-100 usage.
- Show percentage changes as `Last refresh 10.0% → now 25.0%`. This avoids both
  the mathematically wrong `+15%` and unfamiliar `pp`/`%p` abbreviations.
- A corrected series uses `Previous peak 50.0% → now 65.0%`, not the most recent
  lower reading. Monetary changes retain `+$0.40 since last refresh` or
  `+$0.40 above previous peak`; readers should not subtract dollar totals.
- Do not add `Surge`, `Crit`, `Warn`, a new icon vocabulary, inline bold, custom
  buttons or explanatory developer-state labels to the OS banner.

## Deterministic composition

### Configured alerts

1. Only already-eligible, not-yet-delivered threshold events enter composition.
2. Rank Critical before Warning. Within a level, use the stable order Paid budget,
   Other Models, Cursor Models. Additional charges come first; the two included
   families follow the app's default display order. This is a tie-break policy,
   not a claim that dollars and percentage points are comparable.
3. Title: `<Scope> <actual percentage> · <Level>`.
4. First body row: the configured alert level. If an authoritative money or
   request fraction is available, show it with that level instead.
5. Next rows: every other eligible threshold, with scope, actual percentage and
   level. There are at most three threshold scopes; none may be omitted to make
   room for a Bold increase.
6. Use any remaining body-row budget for qualifying Bold information, in the
   increase order below. Do not promise an increase in the title if it is omitted.

### Significant increases (Bold)

1. Preserve the existing alert gate and raw-value Tier calculation. Determine
   Tier eligibility per signal; an overall Tier 2 is not enough to include every
   positive companion. Paid includes both absolute and positive-cap-relative
   eligibility. Do not compare or normalize dollars against percentage points.
2. Only individually Tier-2-qualified signals appear in an OS increase summary.
   Order: Paid spending, Other Models, Cursor Models, Included usage.
3. With no threshold event, title: `<first qualifying scope> increased`.
4. First row: that signal's value change with its true comparison basis. Additional
   qualifying signals follow in the fixed order, within the row budget.
5. A percentage row needs a captured reference and current value. Do not recover
   these from already-rounded text or read a newer live value while dispatch waits.
6. Missing percentage snapshots are omitted from unrelated dollar-change banners.
   Missing does not become zero. The banner no longer repeats both model-family
   percentages under an Included dollar increase.
7. A secondary percentage row can use `Other Models: 20.0% → 35.0%` to avoid
   repeating the normal refresh reference. Its unmarked arrow always means the
   captured previous reading to current reading. A corrected secondary row must
   explicitly say `peak`, meaning the previous cycle peak, not the last refresh.

### Body budget and omissions

The composition budget is **three explicit body rows**, not a guarantee of three
visual lines in macOS. Long names, large values and font settings can wrap. Native
notification layout is owned by the OS; the HTML compact clamp is a review aid.

Threshold rows are mandatory. After them, choose individually eligible increase
rows in the stated order until the budget is full. A same-scope increase may omit
the repeated scope label only when the sole preceding body row is that title's
configured alert level. After any other threshold or increase, name the scope
explicitly so values cannot appear to belong to the preceding scope. Omitted increases are not
queued for another notification and are not represented as a recoverable event
history. Do not say `+N more in popover`: clicking opens current usage, not the
old notification's full payload. Do not fabricate a detail view to support copy.

**Freshness:** combine thresholds and Bold only from the same observation revision.
If permission waits allow a newer threshold to replace an older pending Bold,
show the latest threshold and omit that older Bold. Do not combine a title saying
86.0% with an old body saying `now 82.0%`, nor replay the omitted increase later.
Legacy coalescing likewise requires the same completed refresh. Captured event
references and values must stay immutable through authorization waits.

When a newer observation contains the same undelivered threshold identity and a
new qualifying Bold increase, let that observation deliver both together. An older
active batch must not consume the newer threshold first and split the pair into
two banners. Same-revision value replacement remains valid.

This is intentionally a summary, not a complete refresh ledger. With three
threshold events, the banner contains those three states and no Bold detail.
With four qualifying increases alone, the first three are shown. The tradeoff is
explicit: lower-ranked awareness details may be absent, but configured alerts
are not displaced, and real additional spending takes precedence among increases.

## Legacy and app-status behavior

- Legacy request, included-dollar, paid-dollar and percent-only alerts use the
  same vocabulary and show actual usage separately from the configured level.
- Selected change: coalesce a legacy threshold and Bold from the same completed
  refresh into one payload. This is a dispatch change, not a string-only edit.
  Preserve ownership/revision cancellation and acknowledge threshold delivery
  under its existing contract. Do not silently redesign the legacy ledger here.
- New release: `Update available: <version>` / `See what’s new on GitHub.`
  Substitute the validated release version; do not hardcode an example version.
- Failure: `Can’t refresh Cursor usage` / `5 refreshes failed in a row.\nData may be out of date.`
- Expiry: `Cursor session expired` / `Reconnect to resume usage updates.`
- Status events remain separate from usage batches. Existing update opt-out,
  fifth-awake-failure behavior, session-expiry exception and click destinations
  remain unchanged. Do not promise a login window in every reconnect path.

## Implementation boundaries

Copy: consistent nouns, English legacy text, actual usage and level titles,
short app-status messages, and percentage-change notation.

Required plumbing/composition: retain each signal's eligibility and exact captured
reference/current values in the event; retain real money/request fractions where
available; choose titles and rows using the policy above; pass actual legacy
usage to its formatter; coordinate same-refresh legacy delivery once.

Keep numeric thresholds, independent scope controls, the dual-thumb gauge,
icon styles, OS permission handling, raw-value comparisons, split dedup identities,
split Critical-covering-Warning, absence of a Bold cooldown, and click routing intact.
Legacy threshold acknowledgement and continuity gates keep their existing behavior;
this change does not retrofit the split ledger or baseline policy into legacy plans.
No new historical event store, notification settings or estimated-limit logic.

## Review decisions

- Adopt Fable's actual-value titles and before/current percentages; shorten its
  four-row proposal to three rows and keep dollar deltas explicit.
- Adopt the shared recommendation to ignore incidental below-tier deltas and to
  let real qualifying signals determine the title.
- Reject Gemini/Muse's `pp`, `%p`, `Crit`, `Warn` and `Surge` vocabulary; reject
  the integer percentages in Gemini's combined example.
- Reject Grok's very long combined lines: they preserve too much at the cost of
  the requested quick comprehension.
- Reject promises in Grok/Gemini/Muse that omitted historical deltas are already
  visible in the live popover. The app has no such event-detail contract.
- Choose legacy coalescing, which Grok/Gemini recommend and Fable treats as a
  separate decision. Muse prefers keeping two banners; fewer simultaneous OS
  interruptions is the chosen tradeoff, requiring explicit implementation tests.

## Acceptance criteria

- Cover each existing notification family: split thresholds and Bold, legacy
  request/included-dollar/paid-dollar/percent-only alerts and Bold, combined
  delivery, app status, and intentional suppression. The local review mapped
  47 existing cases plus three new policy cases; reproduce the behavioral
  coverage in implementation tests rather than depending on the local HTML.
  Verify ordinary and corrected deltas, tiny companions, missing values,
  threshold ties, Paid without cap, Paid relative-only Tier 2, and over-100 usage.
- Every eligible threshold is represented, even when Bold also fires. A lower
  severity never becomes the title ahead of a higher severity.
- `+$0.01` Included cannot headline an independently qualifying Cursor increase.
- Percent arrows use the event's exact previous/peak/current sample, and current
  display values cannot race the async notification permission wait.
- No amount is derived from estimated limits for notifications. No omitted
  payload is falsely promised in a current-state popover.
- Same-refresh legacy threshold+Bold delivers once; threshold-only and Bold-only
  still deliver under their own settings, cancellation and acknowledgement rules.
- Additional design fixtures cover a Paid relative-only trigger ($0.15 on a $1
  cap), four qualifying increases with no threshold, and a latest threshold
  combined with an older pending Bold. Their payloads are specified below.
- Below-threshold first observations do not synthesize a Bold jump. For split
  usage, the first observation after a continuity break also resets the baseline.
  An eligible undelivered threshold may still alert independently. Usage-alert
  and Bold switches retain independent gates.
- Inspect native macOS output during later app implementation. The local screenshots
  verify only the HTML design and illustrative truncation, not native parity.

## Representative payloads

These are synthetic examples, not account measurements. Eligibility is an input
to composition: retain the existing raw-value gates and sensitivity settings.
Each block contains the title on the first line and the body after the blank
line. Body line breaks are intentional; the OS may wrap them further.

### S01

Cursor usage is 82.0%; its undelivered Warning is configured at 80%; no Bold increase.

```text
Cursor Models 82.0% · Warning

Your warning level is 80%.
```

### S18

Cursor rises from 10.0% to 25.0% and independently qualifies for Tier 2. Included cost rises by only $0.01 and does not qualify.

```text
Cursor Models increased

Last refresh 10.0% → now 25.0%
```

### S13

Cursor readings are 50.0%, 40.0%, then 65.0%; the qualifying increase is above the previous peak of 50.0%.

```text
Cursor Models increased

Previous peak 50.0% → now 65.0%
```

### S08

Included cost rises from $10.00 to $10.40 and qualifies for Tier 2. The model-family percentages do not change.

```text
Included usage increased

+$0.40 since last refresh
```

### S17

Paid is $9.30 of a $10.00 cap and Cursor is 93.0%, both with undelivered Critical at 90%. Other is 82.0% with undelivered Warning at 80%. All four increases also qualify; the three mandatory threshold rows leave no room for them.

```text
Paid budget 93.0% · Critical

$9.30 of $10.00 · alert at 90%
Cursor Models 93.0% · Critical
Other Models 82.0% · Warning
```

### C01

Legacy included cost rises from $15.90 to $16.80 of a $20.00 limit. Warning at 80% is undelivered and the same completed refresh also qualifies for Bold. Deliver one payload.

```text
Included usage 84.0% · Warning

$16.80 of $20.00 · alert at 80%
+$0.90 since last refresh
```

### D01

Paid rises from $0.10 to $0.25 with a $1.00 cap. Its relative increase qualifies for Tier 2 although the $0.15 delta is below the absolute $0.30 trigger; no threshold alert.

```text
Paid spending increased

+$0.15 since last refresh
```

### D02

Paid +$0.30, Other 20.0% to 35.0%, Cursor 10.0% to 25.0%, and Included +$0.40 all independently qualify for Tier 2. No threshold alert. Omit Included under the three-row limit.

```text
Paid spending increased

+$0.30 since last refresh
Other Models: 20.0% → 35.0%
Cursor Models: 10.0% → 25.0%
```

### D03

Cursor 65.0% to 82.0% creates a pending Bold event. During authorization, a different observation revision supplies a Warning at 86.0%. Omit the old Bold event.

```text
Cursor Models 86.0% · Warning

Your warning level is 80%.
```

### A03

The app can no longer authenticate and transitions to a session-expired state. Preserve its existing independent delivery gate and reconnect destination.

```text
Cursor session expired

Reconnect to resume usage updates.
```

### No-message cases

- Usage alerts and jump effects both disabled: no usage banner, even if usage rises from 10.0% to 95.0%.
- First valid observation below every enabled threshold: establish the baseline without a usage banner.
- Split usage: first fresh observation after sleep, errors or another continuity break, below every enabled threshold: no recovered-interval Bold banner.

These cases do not disable independently eligible app-status events.

## References

[Apple notifications guidance](https://developer.apple.com/design/human-interface-guidelines/notifications/),
[Cursor image-file tools](https://cursor.com/docs/agent/overview).
