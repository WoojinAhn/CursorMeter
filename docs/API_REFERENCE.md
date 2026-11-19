# Cursor API — Reference

Internal reference for the (undocumented) Cursor API surface used by CursorMeter. Sources include the `cursor.com/dashboard` web client and official bundled Cursor IDE/CLI clients.

> **Status disclaimer**: every endpoint listed here is undocumented and not part of any public contract. Schemas, paths, query parameters, and authentication mechanics can change without notice. Treat as best-effort observation, not as a stable API.

## Authentication

- **Session credential** derived from the signed-in Cursor IDE, or a cookie captured by `LoginWindow` after web-based login (`https://www.cursor.com/dashboard`).
- The auth-bearing cookie is `WorkosCursorSessionToken` (current as of 2026-05). See `LoginWindow.requiredCookieNames`.
- Legacy `cursor.com` endpoints are GETs/POSTs with cookies attached. The shared-plan DashboardService methods below use the access JWT from the same selected credential as Bearer authorization, without a Cookie header.
- **Bearer-token Admin API** at `api.cursor.com/teams/*` is a separate surface (team admin only) and is **not used by this app**.

## Endpoints used by CursorMeter (production code)

### `GET /api/auth/me`

Authenticated profile for display name / email and account identity. The optional authenticated `sub` also binds recent-usage restoration to the same account when credentials rotate; no additional identity request is made. An IDE-only exception restores usage when this endpoint returns exactly HTTP 404 and the same credential/batch has a usable usage-summary; any primary unauthorized result still wins. This exception has no fresh subject authority, performs no new team/member discovery, and does not switch to a saved browser account. See [the #128 specification](superpowers/specs/2026-09-30-issue-128-profile-404-mitigation.md) for the measurement predicate and account/persistence boundaries. The 404's cause remains unverified.

Response (excerpt):
```json
{ "email": "...", "name": "...", "sub": "user_..." }
```

### `GET /api/usage-summary`
### `GET /api/usage-summary?teamId=<id>`

Plan-level summary (billing cycle, plan percentage, membership type, USD-cents counters when on a credit-based plan).

Response shape consumed by `UsageDisplayData.from(summary:)` (see `UsageModels.swift`):
- `billingCycleEnd: ISO-8601 string`
- `planUsedCents`, `planLimitCents` (Int) — present when the plan is credit-based
- `serverPercentUsed` (Double) — for percent-only plans
- `membershipType`, `isPercentOnly`, `isCreditBased`

The `teamId` variant is observed when an enterprise team is active. CursorMeter currently calls the un-suffixed form; this is sufficient on personal accounts. (Confirmed 2026-06: on a token-based enterprise member account the `?teamId=` response is byte-identical to the plain call.)

**Token-based enterprise contracts** (`/api/dashboard/teams` → `pricingStrategy: "tokens"`, `adminOnlyUsagePricing: true`) ship **no `plan` object** in `usage-summary`: spend is in `individualUsage.overall.used` (cents, `limit: null`) and the per-seat limit comes from `get-hard-limit` (see below). CursorMeter folds those into the credit-based display (`$used / $limit`, mirroring the dashboard). When the hard limit is unavailable (first refresh before `teamId` is cached, or non-usage-based plans) it falls back to parsing the percentage from `autoModelSelectedDisplayMessage` (e.g. `"You've used 0% of your included total usage"`) into `serverPercentUsed` → percent-only, instead of `0 / 0`. On-demand spend still comes from `teamUsage.onDemand`. See issue #71.

**Free plan** (observed 2026-07-24): `membershipType: "free"`, `plan: {enabled, used: 0, limit: 0, remaining: 0, breakdown: {included, bonus, total}, autoPercentUsed, apiPercentUsed, totalPercentUsed}`, `onDemand: {enabled: false, limit: null}`, `teamUsage: {}`. CursorMeter renders this via percent-only mode (`totalPercentUsed`). Note the dashboard message and the numeric fields can disagree (message "3%", `autoPercentUsed: 5`, `totalPercentUsed: 2.5`) — the app displays `totalPercentUsed`.

**Personal paid split quotas** (observed 2026-09-24/25; #121): summary `individualUsage.plan.autoPercentUsed` maps to **Cursor Models**, and `apiPercentUsed` to **Other Models**. These authoritative percentages are independent of the legacy `plan.used / plan.limit` monetary ratio. Missing/invalid optional percentages remain unavailable. Activate only with a positive plan limit, at least one valid pool field, and a successfully decoded current request-usage response without a request limit. Free, team/enterprise/business, overall-only, and known enterprise request scopes keep their legacy path. Empty `teamUsage: {}` is not a team signal.

`plan.used` and `plan.limit` are integer **USD cents**. The legacy limit is neither a per-pool inferred limit nor a sum of the split quotas. Included usage value is not additional spending. Separate summary on-demand `used`, `limit`, and `enabled` fields retain paid-budget meaning; no cap means no budget percentage. A latched split scope keeps its last dated snapshot on a summary failure instead of publishing a usage-only legacy fallback.

### `POST /api/dashboard/get-current-period-usage`

Optional personal enrichment, with `{}` and the existing Cookie/Origin headers. Consumed fields:

- Root `billingCycleStart`, `billingCycleEnd`: ISO-8601 dates, with or without fractional seconds, or decimal epoch-millisecond strings (observed 2026-10-06).
- `planUsage.includedSpend`: exact Decimal USD cents. Compare with summary `plan.used` within **one cent**; `totalSpend` is not an interchangeable fallback.
- At the legacy monetary cap, `includedSpend` can remain fixed while free `bonusSpend` increases. Complete non-Bot included history then reconciles against `planUsage.totalSpend`, but only with a verified included-plus-bonus breakdown, matching positive summary/period limits, the same cycle, and agreement of overlapping pool percentages. All three monetary fields and the limit participate in the collection's before/after source check. Missing or inconsistent evidence retains the summary-only check. Paid on-demand usage remains separate.
- `planUsage.autoPercentUsed`, `apiPercentUsed`: supplementary percentages only when cycles and included spend agree. Existing primary fields win.
- Root `autoBucketModels`: normalized exact model membership evidence. It is optional and does not guarantee a historical event's charged pool.

The endpoint is fetched during bounded cycle enrichment or a missing-field fill (at most once per minute). A coherent result may fill a missing pool field before history completes, only for its accepted primary revision. Identical canonical primary inputs may retain it for up to ten minutes with its original period source timestamp; changed inputs require validation again. Primary and period precision histories remain separate. Period-only fallback is display enrichment, not a source of threshold or jump events. It cannot overwrite newer primary measurements or replay consumption. Period/monthly 401/403/429/decode errors affect enrichment only and do not participate in the primary credential-expiry decision. Sanitized observed schemas and synthetic fixtures are in [the source contract](superpowers/specs/2026-09-26-issue-121-source-contract.md).

### `GET /api/usage?user=<sub>`

Per-model request counts for the current billing cycle. Dynamic-key payload — model names appear as top-level keys and CursorMeter parses with `Codable` dictionary handling (`UsageModels.swift`).

Response (excerpt):
```json
{
  "gpt-4o-mini": { "numRequests": 142, "maxRequestUsage": null, ... },
  "claude-sonnet-4": { "numRequests": 47, ... },
  ...
  "startOfMonth": "...",
  "globalRequests": 0
}
```

The `?user=<sub>` query parameter takes the `sub` returned by `/api/auth/me`.

### `POST /api/dashboard/teams`

Sole source of `teamId` for the analytics endpoints. Used by `CursorAPIClient.fetchTeams` to discover the active team once per session (cached afterwards). GET support was dropped server-side ~2026-07-18 (405) — requires POST with an empty JSON body and `Origin: https://cursor.com` like the other dashboard endpoints (#89). Response:

```json
{ "teams": [{ "id": 13403082, "name": "..." }] }
```

Empty / non-200 on personal plans; observed `{}` (no `teams` key) on a free account 2026-07-24. Personal accounts skip this endpoint entirely for the weekly chart (#103).

### `POST /api/dashboard/get-hard-limit`

Member-facing monthly spend limit for token-based enterprise contracts. **Requires `{"teamId": <id>}` in the body** — an empty body returns `{"noUsageBasedAllowed": true}` (all fields nil). Bare-host + `Origin: https://cursor.com` like the other dashboard POSTs.

```json
{ "hardLimit": 3000, "hardLimitPerUser": 200, "perUserMonthlyLimitDollars": 100 }
```

`perUserMonthlyLimitDollars` is in **whole dollars**; combined with `individualUsage.overall.used` (cents) it yields the dashboard's "Your monthly usage $0.17 / $100". `CursorAPIClient.fetchHardLimit` fetches it optimistically (parallel, gated on a prior-refresh `teamId`); `UsageDisplayData.from` folds it into the credit-based display. See issue #71.

### `POST /api/dashboard/get-filtered-usage-events`

Per-event usage stream. Used by the weekly bar graph (all account types). Returns events newest-first; pagination via `page` / `pageSize`.

Request:

- Method: `POST`
- Headers:
  - `Cookie: <session cookie header>`
  - `Origin: https://cursor.com` — **required.** Without it the server returns `{"error":"Invalid origin for state-changing request"}` with no events.
  - `Content-Type: application/json`
- Body: `{ "teamId": <int>, "userId": <int>, "page": <int, 1-indexed>, "pageSize": <int> }`
- **Personal accounts** (free verified live 2026-07-24; Ultra verified live 2026-09-10; Pro unverified): pass `teamId: 0` and omit `userId` entirely — events are scoped to the session cookie. Free events use `kind: "USAGE_EVENT_KIND_CUSTOM_SUBSCRIPTION"`, `customSubscriptionName: "free"`; Ultra events use `kind: "USAGE_EVENT_KIND_INCLUDED_IN_ULTRA"`, `isTokenBasedCall: true`. Both can carry fractional `requestsCosts` and `chargedCents`. Ultra included events remain plan activity, not on-demand charges.

Response shape (truncated):

```json
{
  "totalUsageEventsCount": 1397,
  "usageEventsDisplay": [
    {
      "timestamp": "1780402687672",
      "model": "composer-2.5-fast",
      "kind": "USAGE_EVENT_KIND_INCLUDED_IN_BUSINESS",
      "requestsCosts": 2,
      "usageBasedCosts": "-",
      "isTokenBasedCall": false,
      "tokenUsage": {
        "inputTokens": 3914,
        "outputTokens": 1390,
        "cacheReadTokens": 298176,
        "totalCents": 18.167999267578125
      },
      "owningUser": "232352588",
      "owningTeam": "13403082",
      "chargedCents": 8,
      "isChargeable": true
    }
  ]
}
```

Important shape notes:

- **`timestamp` is a string of UTC epoch milliseconds.** Validate it as finite before converting to `Date` using seconds (`milliseconds / 1000`). Recent usage skips invalid decoded timestamps without changing the existing structural decoding contract.
- **`requestsCosts` is the weighted billing unit** — light auto-complete calls weigh 1–2, Max-mode Opus calls can weigh 100+. Cursor's plan limit (e.g. 2000) is denominated in this same unit.
- **Events are returned newest-first by timestamp** within a page. Pagination walks backwards in time; stop when the oldest event in the latest page is older than your window or the collected count reaches `totalUsageEventsCount`.
- **Empty pages can omit `usageEventsDisplay`** (Ultra verified 2026-09-10). Weekly pagination treats this as an empty page even with a nonzero total, preserving #108 behavior after a successful first page. For the recent snapshot, a missing first-page array with a positive or absent total is ambiguous and keeps the previous snapshot. An explicit empty array, or a missing array with total zero, is a successful empty snapshot.
- `chargedCents` is a value in USD cents; divide by 100 for dollars. Included events represent plan-covered usage value, not additional charges. Ratio `chargedCents / requestsCosts` is usually 4 (= $0.04/unit) but some models (gpt-5.5-medium, claude-opus-4-7-high) use 2, and errored / non-chargeable events use 0.

### Shared weekly and recent consumers

`UsageEventCollection` supplies the weekly chart and Settings → Usage from the same request pipeline, even when the chart is hidden. Weekly pagination keeps its existing 100-event pages, five-page cap, and seven-day cutoff. Recent usage selects at most 30 valid rows from page one only, in descending timestamp order with API order preserved for ties. It has no seven-day cutoff and never fills from another page or maintains a local archive.

The first page’s receipt/decoding time becomes `cachedAt`; later pages, identity validation, restoration, formatting, and failures do not advance it. Later network/transient failures (including HTTP 408, 429, and 5xx) can preserve the validated first-page snapshot while the chart fails. Authentication, scope, and shape rejection—including later-page decoding failure—withhold the candidate. Existing enterprise rediscovery may supply a new validated first-page result.

The decoder accepts optional `model`, `kind`, and token components, including `cacheWriteTokens` when present; this is not a claim that every live payload contains them. Recent dollar values use only `chargedCents`, never token-price estimates, `tokenUsage.totalCents`, or `requestsCosts`. Missing optional values remain unavailable rather than becoming zero.

Opening Usage and switching Local/UTC only render saved state. Manual controls share the existing refresh entry, one in-flight operation, and a minimum three-second admission interval on each Mac. Existing periodic and local-activity scheduling remain active; there is no cross-device request deduplication.

### Independent cycle amounts consumer

Split-plan amounts use a separate exact-Decimal DTO and collector for the same filtered-events endpoint. Personal requests omit `userId`, use `teamId: 0`, and start at page 1 with 100 rows. A short page alone is not completion. Stable total, an explicit empty terminator, or crossing the cycle start can end traversal; order, overlap, head-page and summary/period rechecks still apply. Identical rows within a page are counted; exact overlap across pages makes attribution uncertain instead of silently dropping cost.

The combined traversal/retry budget is 100 pages, 10,000 received events, 16 MiB of decoded payloads and 60 seconds. Automatic attempts share 300 pages/hour per session and wait for a full 100-page allowance before starting; hourly exhaustion is temporary. Cancellation charges actual attempted pages once the collector reports them. Legacy cost collection retries complete results after at least 10 minutes and changed primary inputs; budget partials need explicit retry within the same cycle. Unstable, transport, endpoint and 429 results have distinct backoff; manual refresh cannot bypass Retry-After. Primary refresh never awaits collection.

For the popover's estimated today highlight, eligible demand keeps a 60-second start floor and, after automatic success, additionally waits `max(60, chargedHistoryPages * 3600 / 200)` seconds from completion (including verification/retry pages). This reserves room for a full 100-page attempt within the 300-page rolling hour instead of allowing successful scans to exhaust it in a short burst. The adaptive deadline applies only after a complete outcome; failure/early-retry behavior remains unchanged. Manual success cannot shorten an existing automatic deadline, and retired completions do not replace it. Scope reset clears this pacing but retains hourly charges and Retry-After. Histories composed only of paced automatic successes sustain admission even as costs vary; mixed failure/legacy charges, retired work and resets can still cause budget waits.

The demand identity includes the source summary, KST day, and current refresh's admitted history content revision (or an explicit per-refresh fallback when no revision is available). This reuses the weekly/recent response as a change signal, not as a complete cycle denominator. Only the newest pending demand is retained. Existing failure backoffs and automatic budgets still apply; states that cannot support an overlay retain legacy successful-cost cadence. Complete-but-unreconciled today demand remains an unstable failure even under that cadence, including when the source included total is missing. The existing two-equal-summary early retry rule can therefore increase collection frequency, within the automatic page budget. An explicit stopped-cost retry cannot fulfill today demand. See the [today-highlight contract](superpowers/specs/2026-10-02-issue-130-today-usage-highlight-design.md) and [original cycle-collection specification](superpowers/specs/2026-09-26-issue-121-split-usage-design.md).

Today's optional aggregate uses server event timestamps within `[KST midnight, next KST midnight)` and the billing cycle, with the same included-cost classification as the cycle total. The highlighted percentage points are `reported pool percentage × today included cost / cycle included cost`; they are an estimate, not a daily percentage from Cursor. Matched source values, validated coverage/attribution and current-session demand are required. Missing or inconsistent evidence withholds only the optional highlight; either pool at 100% or a positive percentage with zero family cost withholds both. Official total percentages and alert calculations are unchanged.

Classification version 2 applies explicit `grok-bot-` exclusion before normalized server membership, then bounded Grok 4.5/4.6/4.7 and Composer 2.5 family corrections. Every remaining nonblank model name is provisionally Other; missing or blank names remain unresolved. This does not classify unknown cost-bearing kinds as included. Bot, paid and unresolved amounts stay separate. Version-1 snapshots are discarded and recollected.

Reconcile included family totals with summary included cents, or with the validated included-plus-bonus receipt's total under the capped-bonus conditions described above. Preserve the one-cent tolerance; an unvalidated period `totalSpend` is not a fallback. Unresolved costs, contradictions, incomplete coverage and spillover suppress inferred limits. An unavailable or empty optional server catalog alone does not block estimates when the fallback classifier and all other checks pass; an unrecognized Cursor alias can still be provisionally misattributed to Other. Observed percentage precision is tracked separately per pool/source/scope; inferred limits require matching sources, at most 5% relative rounding uncertainty, and a percentage at least 0.1 and below 100. Do not use a fixed Ultra multiplier or $400 fallback.

## Endpoints observed (not yet used)

### `GET /api/v2/analytics/team/usage` (removed in v0.4.x)

Previously used for the weekly chart. Replaced by `POST /api/dashboard/get-filtered-usage-events` because:

1. The old endpoint omits days at cycle boundaries (observed: 5/30, 5/31, 6/1 missing from a known-active week).
2. The old endpoint exposes only request *counts*, not weighted billing units — a Max-mode Opus call and a light auto-complete both contribute 1.

Documented here only for archeology.

### `GET /api/v2/analytics/team/models`
### `GET /api/v2/analytics/team/models/aggregated`

Per-model usage. `timeseries` form is daily; `aggregated` is one row per model summed over the range. Useful for a "models" breakdown chart (#B).

### `GET /api/v2/analytics/team/composer`
### `GET /api/v2/analytics/team/tabs`
### `GET /api/v2/analytics/team/ai-commits/timeseries`
### `GET /api/v2/analytics/team/leaderboard`

Other observed analytics endpoints, all with the same `startDate=/endDate=/teamId=` shape. Not currently planned for use; documented here for reference.

### Dashboard POST endpoints

Many `/api/dashboard/*` POST endpoints exist (e.g. `get-team-spend`, `get-current-billing-cycle`, `get-hard-limit`, `get-credit-grants-balance`). Not currently planned for use; recorded for future spend/forecast features.

## Known limitations / open questions

- **Personal Pro/Pro+ weekly events** — `teamId: 0` verified on free and Ultra; Pro/Pro+ remain unverified. While logged in with the chart enabled, transient weekly fetch failures preserve cached data; two consecutive failures show the last successful update date and time. After a weekly fetch failure with no cached history available, a compact unavailable/retrying message is shown instead. Existing cache invalidation for rejected request shapes or access is unchanged.
- **Weekly/recent pagination** — the legacy event pipeline shared by the chart and recent list stops at the reported total, an empty page, or the 7-day cutoff, with a safety cap of 5 pages of 100 events. Histories exceeding that cap can be incomplete. Shared weekly billing does not reuse these legacy histories.
- **Stability** — all paths are undocumented. Any contributor changing the consumer code should re-verify the response shape against a fresh dashboard capture.
- **Rate limits** — server-side limits are undocumented. An ephemeral URLSession does not isolate account/server rate limits. The recent list adds no automatic requests to the existing weekly pipeline. Split cycle enrichment makes separately bounded requests, and all admission limits apply per Mac only.

## How to re-verify

1. Open `https://www.cursor.com/dashboard/analytics` in a browser logged in with the relevant account.
2. Open DevTools → Network → XHR filter.
3. Refresh the page; the endpoints under "Endpoints observed" above appear with response bodies viewable in the panel.
4. Update this file if names, query params, or schema have drifted.


## Shared weekly plans: existing Cursor authentication

For personal accounts on the merged weekly plan, CursorMeter keeps the same IDE
connection or saved Cursor browser session. It does not require a Grok login or
read Grok CLI credentials. The DashboardService path below was verified with the
same IDE access token used by the existing Cursor authentication path.

All methods are read-only POST requests under
`https://api2.cursor.sh/aiserver.v1.DashboardService/`, using JSON and
`Connect-Protocol-Version: 1`. Authorization is the Bearer JWT extracted from the
selected `WorkosCursorSessionToken`; the Cookie header is not sent to this host.
Redirects are refused. Personal requests omit team headers and team IDs.

| Method | Request | Meaning |
| --- | --- | --- |
| `GetPlanInfo` | `{}` | `isMerged` plus `planInfo.includedUsagePeriod` identifies the weekly regime |
| `GetCurrentPeriodUsage` | `{"personalScope":true}` | `planUsage.totalPercentUsed`, `billingCycleStart` and `billingCycleEnd` supply the weekly meter |
| `GetUserPrepaidBilling` | `{}` | Separate balance, funding/spending aggregates, optional monthly consumption and Auto Top-up, and limited top-up records |
| `GetHardLimit` | `{"personalScope":true}` | Monthly additional-usage cap; not the purchased-credit denominator |

The current-period cycle accepts the existing epoch-millisecond or ISO date
formats. Its end must agree with `planInfo.includedUsageResetsAt` before the
weekly reading is accepted. Auto/API monthly pool percentages are not substitutes
for the shared total. A known shared account with a failed supplemental request
must not fall back to displaying monthly percentages.

Each accepted snapshot belongs to the existing session generation, exact selected
credential and verified profile subject. The new reads support personal scope
only. A confirmed team transition clears the old personal wallet. A shared RPC
401/403 is a data failure, not authority to delete a valid primary credential or
retry another account. An exact-credential retained profile can preserve stale
readings during the existing IDE profile-404 fallback; it does not authorize a
fresh wallet request. Logout and account/credential changes discard late results.

The current individual subscription membership tokens are `plus`, `premium`,
`super`, and `unified_ultra`, in addition to the existing recognized personal
memberships. The installed official Cursor 3.30.14 membership enum and unified
tier set verify these exact strings (2026-11-18). In particular, `unified_ultra`
is distinct from legacy `ultra`, and `plus` is distinct from `pro_plus`.
The [official plan documentation](https://cursor.com/docs/models-and-pricing)
uses display names, which must not be substituted for these wire values.
`GetPlanInfo` still determines the billing regime; these tokens only establish
recognized personal scope. Team/business and unknown memberships remain excluded.
A live `premium` response exposed the original legacy-only allowlist defect;
the shared UI fixture now uses that current membership instead of `pro`.

Prepaid int64 fields use protobuf JSON decimal strings (or exact integer numbers).
Canonical Int64 strings retain exact source values; numeric JSON compatibility
is bounded by Foundation Decimal precision rather than an arbitrary-precision
JSON parser. Nonoptional proto3 scalar zero may be omitted only in a recognized eligible
prepaid response. Optional `spentThisMonthCents` remains unknown when absent.
`topUps` is bounded display history: the installed Cursor IDE requests `limit:1`.
Never use a truncated history sum as the total purchased amount. A purchased-credit
ratio requires valid aggregate arithmetic and purchase-record reconciliation;
unknown origins, grants, refunds, conflicting rows or incomplete coverage leave
the balance visible and the ratio unavailable. The raw consumer gRPC ledger uses
different amount signs and is not interchangeable with this JSON response.
Only `TOPUP_MANUAL` is currently verified for API2 purchase reconciliation.
`PrepaidTopUpEntry.origin` is a plain string in the installed schema; the separate
Grok ledger's automatic-purchase enum does not establish an API2 origin value.
Auto Top-up settings remain independently readable even when a purchase origin
cannot be recognized.

The official Cursor commerce bridge maps an explicit `noUsageBasedAllowed` or a
nonpositive `hardLimit` to a zero cap, the valid Int32 maximum 2147483647 to no cap,
and other valid Int32 values from whole dollars to cents. Missing/malformed values remain
unknown. `autoTopUp.monthlyCapCents` limits purchases and is not this consumption
cap. `GetMonthlyBillingCycle` was separately observed to describe the subscription
billing cycle; it must not be used as the calendar-month reset of
`spentThisMonthCents`.

A live tiny third-party request appeared in billing items with a sub-cent USD
`pricing.contracted` while integer-cent wallet/monthly fields remained unchanged.
These endpoints have different precision and update timing. Do not manufacture a
new wallet balance by subtracting event prices or claim the displayed rounded
row cost is the exact charge.

### Current shared activity and monthly period (#148)

Verified on 2026-11-19 using the existing IDE-derived Cursor session cookie and
the same authenticated primary profile. All three reads returned HTTP 200 at
`https://cursor.com`; redirects were refused. No extra login, inference, or
billing mutation was required. These are read-only dashboard queries even when
the HTTP method is POST.

| Method and path | Request | Relevant response |
| --- | --- | --- |
| GET `/api/dashboard/v2/usage-status` | `scope=user` | `availability`, `monthlyUsage.{usedCents,limitCents,additionalUsageOff,periodStart,resetsAt}` |
| GET `/api/dashboard/v2/query-billing-items` | `scope=user`, ISO `startTime`/`endTime`, `pageSize`, optional opaque `cursor` | `data[]`, `pagination.{hasMore,nextCursor}` |
| POST `/api/dashboard/v2/query-daily-usage` | `scope:"user"`, ISO `startTime`/`endTime`, `groupBy:["usageType"]`, `filters:{}`, `topN:20` | range, `series[]`, `other`, totals and daily `points[]` |

The official web source supplies these relative paths through its same-origin
JSON fetch wrapper. The observed Cursor host accepts the existing cookie; the
Grok-hosted dashboard uses its own `/dashboard` mount. Do not transfer Grok
cookies to Cursor or introduce a separate account binding for these queries.
The old `GetFilteredUsageEvents` RPC returned historical events but no events
for the recent seven-day window; HTTP success alone does not make that old
ledger a current shared-activity source.

Billing item `eventTime` is ISO8601 with an offset, not epoch milliseconds.
`pricing.contracted` is a decimal USD string (the official schema uses ten
fractional digits); convert with Decimal before formatting or converting to
cents. `totalTokens` is a string. Optional `product`, `hasTokenMeters` and model
metadata must remain optional. Do not retain principal IDs or email fields just
to render a recent row. `chargeCategory` distinguishes `usage`, `credit` and
`adjustment`; `usageType` distinguishes `included`, `on_demand`, `credits` and
`free`. The official label for `credits` is **Credit grants**, not purchased
prepaid credit. Negative prices can represent non-usage adjustments.

Daily points contain `dayStartTime`, decimal USD `contractedCost`, numeric
`tokens` and `includedTokens`. Current responses use **UTC-midnight buckets**,
including when the request start has a local timezone offset. A local date
label must not silently reinterpret those totals. For ranked grouped results,
the official cost chart selects `costRank <= topN` and adds `other.points`;
the token chart uses `tokenRank <= topN` and adds `other.points`. A combined union
of ranked series can double-count. Weighted legacy request units are not tokens.

`monthlyUsage.periodStart` and `resetsAt` are server-provided ISO dates for the
paid period. They are separate from weekly included resets and subscription
billing dates. `creditsUsedCents` is not evidence of a wallet decrement and must
not be subtracted from the prepaid balance. `identity_unlinked` and malformed
responses are unavailable data, not zero usage or primary authentication failure.

The installed official Cursor commerce bridge also clarifies Auto Top-up:
for an eligible prepaid response, an omitted `autoTopUp` maps to `null`, which
the UI renders as Off / Set Auto Top-Up. Apply that meaning only to a verified
eligible prepaid response; a failed or malformed read remains unavailable.

Source evidence: official dashboard
[`2lep6thelp200.js`](https://grok.com/dashboard/_next/static/immutable/chunks/2lep6thelp200.js)
and [`2x5blx2ii_ux0.js`](https://grok.com/dashboard/_next/static/immutable/chunks/2x5blx2ii_ux0.js),
inspected from the already authenticated browser's loaded public source; installed
Cursor `workbench.xai-commerce-prepaid.js` (`cursorSettingsFromReads` and
`CreditsCardView`). Only contract details are retained here, not live account data.

### Shared included-zero display (#148 follow-up)

Fresh current-account activity verified that `usageType: included` can carry
exactly zero `pricing.contracted`, even with nonzero tokens. This is reported
billing amount, not the retail value of included tokens. Keep zero distinct
from missing cost and do not infer a retail charge. The UI exposes precise
reported USD in hover/accessibility help while retaining compact visible values.

`displayExtras.displayLabel` is not a model identifier: current usage responses
can place the account display name there with no `model` field. Retain only the
explicit product/model context, not that label as a model fallback.
