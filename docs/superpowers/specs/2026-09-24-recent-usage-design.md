# Recent Usage and Shared Refresh Design

Date: 2026-09-24  
Status: Design approved in conversation; independent model review pending  
Baseline: `origin/main` at `303a11c`  
Implementation issue: Create after design review and before native code changes.

## Outcome and Boundaries

Add a compact Usage tab to Settings showing at most the latest 30 account usage
events. Reuse the event response already fetched for the weekly chart. Persist
one bounded snapshot so a restart can show saved data and its original timestamp.
The existing popover refresh arrow and the new Settings refresh button share
request coordination and a minimum three-second guard.

Cursor remains the source of truth for full history and billing. This is a recent
snapshot with an Open Cursor link, not a historical ledger. There is no load-more
control, date search, export, accumulated archive, or new polling loop. The list
limit is a product boundary; existing weekly retrieval still fetches more rows
when required for the chart.

Use Swift 6, AppKit, Observation, and macOS SDK frameworks only. Preserve existing
account support, authentication fallbacks, chart behavior, and refresh settings.
Do not redesign unrelated settings, notifications, updates, or billing logic.

## Evidence and Existing Integration

- `UsageViewModel.refresh()` fetches the summary, request counts, and user info,
  and also retrieves weekly events. A running refresh currently drops another
  refresh through `isRefreshing`; it has no three-second manual guard.
- `CursorAPIClient.fetchWeeklyUsage` calls
  `POST /api/dashboard/get-filtered-usage-events`. Personal requests use
  `teamId: 0` and omit `userId`; team requests include resolved team and user IDs.
- The collector requests 100 rows per page, up to five pages, newest first, with
  the existing seven-day stopping rule. Turning off the weekly chart only hides
  the chart; it currently does not disable these requests.
- The default periodic interval is five minutes. Cursor activity uses a local
  file-change signal, a five-second debounce, and a 60-second activity throttle.
  The signal does not contain usage data and does not observe other computers.
- A read-only live check confirmed that included events can still contain
  `model`, `tokenUsage`, and numeric `chargedCents` even when the dashboard shows
  Included instead of a dollar amount. This is an observed undocumented schema,
  not a guarantee that the fields remain available.
- The current weekly collector throws away a successful first page if a later
  page fails. Its optimistic path also starts before account verification, so
  first-page publication must use the same account validation as other results.

References: `docs/API_REFERENCE.md`, `Sources/CursorMeter/UsageViewModel.swift`,
`WeeklyUsageModels.swift`, `CursorAPIClient.swift`, and `CursorActivityWatcher.swift`.

## Settings and Display Contract

Add Usage after General, Alerts, and Display. Use the selected compact layout:
model on the first line, event date/time and type below it, and right-aligned
tokens and USD amount. Show six or more rows in a vertically scrolling region
at the selected approximately 480-point Settings width. Other tabs retain their
existing preferred sizes. Do not add horizontal scrolling to the list.

The header contains Recent usage, the saved snapshot date/time, and Refresh.
The footer contains the displayed row count, a Local/UTC segmented control,
and a link to `https://www.cursor.com/dashboard?tab=usage`. Include the caption
"Included amounts show usage value covered by your plan."

| Field | Rule |
| --- | --- |
| Order and limit | Newest first; at most 30 rows; stable API order for equal timestamps |
| Model | Server model name; truncate visually with the full name accessible; missing value is an em dash |
| Type | Included for included kinds, On-demand for usage-based kinds, Free when explicitly identified, otherwise Other |
| Tokens | Sum valid input, output, cache-read, and cache-write counts; missing optional cache counters mean zero; missing input/output or invalid counters mean unavailable |
| Token format | Below 1,000 use an integer; K uses up to one decimal; M uses up to two; remove trailing zeros; expose the exact total through accessibility/help |
| Amount source | `chargedCents / 100`, preserving the numeric value; do not silently substitute `tokenUsage.totalCents` or a pricing estimate |
| Amount format | Two decimals for values at least $0.01; four for positive values below $0.01; zero is $0.00 |
| Tiny/missing amounts | Positive values below $0.0001 display `<$0.0001`; absent, non-finite, or unsupported negative values display an em dash |
| Included semantics | An included amount is a server-reported usage value covered by the plan, not an extra charge |

