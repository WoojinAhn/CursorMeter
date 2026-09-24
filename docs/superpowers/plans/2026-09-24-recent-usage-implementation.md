# Recent Usage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver issue [#118](https://github.com/WoojinAhn/CursorMeter/issues/118): a bounded, persistent recent-usage list and shared refresh feedback without additional automatic Cursor requests.

**Architecture:** Extend the existing event stream, carrying a first-page candidate independently of weekly aggregation. Keep display formatting, cache ownership/persistence, and refresh timing in focused types; integrate them through the existing MainActor view model. AppKit views render shared state and do not own refresh scheduling.

**Tech Stack:** Swift 6, AppKit, Observation, Foundation, CryptoKit, XCTest, macOS 14; no external dependencies.

---

## Authority, Workspace, and Verification

The finalized contract is `docs/superpowers/specs/2026-09-24-recent-usage-design.md`.
The approved visual is `docs/mockup-118.html`. The user authorized autonomous
execution, ordinary issue/commit/push work, and three-model reviews at integration
and final checkpoints. Release and deployment remain outside scope.

Work in the isolated `feature/recent-usage` checkout. Preserve the original
checkout's uncommitted files. The coordinator owns shared state/registration
files (`UsageViewModel.swift`, `CursorMeterApp.swift`, `SettingsTabViewController.swift`),
README/SECURITY pairs, API docs, and this plan. Only one implementation worker
edits code at a time. Review spec compliance before code quality at each task.

Baseline code is origin/main `303a11c`; design commits are `55aed8b` and `36a1737`.
Unmodified source builds with installed CLT Swift 6.2.4. Installed Xcode 27 Swift
6.4 rejects the existing `nonisolated AppDelegate.main`; a disposable validation
mirror removing that single keyword passed all 493 baseline tests. That shim is
not a production change. `.Codex/bin/test-swift.py` recreates the local mirror,
applies exactly that shim, and forwards arguments to `swift test --build-system native`.
CI must test the unmodified source before completion. Keep this environmental
limitation distinct from feature failures.

Local commands, verified against installed help:

```bash
python3 .Codex/bin/test-swift.py --filter RecentUsageModelsTests
python3 .Codex/bin/test-swift.py
DEVELOPER_DIR=/Library/Developer/CommandLineTools SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.2.sdk /Library/Developer/CommandLineTools/usr/bin/swift build --scratch-path .Codex/build-swift62 --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.2.sdk
```

## File Boundaries and Interfaces

| File | Responsibility |
| --- | --- |
| `WeeklyUsageModels.swift` | Tolerant new list fields and whether the API supplied its event array; existing chart fields retain their contracts |
| `RecentUsageModels.swift` | `RecentUsageEntry`, `RecentUsageCandidate`, type mapping and the 30-row boundary |
| `RecentUsageFormatter.swift` | USD, exact/compact tokens, Local/UTC and dates |
| `RecentUsageStore.swift` | Versioned bounded file, equality binding, atomic writes, operation ordering |
| `RecentUsageController.swift` | MainActor snapshot/held-cache lifecycle, persisted validity token, no scheduling or networking |
| `RefreshFeedback.swift` | Pure deadline arithmetic and observed admission/phase ownership |
| `UsageEventCollection.swift` | First-page candidate plus independent weekly Result; existing pagination |
| `UsageViewModel.swift` | Session/attempt guards, existing credential and request pipeline, outcomes |
| `RefreshFeedbackButton.swift` | Shared AppKit presentation, Core Animation rotation, Reduce Motion |
| `SettingsUsageTabViewController.swift` | Fixed-size list, status, cache time, Local/UTC, dashboard link |
| Existing AppKit registration files | Tab registration, observation, production store injection |

Use these display value signatures across tasks:

```swift
enum RecentUsageKind: String, Codable, Sendable {
    case included, onDemand, free, other
}

struct RecentUsageEntry: Codable, Equatable, Sendable {
    let date: Date
    let model: String?
    let kind: RecentUsageKind
    let tokens: Int?
    let chargedCents: Double?
}

struct RecentUsageCandidate: Codable, Equatable, Sendable {
    static let limit = 30
    let entries: [RecentUsageEntry]
    let cachedAt: Date
}

enum RecentUsageTimeZone: String, Codable, CaseIterable, Sendable {
    case local, utc
}
```

