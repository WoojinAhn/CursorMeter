# Weekly Chart on Personal Accounts (#103) — Design

Date: 2026-07-24
Issue: https://github.com/WoojinAhn/CursorMeter/issues/103
Approach: A (membershipType branch) — approved 2026-07-24

## Problem

The weekly bar chart is gated on `membershipType == "enterprise"` plus a
discovered `teamId`/`userId`. On personal accounts (free/pro/etc.) the chart
silently disappears even though the backing endpoint works there.

## Verified API behavior (live, free account, 2026-07-24)

`POST /api/dashboard/get-filtered-usage-events` with body
`{"teamId": 0, "page": 1, "pageSize": N}` (no `userId`) returns 200 on a free
personal account. Events are already scoped to the requesting user and carry
`requestsCosts` (fractional, e.g. 1.1), `chargedCents`, `tokenUsage`, and
`kind: "USAGE_EVENT_KIND_CUSTOM_SUBSCRIPTION"` with
`customSubscriptionName: "free"`. `Origin: https://cursor.com` + bare host
requirements are unchanged.

Pro/Pro+ are unverified but assumed identical; scope decision below covers them.

## Scope decision

Personal path applies to **every non-enterprise membershipType** (including
`nil` from the legacy usage-only fallback). If the endpoint rejects a plan we
didn't verify, the existing failure handling hides the chart quietly — low
blast radius. (User-approved: "모든 비엔터프라이즈".)

## Design

### 1. API layer — `CursorAPIClient.fetchWeeklyUsage`

`userId: Int` → `userId: Int?`. When nil, omit the key from the JSON body
entirely (verified working). Enterprise call sites keep passing the resolved id.

### 2. ViewModel branch — `refreshWeeklyChart`

- `membershipType == "enterprise"` (case-insensitive, as today): existing team
  path untouched (resolveTeamId → fetchMyTeamMember → collect with real ids).
- Otherwise: call `collectWeeklyEvents(teamId: 0, userId: nil)` directly —
  skip the teams and roster fetches entirely (2 fewer round-trips).
- Failure semantics identical to today: keep previous `weeklyData` on transient
  failure, hide chart when there is none.

### 3. Availability flag rename

`isEnterpriseTeam` no longer describes the gate — rename to
`weeklyChartAvailable` ("a weekly fetch succeeded for this account"). Update the
three consumers:

- `MenuBarView` chart gate
- `SettingsAppearanceTabViewController` weekly-chart section visibility
  (now intentionally visible for personal accounts)
- `CursorMeterApp` observation-tracking read (must keep tracking the renamed
  property — silent-update rule in CLAUDE.md)

### 4. Optimistic parallel path

Personal accounts need no discovery, but the first refresh doesn't know the
membership type yet. Cache the established mode from the previous refresh:

```swift
enum WeeklyMode { case enterprise(teamId: Int, userId: Int), personal }
var cachedWeeklyMode: WeeklyMode?
```

`makeOptimisticWeeklyTask` fires when a mode is cached (enterprise uses cached
ids as today; personal uses teamId 0 / nil userId). `resetPerAccountState`
clears the cache (#54 account-switch leak rule). The existing separate
`cachedTeamId`/`cachedUserId` stay as-is for the hard-limit path; the weekly
mode cache is additive.

### 5. Display

No changes. Free is `isCreditBased == false` → tooltip shows integer weighted
units like request-quota plans. `USAGE_EVENT_KIND_CUSTOM_SUBSCRIPTION` is an
unknown kind → treated as plan day (existing intent). Fractional
`requestsCosts` already handled by `Double` summing + rounding in
`sevenDayRolling`. The `dailyRequestBudget` reference-line concern is moot —
that property is dead in production (tests only).

## Error handling

- Personal fetch non-200 / decode failure → same catch arms as today
  (`weeklyData` retained if present, `weeklyChartAvailable = false` when none).
- 403 clears enterprise caches today; personal path has no caches to clear but
  shares the same hide behavior.

## Testing

Existing MockURLProtocol + `UsageViewModel(apiClient:)` seams. New cases:

1. `fetchWeeklyUsage` with nil userId omits the key from the request body.
2. Non-enterprise membershipType → request goes out with `teamId: 0`,
   `weeklyChartAvailable == true` on success, chart data folded.
3. Personal-path failure with no prior data → chart hidden
   (`weeklyChartAvailable == false`).
4. Account switch → `cachedWeeklyMode` cleared (no cross-account optimistic
   fetch).
5. Rename: existing enterprise-path tests updated mechanically.

## Out of scope

- #104 notification body fix (separate issue).
- Verifying Pro/Pro+ live (covered by graceful failure).
- Chart unit/tooltip changes for free plans.
