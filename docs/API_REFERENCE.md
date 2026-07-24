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

User identity. Used to render display name / email and gate UI for logged-in state.

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
- **Personal accounts** (free verified live 2026-07-24; pro assumed): pass `teamId: 0` and omit `userId` entirely — events are scoped to the session cookie. Observed personal-plan event fields: `kind: "USAGE_EVENT_KIND_CUSTOM_SUBSCRIPTION"`, `customSubscriptionName: "free"`, fractional `requestsCosts` (e.g. 1.1), numeric `owningUser` present in each event.

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

- **`timestamp` is a string of UTC epoch milliseconds.** Convert to `Date` via `TimeInterval(timestamp)! / 1000`.
- **`requestsCosts` is the weighted billing unit** — light auto-complete calls weigh 1–2, Max-mode Opus calls can weigh 100+. Cursor's plan limit (e.g. 2000) is denominated in this same unit.
- **Events are returned newest-first by timestamp** within a page. Pagination walks backwards in time; stop when the oldest event in the latest page is older than your window.
- `chargedCents` is the dollar charge for the event. Ratio `chargedCents / requestsCosts` is usually 4 (= $0.04/unit) but some models (gpt-5.5-medium, claude-opus-4-7-high) use 2, and errored / non-chargeable events use 0.

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

- **Personal Pro/Pro+ weekly events** — `teamId: 0` verified on free only; pro assumed identical. Failure degrades to a hidden chart.
- **Pagination** — none observed. All ranges return a single payload.
- **Stability** — all paths are undocumented. Any contributor changing the consumer code should re-verify the response shape against a fresh dashboard capture.
- **Rate limits** — not observed in normal dashboard use; the dashboard issues several dozen requests on load without throttling. The app's `URLSessionConfiguration.ephemeral` already isolates from any shared rate-limit state.

## How to re-verify

1. Open `https://www.cursor.com/dashboard/analytics` in a browser logged in with the relevant account.
2. Open DevTools → Network → XHR filter.
3. Refresh the page; the endpoints under "Endpoints observed" above appear with response bodies viewable in the panel.
4. Update this file if names, query params, or schema have drifted.