Candidates are built only through a failable initializer
`init?(response: FilteredUsageEventsResponse, cachedAt: Date)`. Direct entry-array
construction, used for fixtures and file decoding, must still enforce the limit
at the persistence boundary. Missing optional values remain nil, never estimates.

## Task 1: Decode and Format Bounded Recent Events

**Files:** create `Sources/CursorMeter/RecentUsageModels.swift`,
`Sources/CursorMeter/RecentUsageFormatter.swift`, and
`Tests/CursorMeterTests/RecentUsageModelsTests.swift`; modify
`Sources/CursorMeter/WeeklyUsageModels.swift` only for required decoding metadata.

- [x] Write failing XCTest cases for count/ordering, malformed optional fields,
  first-page empty ambiguity, type mapping, tokens, money, and timezone boundaries.
  Start with a fixture that proves the new metadata does not break weekly decoding:

```swift
func testOptionalListFieldsDoNotBreakWeeklyDecoding() throws {
    let data = Data("""
    {"totalUsageEventsCount":1,"usageEventsDisplay":[{
      "timestamp":"1780402687672","requestsCosts":2,"chargedCents":8,
      "model":{"unexpected":true},"tokenUsage":"unavailable"}]}
    """.utf8)
    let response = try JSONDecoder().decode(FilteredUsageEventsResponse.self, from: data)
    let candidate = try XCTUnwrap(RecentUsageCandidate(response: response, cachedAt: .distantPast))
    XCTAssertEqual(candidate.entries.count, 1)
    XCTAssertNil(candidate.entries[0].model)
    XCTAssertNil(candidate.entries[0].tokens)
    XCTAssertEqual(response.usageEventsDisplay[0].requestsCosts, 2)
}
```

- [x] Run `python3 .Codex/bin/test-swift.py --filter RecentUsageModelsTests` and
  record the expected missing-type/behavior failure before adding production code.
- [x] Implement tolerant list-only decoding. Accept integral numeric strings and
  integer JSON counters; invalid optional cache counters make the total unknown.
  Require input/output; absent/null cache counters are zero. Sum with
  `addingReportingOverflow`, rejecting negative values. Preserve required String
  timestamp decoding and the existing required chart-field error behavior.
- [x] Implement candidate selection with indexed stable sorting and `prefix(30)`:

```swift
let sorted = response.usageEventsDisplay.enumerated().compactMap { index, event in
    RecentUsageEntry(event: event).map { (index, $0) }
}.sorted { lhs, rhs in
    lhs.1.date == rhs.1.date ? lhs.0 < rhs.0 : lhs.1.date > rhs.1.date
}
```

  `RecentUsageEntry.init?(event:)` rejects nonfinite/unrepresentable dates;
  amount nil/nonfinite/negative is retained as unavailable. Reject a nonempty
  all-invalid page and a missing first-page array with positive count. An empty
  supplied array or omitted array with zero count is a valid empty candidate.
  Do not apply the weekly date cutoff or deduplicate rows.
- [x] Implement formatter functions `amount(cents:)`, `tokens(_:)`,
  `eventTime(_:mode:now:localTimeZone:)`, `cachedTime(_:mode:localTimeZone:)`,
  `zoneLabel(mode:at:localTimeZone:)`, and `zoneIdentifier(mode:localTimeZone:)`.
  Use Foundation Decimal/NumberFormatter with POSIX USD punctuation and .halfUp;
  pick precision from the original value. Date functions take an explicit local
  timezone for tests and default to `.autoupdatingCurrent` in production.
- [x] Verify fixtures: 35 rows become 30; ties survive; old rows survive;
  `[1, 999, 1000, 999950, 1000000]` token totals; 1.56/0.0072/zero/tiny/missing USD;
  invalid counter/overflow; included/business/ultra/on-demand/free/custom/other;
  UTC versus Seoul date boundary and Los Angeles DST. Run existing `WeeklyUsageTests`
  and `WeeklyChartMetricTests` once to rule out decoder/aggregation regressions.
- [x] Run spec and code-quality reviews, fix relevant findings, then commit only
  these files as `[#118] feat: decode and format bounded recent usage` with the
  Codex co-author trailer.

Task 1 evidence: commit `e7fc866`; specification and quality reviews passed;
517/517 tests passed in the local compatibility mirror and unmodified-source
CLT Swift 6.2.4 build completed successfully.

## Task 2: Persist One Snapshot and Revoke It Safely