The Local/UTC control defaults to Local and remembers the selected mode on this
Mac. Local follows the system time zone, including changes while the app runs.
Apply the selection to both event timestamps and the snapshot timestamp. Store
absolute instants, never preformatted strings. A mode change only reformats the
snapshot: it neither contacts Cursor nor updates the saved timestamp or ordering.
Show the active time-zone abbreviation/offset compactly; expose its full identifier
in help. Event dates may omit the year for the current year; snapshot dates include
the year so an old restored snapshot cannot appear to have been saved today.

The approved visual companion is currently the ignored local file
`.superpowers/brainstorm/39880-1790173474/content/display-rules-v9.html`.
It illustrates the approved layout, price formatting, time-zone control, and
1.3-second rotation. Its fixed examples are simulated. The written error,
authentication, and timing contracts here govern implementation. After issue
creation, copy the approved before/after design to `docs/mockup-<issue>.html` and
include missing/error states needed for native verification.

## One Existing Request Pipeline

1. Keep the existing session-start, periodic, activity, and manual refresh
   triggers. Opening or reselecting Usage reads state only.
2. Extend the existing event decoder with the optional fields required by the
   list. Do not request a second event page for the purpose of populating the list.
3. Preserve a bounded first-page result alongside the weekly aggregation result.
   On successful collection, both consumers update. If page one succeeds and a
   later weekly page fails, the recent snapshot may update while the chart keeps
   its existing stale/error behavior. If page one fails, preserve the old list.
4. Return both outcomes when the collection attempt ends; an eager callback that
   writes a snapshot before the refresh validates its account is not required.
5. Validate the current session generation and resolved account/team scope before
   publishing either result or scheduling persistence. Discard invalidated
   optimistic results and results from a prior login, logout, or account switch.

Take up to 30 valid events from the first page without the weekly date filter:
the latest event may legitimately be older than seven days. Do not deduplicate
different events merely because timestamp, model, and amount happen to match.
Skip rows whose timestamp cannot be interpreted; if a nonempty page contains no
usable rows, report unavailable data and retain the prior snapshot, not a
successful empty history. A documented empty response with the event count but
no event array is a valid empty page. An unsupported/malformed response such as
`noUsageBasedAllowed` is unavailable, not a successful empty snapshot.

This adds zero automatic Cursor requests relative to the existing refresh
pipeline. Existing 100-row weekly pages and the five-page cap remain unchanged.
Manual Refresh initiates the same app refresh, subject to the shared guard; it
does not bypass caching by creating a list-specific client or request path.

## Persistent Snapshot and Account Boundaries

Persist one versioned file in the app's per-user Application Support directory,
containing at most 30 display events, their account/team scope, and `cachedAt`.
Replace it atomically after a valid successful first-page result, including a
valid empty result. Do not accumulate files per refresh or retain historical
snapshots. Store only required model/type/token/amount/timestamp data; exclude
conversation IDs, user names, email text, raw API responses, and credentials.
Use owner-only file permissions and background I/O. Preserve current data in
memory if a write fails; log the persistence failure without event contents.

`cachedAt` records when the valid first-page response was fully received and
decoded. Carry that time with the candidate snapshot; publishing after account
validation or later-page collection must not advance it. Restoring, rendering,
reformatting, a failed refresh, or a failed write never invents a new successful
retrieval time. Persist the timestamp and events together.

The existing `.loggedIn` state is insufficient proof of account identity: it is
set before the initial network authentication completes. Apply these rules:

- Bind a successfully saved snapshot to the effective credential that actually
  authenticated the refresh, using a SHA-256 digest for equality only. Never
  persist or log the credential. Bind the snapshot separately to the resolved
  authenticated account subject and personal/team scope (team ID and numeric
  user ID when relevant); store account selectors as opaque digests.
- On restart, after the existing credential resolution selects a source, an
  exact match to the previously successful credential binding permits immediate
  display of that saved snapshot as cached data in its last known scope. Do not
  present it as a freshly authenticated or up-to-date response.
- If the credential has rotated, hold the saved snapshot privately until the
  existing requests verify the same stable account subject and resolved scope.
  A credential-derived subject is a cache selector, not proof of authentication.
  If a stable subject cannot be established, only the exact prior credential
  binding can enable early restore; otherwise wait for fresh event data.
- If a new account or scope is established, discard the prior snapshot. A valid
  snapshot under an unchanged binding can still be shown offline, with its saved
  timestamp and update failure. On explicit logout, session expiry, or account
  change, clear displayed and persisted usage data.
