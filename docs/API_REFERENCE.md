# Cursor API — Reference

Internal reference for the (undocumented) Cursor API surface used by CursorMeter. All endpoints are observed via the `cursor.com/dashboard` web client.

> **Status disclaimer**: every endpoint listed here is undocumented and not part of any public contract. Schemas, paths, query parameters, and authentication mechanics can change without notice. Treat as best-effort observation, not as a stable API.

## Authentication

- **Session cookie** captured by `LoginWindow` after web-based login (`https://www.cursor.com/dashboard`).
- The auth-bearing cookie is `WorkosCursorSessionToken` (current as of 2026-05). See `LoginWindow.requiredCookieNames`.
- All endpoints below are GETs/POSTs with cookies attached.
- **Bearer-token Admin API** at `api.cursor.com/teams/*` is a separate surface (team admin only) and is **not used by this app**.

## Endpoints used by CursorMeter (production code)

### `GET /api/auth/me`

User identity. Used to render display name / email and gate UI for logged-in state. The optional authenticated `sub` also binds recent-usage restoration to the same account when credentials rotate; no additional identity request is made.

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

- Root `billingCycleStart`, `billingCycleEnd`: ISO-8601 dates, with or without fractional seconds.
- `planUsage.includedSpend`: exact Decimal USD cents. Compare with summary `plan.used` within **one cent**; `totalSpend` is not an interchangeable fallback.
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

The combined traversal/retry budget is 100 pages, 10,000 received events, 16 MiB of decoded payloads and 60 seconds. Automatic attempts share 300 pages/hour per session and wait for a full 100-page allowance before starting; hourly exhaustion is temporary. Cancellation charges actual attempted pages once the collector reports them. Complete results retry after at least 10 minutes and changed primary inputs; budget partials need explicit retry within the same cycle. Unstable, transport, endpoint and 429 results have distinct backoff; manual refresh cannot bypass Retry-After. Primary refresh never awaits collection. See [the specification](superpowers/specs/2026-09-26-issue-121-split-usage-design.md) for exact policy.

Classification version 1 applies explicit `grok-bot-` exclusion before normalized server membership, then bounded Grok 4.5/4.6/4.7 and Composer 2.5 family corrections. Known Claude/GPT/Gemini families are Other; unfamiliar names or cost-bearing kinds remain unknown. Classification is provisional. Bot/paid/unknown amounts remain separate observed activity. Reconcile included family totals with summary included cents; unknowns, contradictions, missing metadata, incomplete coverage and spillover suppress inferred limits. Observed percentage precision is tracked separately per pool/source/scope; inferred limits require at most 5% relative rounding uncertainty, percentage at least 0.1 and below 100. Do not use a fixed Ultra multiplier or $400 fallback.

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

- **Personal Pro/Pro+ weekly events** — `teamId: 0` verified on free and Ultra; Pro/Pro+ remain unverified. Failure degrades to a hidden chart.
- **Weekly/recent pagination** — the shared weekly pipeline stops at the reported total, an empty page, or the 7-day cutoff, with a safety cap of 5 pages of 100 events. Histories exceeding that cap can be incomplete.
- **Stability** — all paths are undocumented. Any contributor changing the consumer code should re-verify the response shape against a fresh dashboard capture.
- **Rate limits** — server-side limits are undocumented. An ephemeral URLSession does not isolate account/server rate limits. The recent list adds no automatic requests to the existing weekly pipeline. Split cycle enrichment makes separately bounded requests, and all admission limits apply per Mac only.

## How to re-verify

1. Open `https://www.cursor.com/dashboard/analytics` in a browser logged in with the relevant account.
2. Open DevTools → Network → XHR filter.
3. Refresh the page; the endpoints under "Endpoints observed" above appear with response bodies viewable in the panel.
4. Update this file if names, query params, or schema have drifted.