**Files:** create `Sources/CursorMeter/RecentUsageStore.swift`,
`Sources/CursorMeter/RecentUsageController.swift`,
`Tests/CursorMeterTests/RecentUsageStoreTests.swift`, and
`Tests/CursorMeterTests/RecentUsageControllerTests.swift`.

- [x] Write failing tests using a temporary directory and a unique UserDefaults
  suite. The critical ordering test submits removal before an older save:

```swift
try await store.remove(operation: 2)
try await store.save(snapshot, validityToken: "current", operation: 1)
let restored = await store.load(validityToken: "current")
XCTAssertNil(restored)
XCTAssertFalse(FileManager.default.fileExists(atPath: cacheURL.path))
```

  Here `store` is `RecentUsageStore(fileURL:)`, `snapshot` is a synthetic
  `RecentUsageSnapshot(candidate:binding:)`, and `cacheURL` is inside the test's
  temporary directory. Define `RecentUsageBinding` with credential, optional
  authenticated-subject, and request-scope equality digests. Its initializer
  extracts only WorkosCursorSessionToken from a header and hashes it with
  CryptoKit SHA256; missing/ambiguous auth cookies do not authorize restoration.
- [x] Observe red before implementation. Add a version-1 Codable envelope with
  snapshot and validity token, limit/size/date validation, and owner-only atomic
  replacement. File operations run off the MainActor. The store owns a greatest
  operation ID and rejects older operations before file mutation; actor scheduling
  order is not assumed. Apply 0700 directory and 0600 file permissions each write.
  Maximum encoded size is 256 KiB, checked before read and after encode. Update the
  operation floor before attempting removal even if removal fails.
- [x] Implement a MainActor observable `RecentUsageController` with `snapshot`,
  `status`, and a private held snapshot. Its store is nil by default. Configure
  production or test store/preferences explicitly; nil means zero file I/O.
  Capture generation/revision before loads and reject late results. Begin restore
  only after the credential selected for the imminent request is known.
- [x] Match an exact successful credential for early cached display. Rotated
  credentials keep the candidate private until authenticated subject and resolved
  request scope both match. New scope, rejected credential, logout, or expiry clears
  displayed/held data and revokes the old persisted validity token before queued
  deletion. A failed removal cannot make the old file eligible at the next launch.
  A validated network candidate replaces rows and cachedAt together; write failure
  keeps memory usable and emits only a content-free persistence error.
  Use an injected validity-token read/commit boundary. Production commits the
  nonsecret UUID with CFPreferencesSetAppValue + CFPreferencesAppSynchronize and
  checks its Boolean result before queued deletion. This small synchronous
  authentication-boundary operation avoids relying on asynchronous UserDefaults
  writes or a shutdown-draining subsystem. Failure disables disk restore/save for
  the process and attempts cleanup, while valid in-memory data remains usable.
  Keep session generation/attempt ID, restore revision, and monotonically
  increasing disk-operation ID distinct. Every selected credential/fallback
  invalidates the restore revision, even within one outer attempt. Rotated-token
  reuse requires nonnil authenticated subject AND exact scope; preserve cachedAt
  and the original stored binding until a fresh candidate is received.
- [x] Verify exact restart timestamp; credential cookie-order independence; rotated
  offline withholding; matching-subject reuse; different account/team rejection;
  late load after network publication; old save after invalidation; deletion and
  write failures; corrupt/oversized/unsupported files; no credentials/email/raw
  event payload; second replacement still mode0600; one file and at most30 entries.
- [x] Review spec then quality, and commit `[#118] feat: persist account-bound recent usage snapshots`.

Task 2 evidence: specification and quality reviews passed; exact auth-value,
stale-attempt, and process-recreation regressions were reproduced and fixed.
The compatibility mirror passed 549/549 tests; the unmodified-source
CLT Swift 6.2.4 build completed successfully.

## Task 3: Own Shared Admission and Feedback Deadlines

**Files:** create `Sources/CursorMeter/RefreshFeedback.swift` and
`Tests/CursorMeterTests/RefreshFeedbackTests.swift`.

- [x] Write pure deadline tests with a captured ContinuousClock.Instant. Production
  durations are3s admission,1.3s minimum rotation,0.65s result. Test-only `.immediate`
  has all three zero. Use these exact expected boundaries:

```swift
// Fast: completion at0.2 -> rotation ends1.3, result ends/readiness3.0.
// Slow: completion at4.2 -> rotation ends4.2, result ends/readiness4.85.
// A second start is denied while work is active even past3.0.
// Invalidating attemptA then startingB makes A's completion a no-op.
```