- Increment a session generation on authentication boundaries. Delayed network
  completions and disk writes must compare it and their scope before committing.
  Serialize store writes/removal so a pending old write cannot recreate a file
  after logout. A new login's initial refresh is not blocked by an old cooldown.
- Corrupt or unsupported cache versions become a cache miss; the existing initial
  refresh repopulates them. Do not add a cache-repair network request or prompt.

The early-restore check trades some cache hits for account isolation: a rotated
credential may require identity validation before saved rows can be displayed.
It does not add authentication calls; it uses the existing chain. Do not expand
the app's authentication permissions or read Cursor refresh tokens.

## Shared Refresh and Feedback

Coordinate refresh at the common app entry, not in either button's action.
Only one refresh attempt may run for the active session. A normal request that
arrives while another is active reuses the observed in-flight state and causes
no additional requests or trailing queued replay. Both manual surfaces share
the same minimum three-second admission window measured from an accepted start
using a monotonic clock. Recent automatic starts also guard immediate manual
duplicates. Normal automatic triggers inside that window do not start another
attempt; their existing scheduling remains the fallback.

The three-second guard is not a polling interval. Preserve the longer activity
throttle. Internal IDE-to-cookie authentication fallback belongs to one admitted
refresh and does not pass through the guard again. Explicit reconnect/login
invalidates the previous session and its guard; its required initial refresh
must run after obsolete work is cancelled/retired, not be dropped as a duplicate.

Use one observed feedback timeline for visible refresh controls:

- Apply validated data as soon as it is available; do not delay network work,
  decoding, or data publication to make an animation last longer.
- Show the rotation/Updating phase until both the request attempt has ended and
  at least 1.3 seconds have elapsed since its start.
- Then show that surface's result for at least 0.65 seconds. In the normal fast
  case the success check fills the remaining guard, producing approximately
  1.3 seconds of rotation and 1.7 seconds of check before readiness at 3 seconds.
- Readiness is the latest of start + 3 seconds, request completion, and the end
  of the minimum feedback interval. A 4.2-second request therefore remains
  protected through completion and its short result indication.
- Never show a success check for data that failed to update. The popover result
  represents its primary meter; the Usage tab result represents the recent
  snapshot. Their outcomes may differ while admission and busy state stay shared.
  Existing weekly-chart freshness/error presentation remains independent.
- Opening another surface midway through an attempt or cooldown observes the
  existing deadline instead of restarting it. A late animation callback must not
  reset feedback belonging to a newer refresh or account generation.
- Keep button widths fixed, use no countdown or repeated-click toast, and do not
  replace a displayed list with a loading skeleton during ordinary refreshes.
  Respect Reduce Motion with a nonrotating in-progress indicator and accessible
  status text. A successful HTTP response is not sufficient if its payload is
  unavailable or cannot be associated with the current account.

## Data and Failure States

| State | Presentation and behavior |
| --- | --- |
| Initial fetch, no eligible cache | Loading placeholder; no fabricated rows, zero amount, or cache time |
| Eligible saved snapshot | Display immediately with its original cache date/time; existing initial refresh continues |
| Refresh with existing rows | Keep rows and cache time visible while controls show progress |
| Successful empty page | Empty message, zero displayed rows, and a newly accepted snapshot timestamp |
| Failure with snapshot | Keep rows and original time; show a compact update-failed message; no success check in Usage |
| Failure without snapshot | Unable-to-load message; preserve the normal refresh control for a later attempt |
| Missing optional fields | Keep the row and show unavailable values as an em dash; do not estimate |
| Only meter or only list succeeds | Publish the successful consumer and preserve the other's snapshot/error state |
| Later weekly page fails | Publish a validated first-page recent snapshot; preserve weekly stale/error behavior |
| Logout/account change | Clear old rows and pending feedback; reject old-generation results and persistence |

Errors do not create an additional retry loop. Existing automatic scheduling and
an eligible user refresh provide retries. Do not mislabel a saved list's time as
the successful meter refresh time.

## Multiple Devices

The source is Cursor's account-scoped event response. Each Mac keeps its own
bounded cache, refresh schedule, and guard. Local file activity is only an early
refresh trigger; interval refresh remains active without local activity so usage
from another device can become visible. No device-to-device synchronization or
cross-device request deduplication is claimed. Server reporting delay and actual
two-device propagation latency have not been measured; this is not realtime.

