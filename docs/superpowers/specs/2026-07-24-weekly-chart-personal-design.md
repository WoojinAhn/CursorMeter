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

Personal path applies to **every non-nil, non-enterprise membershipType**.
`nil` is excluded (Codex review 2026-07-24): a nil membershipType comes from
the legacy usage-only fallback — i.e. `fetchUsageSummary` *failed*, which says
nothing about the plan. Routing it to `teamId: 0` could send an enterprise
account (during a transient summary outage) down the personal path. nil keeps
today's behavior: chart hidden.

If the endpoint rejects a plan we didn't verify (Pro/Pro+), the existing
failure handling hides the chart quietly — low blast radius. Unknown future
membershipType values take the personal path by design (user-approved: "모든
비엔터프라이즈"); worst case is today's status quo (no chart).

## Design

### 1. API layer — `CursorAPIClient.fetchWeeklyUsage`

`userId: Int` → `userId: Int?`. When nil, omit the key from the JSON body
entirely (verified working). Enterprise call sites keep passing the resolved id.

### 2. ViewModel branch — `refreshWeeklyChart`

Three-way on `membershipType`:

- `"enterprise"` (case-insensitive, as today): existing team path untouched
  (resolveTeamId → fetchMyTeamMember → collect with real ids).
- `nil`: hide chart (today's behavior — see Scope decision).
- Any other value: call `collectWeeklyEvents(teamId: 0, userId: nil)` directly —
  skip the teams and roster fetches entirely (2 fewer round-trips).

`collectWeeklyEvents` and `fetchWeeklyUsage` both change signature to
`userId: Int?`, threaded through the paginator; existing enterprise tests
update mechanically.

Failure semantics identical to today and pinned by test: transient failure
keeps previous `weeklyData` (stale chart stays visible, availability flag
stays true); failure with no prior data hides the chart. A 403 clears
`cachedWeeklyMode` (alongside the existing enterprise cache clears) so the
next refresh re-discovers the mode.

### 3. Availability flag rename

`isEnterpriseTeam` no longer describes the gate — rename to
`weeklyChartAvailable` ("a weekly fetch succeeded for this account"). Update the
three consumers:

- `MenuBarView` chart gate
- `SettingsAppearanceTabViewController` weekly-chart section visibility
  (now intentionally visible for personal accounts). Semantics unchanged from
  today: the section appears only after a weekly fetch has succeeded, so it is
  briefly hidden between launch and first success — pre-existing behavior,
  documented, not a regression.
- `CursorMeterApp.observePopover` tracking read (must keep tracking the renamed
  property — silent-update rule in CLAUDE.md)
- `CursorMeterApp.observeSettings` currently tracks only `activeAuthSource`, so
  an open Settings window never reacts when availability flips (Codex review).
  Add `_ = viewModel.weeklyChartAvailable` to its tracking block.

### 4. Optimistic parallel path

Personal accounts need no discovery, but the first refresh doesn't know the
membership type yet. Cache the established mode from the previous refresh:

```swift
enum WeeklyMode { case enterprise(teamId: Int, userId: Int), personal }
var cachedWeeklyMode: WeeklyMode?
```

`makeOptimisticWeeklyTask` fires when a mode is cached (enterprise uses cached
ids as today; personal uses teamId 0 / nil userId).

**Invalidation points** (all explicit — Codex review caught that `logout()`
clears caches directly instead of via `resetPerAccountState`):

- `resetPerAccountState()` (account switch, #54)
- `logout()` (direct clear, alongside `cachedTeamId`/`cachedUserId`)
- 403 catch arm in the weekly fetch

The existing `cachedTeamId`/`cachedUserId` stay as-is for the hard-limit path;
the weekly mode cache is additive but follows the same invalidation lifecycle.

Known pre-existing limitation (unchanged by this design): when `/api/auth/me`
returns a nil email, account-switch detection does not fire and a stale cached
mode can produce one wasted (discarded) optimistic call — identical exposure to
today's enterprise optimistic path.

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
- 403 clears enterprise caches today; the personal path clears
  `cachedWeeklyMode` in the same arm and shares the hide behavior.

## Testing

Existing MockURLProtocol + `UsageViewModel(apiClient:)` seams. New cases:

1. `fetchWeeklyUsage` with nil userId omits the key from the request body.
2. Non-enterprise membershipType (e.g. "free") → request goes out with
   `teamId: 0`, `weeklyChartAvailable == true` on success, chart data folded,
   and **neither** `/api/dashboard/teams` **nor** `get-team-spend` is ever
   requested (assert on the MockURLProtocol URL sequence).
3. `nil` membershipType (summary failure + usage success legacy fallback) →
   no weekly request at all, chart hidden.
4. Personal-path failure with no prior data → chart hidden
   (`weeklyChartAvailable == false`).
5. Personal-path transient failure with prior data → stale `weeklyData`
   retained and availability stays true (pins today's catch semantics across
   the rename).
6. Account switch → `cachedWeeklyMode` cleared (no cross-account optimistic
   fetch). Logout → `cachedWeeklyMode` cleared.
7. Rename: existing enterprise-path tests updated mechanically.

Manual verification (not unit-testable — `withObservationTracking` blocks live
in the app process): after reinstall, confirm via AX path that the popover
chart appears on the personal account and that an open Settings window shows
the weekly-chart section after the first successful refresh.

## Out of scope

- #104 notification body fix (separate issue).
- Verifying Pro/Pro+ live (covered by graceful failure).
- Chart unit/tooltip changes for free plans.