- [x] Observe red, then implement `RefreshTiming` and `RefreshTimeline` value types,
  `RefreshPhase` (idle/updating/result), `RefreshOutcome` (success/failure), and
  the MainActor observable controller `RefreshFeedback`. Keep arithmetic pure:

```swift
let rotationEnd = max(start.advanced(by: timing.minimumRotation), completed)
let readyAt = max(start.advanced(by: timing.admissionInterval),
                  rotationEnd.advanced(by: timing.minimumResult))
```

- [x] Admission returns an attempt identity bound to the session generation.
  Completion carries independent meter/recent outcomes. One feedback Task sleeps
  to the next deadline, validates identity, publishes phase, and then sleeps to
  readiness if necessary. Invalidate cancels that task and clears the timeline.
  Inject monotonic now/sleep behavior; do not create a general clock framework.
- [x] Verify fast/slow failure and asymmetric outcomes, exact deadline edges,
  automatic/manual overlap, stale completion, and a view joining mid-phase.
  This component owns no HTTP, retry queue, AppKit view, or persistence.
- [x] Review spec then quality, and commit `[#118] feat: coordinate refresh admission and feedback`.

Task 3 evidence: specification and quality reviews passed; 19 focused timing
tests and all 568 compatibility-mirror tests passed. The unmodified-source
CLT Swift 6.2.4 build completed successfully.

## Task 4: Share Event Collection and Integrate Session Ownership

**Files:** create `Sources/CursorMeter/UsageEventCollection.swift` and
`Tests/CursorMeterTests/RecentUsageIntegrationTests.swift`; coordinator modifies
`UsageViewModel.swift`, `UsageModels.swift`, `NotificationManager.swift`, and
existing test factories. Add a focused notification race test for the existing
threshold-notification path.

- [x] Add request-recording MockURLProtocol fixtures for page1/page2 outcomes and
  controllable delayed completions. Select these tests before editing the pipeline:
  one existing page1 feeds both consumers; page2 transient failure retains page1;
  positive-total missing array fails recent only; page2 scope/auth rejection
  withholds candidate; first-session unknown scope adds no request; cached-mode
  list-only success; primary401 cancels abandoned optimistic collection before
  cookie fallback; both existing enterprise shape-fallback paths still work.
- [x] Introduce `UsageEventCollection` containing `recent: RecentUsageCandidate?`
  and `weekly: Result<[UsageEvent], Error>`. Its collector preserves existing
  pageSize100/max5/7-day stop rules and captures page1 wall-clock time exactly once.
  Keep the existing `UsageViewModel.collectWeeklyEvents` compatibility entry used
  by chart tests by returning `try collection.weekly.get()`.
- [x] Change optimistic task and sequential consumers to use that outcome. Do not
  publish before primary authentication and current scope validation. Publish a
  valid recent candidate for later transient failures while retaining existing
  chart failure behavior. Scope/auth/shape errors discard it; existing allowed
  enterprise rediscovery may supply a new candidate. Optional user-info `sub`
  decoding uses a default-nil initializer argument so existing fixtures compile.
- [x] Put admission at the existing `refresh()` entry so all callers share it.
  Store the active network Task; a duplicate awaits its value without another
  request. Complete network work independently of visual feedback. All production
  entry paths retain standard timings. Existing tests explicitly inject `.immediate`
  in their factories; their substantive assertions remain unchanged.
- [x] Capture session/attempt identities and check after every suspension before
  mutation, including provider reads, discovery caches, errors, 401 handling,
  Keychain deletion, retry scheduling, notifications, auth-source writes and defer.
  Track/cancel optimistic tasks on every attempt exit. Explicit reconnect retires
  old work and starts once regardless of old feedback cooldown. Account-change
  detection uses authenticated sub plus the existing normalized in-memory email
  signal; discard old-mode optimistic work before adopting the new scope.
- [x] Guard threshold-notification state inside NotificationManager as well as
  its caller: reset advances a revision, authorization completion checks that
  revision before delivery, and send completion checks it before dedup mutation.
  Verify a paused old send cannot change the new session's dedup state, using an
  injected send seam without the real notification center. Already submitted OS
  notifications are outside this cancellation boundary.
- [x] Wire RecentUsageController, persisted Local/UTC setting, and timezone change
  revision. Tab entry and formatting cannot call refresh. Preserve existing
  activity defer/throttle, periodic fallback, and network retry scheduling.