## Implementation Responsibilities

| Area | Responsibility |
| --- | --- |
| `WeeklyUsageModels.swift` and recent-usage display models | Decode optional event fields; preserve existing aggregation; define bounded snapshot and formatting |
| Recent-usage snapshot store | Versioned atomic persistence, account binding, serialized invalidation, injectable file location |
| Shared refresh timing helper | Monotonic admission/feedback deadlines and deterministic test clock; no independent polling |
| `UsageViewModel.swift` | Wire both consumers to existing retrieval, validate session/scope, expose observable state and actions |
| `SettingsUsageTabViewController.swift` | Native compact list, states, timestamps, Local/UTC selector, Refresh, and dashboard link |
| `SettingsTabViewController.swift` and `CursorMeterApp.swift` | Register tab, preferred-size changes, observation re-arming for all new visible state |
| `MenuBarView.swift` | Route existing arrow through shared state and render its truthful meter outcome |

Keep new persistence, formatting, and timing logic in focused files rather than
growing the already large view model with unrelated utilities. Use the existing
injection conventions and retain existing tests. No general networking rewrite
or independent synchronization service is required.

## Acceptance and Verification

Select tests before implementation and add logic and integration tests with the
feature. Tests must use MockURLProtocol, temporary directories, injected clocks,
and existing notification/keychain seams. Never use real credentials, the real
Keychain, live Cursor requests, or UNUserNotificationCenter in the test host.

1. Opening/reopening Usage or changing Local/UTC issues zero HTTP requests.
2. One admitted existing refresh updates both event consumers with no duplicate
   first-page request. The disabled weekly-chart setting does not break the list.
3. More than 30 returned events produce 30 rows and 30 persisted events. Events
   older than seven days still appear when they are the latest available events.
4. First-page failure retains the list; later-page failure preserves a valid
   first-page snapshot and the chart's established failure semantics.
5. Empty, unavailable, malformed, missing-field, and invalid-timestamp responses
   are distinguished. Known tiny/zero/missing amounts format as specified.
6. Local/UTC conversions preserve absolute instants, order, and cache time, with
   a date-boundary example and a daylight-saving/system-time-zone change case.
7. Restoration retains the original timestamp. Mismatched credential/account/
   team scope does not disclose the previous snapshot; rotated credentials use
   verified identity before reuse. Corrupt cache and write failure remain usable.
8. Logout/relogin while network or disk work is in flight cannot publish or
   recreate the old account's data, and a login within three seconds still runs.
9. Rapid repeated clicks, alternating buttons, and overlapping automatic/manual
   triggers result in one admitted request and no queued burst.
10. Fast and slow success, failure, and partial success have the specified 1.3/3
    second timing, truthful per-surface results, and no stale timer callbacks.
11. Run the full `swift test` suite and relevant build checks. CI currently tests
    both `macos-15` and `macos-15-intel`; check CI after pushing changes to a
    triggering branch/PR, since ordinary feature pushes do not run Test.
12. Verify the native Usage tab and existing arrow with accessibility-based UI
    actions/screenshots; browser screenshots verify only the HTML mockup. Check
    dark/light appearance, scrolling, long model names, Reduce Motion, initial,
    cached, empty, failed, and partial-success states without exposing real PII.
13. Update applicable README/README.ko and SECURITY/SECURITY.ko pairs together,
    API documentation for added decoding behavior, and affected screenshots.

## Review and Delivery

The user authorized autonomous design choices, issue creation after spec review,
implementation, and independent Cursor reviews at important checkpoints using
the latest available Grok, Muse, and Opus 5.5. No further routine selection or
implementation approval is needed. Release/deployment is outside this task.

Run independent specification reviews using `grok-4.7-xhigh`,
`muse-spark-1.3-max`, and `claude-opus-5-5-max`, resolved from the live account
roster. Reconcile findings against code and the agreed requirements, revise this
document, and then create the feature issue. Keep private review prompts/results
and strategic discussion in ignored local notes; the public issue contains the
actionable design, acceptance criteria, and implementation scope.

Next create the Superpowers implementation plan, implement with test-first
checkpoints, and use the same three models for the critical data/refresh/cache
integration and the final implementation review. Coordinator ownership applies
to the spec, README pairs, central registration files, and shared state changes.
Finish with appropriate tests, native UI evidence, atomic commits, CI inspection,
and issue status. Do not publish a release or deploy an app automatically.
