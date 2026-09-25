# Issue 121 source evidence and synthetic wire contract

This records source verification completed before implementation. It contains no live
account amounts, identifiers, tokens, raw history, or private screenshots. Private
captures remain outside version control. All JSON values below are synthetic fixtures.
The shapes and field roles were checked against a personal Ultra dashboard and matching
API responses on 2026-09-25, including a complete active-cycle history traversal and a
repeat traversal with stable surrounding summary/period responses.

## Evidence boundaries

- The dashboard's Cursor Models percentage matched `individualUsage.plan.autoPercentUsed`
  in summary and `planUsage.autoPercentUsed` in current-period usage; Other Models matched
  their `apiPercentUsed` fields. This is observed mapping, not inference from field names.
- Summary and period cycle boundaries matched. Both period `includedSpend` and
  `totalSpend` matched summary plan used in the observed paid-disabled snapshot. Use
  `includedSpend` for included-total reconciliation; do not assume totalSpend remains
  interchangeable when paid or other billing states change. Raw fractional-cent
  included history excluding explicitly named Bot activity reconciled within one cent.
  That does not establish that every family event was debited from that named pool.
- Current-period `autoBucketModels` was populated but omitted some observed Cursor Grok
  families. Bounded correction is provisional, versioned and individually testable.
- Personal history body used `teamId:0`, omitted userId, 1-indexed pages of 100. No
  unverified server-side time filter is introduced.
- Paid `spendLimitUsage` detail was not validated; use summary onDemand for paid amounts.
- Free and enterprise pool semantics were not validated by the Ultra capture. Their
  existing behavior remains the compatibility baseline.

Additional primary context:
[Cursor models and pricing](https://cursor.com/docs/models-and-pricing),
[Cursor staff on API percentage calculations](https://forum.cursor.com/t/bug-report-dashboard-ui-percentages-frozen-due-to-totalpercentused-calculation-bug-in-get-current-period-usage-api/168210/7),
[Cursor staff on Bot and ordinary model usage](https://forum.cursor.com/t/can-cursor-clarify-exactly-which-grok-bot-usage-counts-against-the-weekly-pool-vs-cursor-models-other-models/170951/5).
These establish context, not a guaranteed public schema or fixed effective dollar cap.

## Synthetic summary

```json
{
  "billingCycleStart": "2026-09-01T00:00:00.000Z",
  "billingCycleEnd": "2026-10-01T00:00:00.000Z",
  "membershipType": "ultra",
  "individualUsage": {
    "plan": {
      "enabled": true, "used": 18200, "limit": 40000, "remaining": 21800,
      "autoPercentUsed": 10, "apiPercentUsed": 41, "totalPercentUsed": 15.166667
    },
    "onDemand": {"enabled": false, "used": 0, "limit": null, "remaining": null}
  }
}
```

`used/limit/remaining` are USD cents. `totalPercentUsed` is not the source of either
pool and may differ from `used/limit*100`. Only auto/api map to the two pool percentages.

## Synthetic current-period response

Request: POST `/api/dashboard/get-current-period-usage`, body `{}`, normal Cookie and
Content-Type headers, `Origin: https://cursor.com`. Optional personal enrichment only.

```json
{
  "billingCycleStart": "2026-09-01T00:00:00.000Z",
  "billingCycleEnd": "2026-10-01T00:00:00.000Z",
  "planUsage": {
    "totalSpend": 18200, "includedSpend": 18200,
    "remaining": 21800, "limit": 40000,
    "remainingBonus": false, "bonusTooltip": "",
    "autoPercentUsed": 10, "apiPercentUsed": 41, "totalPercentUsed": 15.166667
  },
  "spendLimitUsage": {"limitType": "none"},
  "autoBucketModels": ["composer-2.5", "cursor-grok-4.5", "default", "vega"]
}
```

Dates may contain fractional seconds; accept ISO-8601 with or without them. Compare
parsed instants exactly, not raw string formatting. An unavailable endpoint does not
invalidate the primary session or summary. Do not treat error bodies as empty metadata.

## Exact-money history and classification table

Decode monthly `chargedCents` JSON numbers directly as Decimal, not from a weekly Double.
Keep optional `isChargeable` as contradictory-evidence input, not a blanket zeroing rule.
A cost-bearing `isChargeable:false` row must be flagged rather than silently discarded.
Do not use `requestsCosts`, `tokenUsage.totalCents`, product IDs or `isHeadless` to infer
which model pool was charged. None was verified as a charged-pool identifier.

Normalize a model using ASCII lowercase and outer whitespace trimming only; do not
rewrite separators. Version-1 bounded correction matches full strings:

```text
^(?:cursor-)?grok-4\.(?:5|6|7)(?:-[a-z0-9]+)*$
^composer-2\.5(?:-[a-z0-9]+)*$
```

This includes observed version families and suffix grammar, not arbitrary future
versions. Reject `grok-4.8`, `composer-3`, `not-cursor-grok-4.7` and substring matches.
Recognize explicit `grok-bot-` before the server list or correction. Exact normalized
server membership (including opaque aliases such as default/vega) is stronger family
evidence than provisional corrections; neither is proof of charge routing. When the
server list is absent, bounded families may still be provisional family amounts, but
inferred pool limits are unavailable until coherent metadata is available.

Known third-party provider prefixes: `claude-`, `gpt-`, `gemini-` with a nonempty suffix.
They are family evidence only. Unrecognized aliases and bare provider names are Unknown.

Included allowlist initially: `USAGE_EVENT_KIND_INCLUDED_IN_ULTRA`,
`USAGE_EVENT_KIND_INCLUDED_IN_BUSINESS`, `USAGE_EVENT_KIND_FREE_CREDIT`.
Paid: `USAGE_EVENT_KIND_USAGE_BASED`.
Non-chargeable: `USAGE_EVENT_KIND_ERRORED_NOT_CHARGED` with absent/zero cost.
`USAGE_EVENT_KIND_CUSTOM_SUBSCRIPTION` with `customSubscriptionName:free` is observed in
Recent but not verified for monthly plan accounting: keep excluded/uncertain separately;
never silently absorb it into included. Any unknown cost-bearing kind blocks inference.

One-cent reconciliation tolerance is an app policy: **1.0 in cents**, or **0.01 in USD**.
For cents-valued Decimal totals, compare `abs(rawIncludedCents - Decimal(summaryUsed)) <= 1`.
Do not accidentally use `0.01` against cents-valued totals (100 times too strict).