- [x] Verify delayed success/error/401 after logout and fast relogin: no old data,
  auth resurrection, Keychain deletion, counter mutation, or release of new busy.
  Verify actual HTTP counts for rapid alternating controls/automatic requests.
  Run full local suite and unmodified CLT build, then spec/quality review.
- [x] Commit `[#118] feat: share usage events and isolate refresh sessions`.
- [x] Request independent Cursor Grok4.7/Muse1.3/Opus5.5 integration reviews using
  cursor:rescue. Reconcile code-grounded findings, test fixes, and commit before UI
  wiring. Keep review jobs read-only; no live Cursor credentials or data.

Task 4 evidence: specification and quality reviews passed after reproducing
and fixing cancellation of awaited optimistic tasks, later-page 408/429 retention,
enterprise shape rejection without meter data, and meter latching after a changed
team/user scope. The compatibility mirror passed 619/619 tests; the unmodified
CLT Swift 6.2.4 build completed successfully. Native app observation, production
store injection, and the system timezone observer remain in Task 5.

Integration review follow-up: all three requested models completed read-only
reviews. Preserve a known unrelated held snapshot across IDE rejection, retaining
its disk binding only when current-file ownership is proven. Invalid credential
bindings expose failure, and repeated revocation avoids redundant durable writes.
Session expiry retains the existing activity throttle. Gated tests cover late
and skipped disk writes, including failed deletion. Independent specification
and quality re-reviews passed. The compatibility suite passed 626/626 tests;
the final persistence synchronization change passed 28/28 controller tests and
the unmodified CLT build. Native UI work remains pending below.

## Task 5: Add Native Usage and Shared Refresh Controls

**Files:** create `RefreshFeedbackButton.swift`,
`SettingsUsageTabViewController.swift`, and focused native UI integration tests.
Coordinator modifies `SettingsCardFactory.swift`, `SettingsTabViewController.swift`,
`CursorMeterApp.swift`, and `MenuBarView.swift`.

- [x] Select UI verification cases:0/1/6/30rows, long model/exact tokens, light/dark,
  initial/cached/empty/failed/partial success, scroll retention, Local/UTC,
  Reduce Motion, mid-attempt reopen, and both buttons sharing readiness/outcomes.
- [x] Implement `RefreshFeedbackButton` as a display-only AppKit component. Keep
  button dimensions and AX names stable; Core Animation rotates only the icon.
  Render state idempotently and preserve the animation when unrelated data changes.
  Reduce Motion uses a distinct static progress symbol; disabled text follows
  native control colors. The labeled button stays100pt wide for every caption;
  the popover control retains its26pt hit target. No UI-owned network or phase timers.
- [x] Implement Usage with init(viewModel:), updateUI(), and viewWillAppear fitting
  size. Set root width480, horizontal insets18, row height52 and viewport312.
  Use NSScrollView plus view-based NSTableView; right-align fixed token/money
  columns and allow model truncation. Reload only for snapshot/zone changes.
- [x] Add Recent usage/cache timestamp/Refresh header, stable status region,
  row count/LocalUTC footer, Included caption, and Open Cursor link. Both button
  actions use the same existing `await viewModel.refresh()` entry. Local/UTC calls
  a setter only. The full source URL is the fixed trusted Cursor dashboard URL.
- [x] Register Usage after Display and fan out updateUI. Extend
  `makeTabRoot(sections:width:)` with width default440. Add all new observable
  fields to both app observation blocks. Inject the real store from the production entry point only;
  keep test-host default storage nil. Keep popover Loading tied to network work.
- [x] Use stable AX names: Usage, Refresh recent usage, Refresh usage,
  Recent usage events, Time zone, Local, UTC, Open Cursor, and Cached at.
  State feedback belongs in accessible value/help without renaming the button.
- [x] Verify through a synthetic native fixture with unique bundle ID and temporary
  storage. Compile real production view/controller files with fixture-only main;
  do not launch production AppDelegate or read real Keychain/IDE credentials.
  All requests use a fail-closed fixture protocol; dev marker and update runner
  prevent GitHub inference/network. Do not replace /Applications/CursorMeter.app.
  Use AX element paths and raised window frames for interactions/screenshots.
- [x] Review spec then quality, fix actual layout/behavior findings, and commit
  `[#118] feat: add recent usage settings and shared refresh feedback`.

Implementation and review checkpoint (2026-09-24): the fourth tab, shared
buttons, presentation observers, and production-only cache are implemented.
Specification and quality reviews corrected missing-model/time-zone help, the
glyph rotation anchor, and duplicate ViewModel initialization. An injected
immutable model survives settings-window recreation.

Final Cursor reviews used Grok 4.7 xhigh, Muse Spark 1.3 Max, and Opus 5.5 Max.
Accepted findings corrected historical DST offsets, UTC invalidation, caption
width, disabled colors, static reduced-motion progress, and five-digit meter
amount containment. Independent specification/quality reviews and the focused
Opus follow-up passed. The compatibility suite passed 642/642; unmodified CLT
debug/release builds and 12 installer tests passed. Original-source CI remains
an integration gate below.

Native acceptance passed after desktop unlock on 2026-09-24. The synthetic app
compiled 30 production Swift files byte-for-byte with a separate application
entry, isolated preferences/storage, and intercepted HTTP. AX inspection and
window captures covered light/dark 0/1/6/30 rows, initial loading, restored cache,
retained cache after failure, and reduced-motion progress. The Usage window is
480 by 628 points with a 422 by 312 viewport. Exact tokens and full model names
are accessible. Local/UTC changes and tab reopening produced zero requests.
Fast refresh kept both controls synchronized and admitted one request per
endpoint despite eight extra clicks. A 4.1-second response kept both controls
busy beyond the 3-second admission interval. Meter/recent partial failures
reported their own outcomes. Cache restoration/failure retained the original
timestamp and rows. All seven published captures use synthetic Demo User data;
no installed app or real credentials were used.

## Task 6: Document, Review, and Deliver

**Files:** update relevant `README.md`/`README.ko.md`, `SECURITY.md`/`SECURITY.ko.md`,
`docs/API_REFERENCE.md`, affected `docs/screenshots/`, and this plan's checklist.

- [x] Document the30-event boundary, original cache time, LocalUTC and amount
  meaning, per-device request guards, undocumented API limitation, and bounded
  local storage/logout behavior. Keep public text factual; no private strategy or
  real-account details. Update each translation pair in the same commit.
- [x] Inspect native screenshots for PII and use only synthetic Demo User data.
  Preserve/refresh affected existing screenshots and add the Usage example.
  Check stale references to three tabs and old refresh/caching descriptions.
- [x] Run complete tests, unmodified debug/release CLT builds, native AX scenarios,
  and final independent Cursor reviews with the same three requested models.
  Review final diff against origin/main, reconcile valid findings, and rerun only
  checks affected by fixes. Record exact outputs and remaining limitations.
- [x] Commit atomic changes with `[#118]` and Codex co-author. Fetch origin before
  integration and preserve user changes. Follow the solo direct-merge preference
  unless external changes make a PR useful. Push a CI-triggering main/PR update;
  feature-only pushes do not trigger this repository's Test workflow.
- [x] Inspect CI for both macOS architectures and installer tests. If failures
  involve the feature, fix and rerun. Close #118 only after acceptance evidence
  and CI pass, then list remaining open issues. Do not publish a release.

Main integration completed through `e497734`, with existing local files preserved
byte-for-byte. Original-source [CI run 35948365910](https://github.com/WoojinAhn/CursorMeter/actions/runs/35948365910)
passed on macOS 15 ARM and Intel: each executed 642 Swift tests with zero failures
and all 12 installer tests. CI follow-ups named the final test class explicitly
inside cancellation Tasks to avoid dynamic `Self` capture, and checked the
refresh button's constrained alignment rectangle instead of its OS-dependent
bezel frame. These test-only corrections retained cancellation, geometry, and
all eight caption-fit assertions; independent specification/quality reviews and
local focused/full suites passed. Production sources remain unchanged from the
accepted review fixes at `58be1f8` and subsequent native acceptance.

[Issue #118](https://github.com/WoojinAhn/CursorMeter/issues/118) was closed as
completed on 2026-09-24 after CI passed. The required post-close open-issue list
was checked: #117, #97, #70, #69, #65, #53, #47, #42, #31, and #30 remain open.
No release was published and no installed application was replaced.

## Coverage Self-Check

Tasks1/4 prove request reuse and all first-page outcomes. Tasks2/4 prove account
and generation isolation, original timestamps, and persistence boundaries.
Task3/4 prove shared timing and existing scheduling. Tasks1/5 prove formatting
and native UI. Task6 supplies translation, screenshot, independent final review,
unmodified-source CI, and issue completion evidence. There are no deferred
product choices or additional user approvals in this execution plan.
