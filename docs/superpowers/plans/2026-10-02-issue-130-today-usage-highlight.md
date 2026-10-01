# Today usage highlight implementation plan

> **For agentic workers:** Use superpowers:subagent-driven-development to implement the tasks with specification and quality checkpoints. The coordinator owns this plan, the specification, shared application wiring, and final commits.

**Goal:** Highlight the estimated KST-today contribution in the large popover circle without changing official totals, menu-bar rendering, alerts, or credential authority.

**Architecture:** Extend the existing full-cycle receipt with one optional KST-day aggregate. Admit a separate demand identity from the existing live history receipt or the current primary refresh ID, then drain only the latest demand under the existing collection protections. Derive optional pool-keyed percentage points for the existing renderer; only the popover supplies them.

**Tech Stack:** Swift 6, Foundation, AppKit, XCTest; no dependencies.

Specification: [Issue #130 design](../specs/2026-10-02-issue-130-today-usage-highlight-design.md).
Baseline: `origin/main` at `9f19ec1`; 973 tests passed before changes.
Branch: `feature/130-today-usage-design`.

## Ownership and boundaries

- Data worker: day/allocation types, cycle receipt/collector/store, corresponding tests.
- Integration worker: scheduler, history change signal, split controller, `UsageViewModel` refresh wiring, corresponding tests. Run after the data interfaces are settled.
- Coordinator: renderer/popover/application observation and midnight hook, documentation, sanitized screenshots, commits and PR.
- Cursor Grok/Gemini/Opus reviewers: read-only instructions; no source mutations. Review the specification first, then data/scheduling and final UI/integration checkpoints.
- Do not touch `.gitignore`, local `AGENTS.md`, older untracked mockups, user settings, or the installed app. Do not merge or release.

## Task 1: Freeze the specification

- [x] Resolve the live roster: `grok-4.7-xhigh`, `gemini-3.1-pro`, `claude-opus-5-5-max`.
- [x] Dispatch independent specification reviews; retain exact outputs under `.Codex/issue-130/spec-review/`.
- [x] Adjudicate each concrete finding against source. Correct source inaccuracies and contract gaps; record accepted/rejected findings. Gemini approved amendments; Grok's final fallback clarification and Opus's findings were adjudicated into v1.0 for implementation/checkpoint verification.
- [x] Mark the specification final and record its digest in `progress.json` before changing Sources/Tests.

## Task 2: Capture and validate the daily aggregate

**Files:**
- Create `Sources/CursorMeter/TodayUsage.swift`.
- Modify `Sources/CursorMeter/CycleUsageModels.swift`, `CycleUsageCollector.swift`, `CycleUsageStore.swift`.
- Create `Tests/CursorMeterTests/TodayUsageTests.swift`; extend `CycleUsageCollectorTests.swift` and `CycleUsageStoreTests.swift`.

- [x] Write failing tests for the half-open KST interval, exact midnight, in-day cycle boundaries, mixed included/free-credit/bot/paid events, and Decimal sub-cent sums. Use fixed server timestamps and an injected collector clock.
- [x] Verify the tests fail for missing daily behavior before implementation:

```sh
swift test --filter 'TodayUsageTests|CycleUsageCollectorTests|CycleUsageStoreTests'
```

- [x] Add the bounded value types and pure eligibility/allocation seam. Use `CycleAmountSnapshot.todayUsage` for the optional aggregate. The selected interfaces are:

```swift
struct TodayUsageDay: Codable, Equatable, Sendable {
    let start: Date
    let end: Date
    init?(containing date: Date) {
        guard date.timeIntervalSince1970.isFinite else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let start = calendar.startOfDay(for: date)
        self.start = start
        self.end = calendar.date(byAdding: .day, value: 1, to: start)!
    }
    func contains(_ date: Date) -> Bool { start <= date && date < end }
}

struct TodayUsageAggregate: Codable, Equatable, Sendable {
    let day: TodayUsageDay
    let evidenceAt: Date
    var cursorCents: Decimal
    var otherCents: Decimal
    let sourceIncludedTotalCents: Decimal
}
```

Capture `TodayUsageCollectionContext(admittedAt: now())` once at admission and pass its day to demand and the same context to `collect(snapshot:summary:todayContext:)`. The context has `day: TodayUsageDay` and `admittedAt: Date`. The collector's direct-call default captures its own entry day. Add costs only in the existing `.cursor` and `.other` included-classification branches, after cycle checks. Set source included-total evidence from the initial primary snapshot; retain its existing source percentage fields. Never derive daily amounts from the weekly totals.

- [x] Use `TodayUsageAllocation.percentagePoints(snapshot:amounts:primaryIsStale:currentSessionAndDemandEligible:now:) -> [UsagePoolID: Double]?`; nil means global unavailability. Derive percentage points only after all global receipt fences pass. For each eligible pool, use this numerical core:

```swift
func todayPoints(percent: Double, cycle: Decimal, today: Decimal) -> Double? {
    guard percent.isFinite, percent >= 0, percent < 100,
          !cycle.isNaN, !today.isNaN, cycle > 0,
          today >= 0, today <= cycle else { return nil }
    let share = NSDecimalNumber(decimal: today / cycle).doubleValue
    guard share.isFinite else { return nil }
    return percent * share
}
```

The caller additionally checks complete/reconciled attribution, same scope/generation/classifier, both effective source percentages and included-total equality, current non-stale primary, current-session admission, matching latest demand (including fallback), and the current KST interval. Either percentage at 100% withholds both pools. Positive P with zero C also withholds both because classification could be inconsistent; P=0/C=0 only omits that pool.

- [x] Validate and lossily decode optional metadata without granting identity authority. Legacy caches still load costs; invalid day details are discarded independently of valid parent costs and never become known zero. Cached receipts cannot produce an overlay before a current-session collection. The evidence timestamp records admission, not a freshness TTL.
- [x] Run the focused suite above and retain pass/fail evidence. Perform native specification review, then code quality review before integrating.

## Task 3: Admit new-request demand and drain it safely

**Files:**
- Modify `Sources/CursorMeter/UsageEventCollection.swift`, `CycleCollectionSchedule.swift`, `SplitUsageController.swift`, `UsageViewModel.swift`.
- Extend `Tests/CursorMeterTests/UsageEventCollectionTests.swift`, `CycleCollectionScheduleTests.swift`, `SplitUsageControllerTests.swift`, `SplitUsageIntegrationTests.swift`.

- [x] Write failing cases before source edits: unchanged summary plus changed events, same receipt coalescing, unavailable-revision fallback per primary refresh, newest pending demand, delayed draining, stale result suppression, 60-second start spacing, failure backoff/429 and hourly page limits, sleep/logout/scope cancellation.
- [x] Run:

```sh
swift test --filter 'UsageEventCollectionTests|CycleCollectionScheduleTests|SplitUsageControllerTests|SplitUsageIntegrationTests'
```

- [x] Derive a stable revision from the existing first history page's content and available total. A successful live receipt can carry it; a cached, failed, malformed, unresolved-scope or old-session receipt cannot. This is a change signal, not a coverage certificate.
- [x] Admit the revision only after `requireCurrent` and the existing recent receipt/scope checks. Carry it with its batch, never as a reusable global last-known revision. At the end of that admitted primary batch, choose:

```swift
enum CycleEventEvidence: Equatable, Sendable {
    case revision(String)
    case primaryRefresh(UInt64)
}

struct CycleCollectionDemand: Equatable, Sendable {
    let summaryFingerprint: String
    let day: TodayUsageDay
    let eventEvidence: CycleEventEvidence
}
```

Move the current pre-history `requestAmounts` call to after history admission, or after its skipped/failed exit. Require the same primary identity/generation still to be current; unresolved revision uses that batch's `networkID` and each new fallback bypasses unchanged suppression. Keep the existing notification and receipt-owner reconciliation order intact. Every pending request captures its summary/snapshot together and must still match the current primary localID before starting; completion retains existing scope/generation fences.

- [x] Extend schedule admission with an optional today demand while retaining legacy call defaults. Distinguish the summary stability fingerprint from the demand key. Track start time and last completed demand; for today work use at least 60 seconds between starts, preserve failure backoffs and 300 automatic pages/hour. Normal refresh button actions use the same automatic admission and page accounting. Keep `retryStoppedAmounts()` as a legacy cost-only retry with matching existing availability text; its result cannot fulfill today's demand.
- [x] Retain only the latest pending demand and its captured request context. A changed demand, including fallback, immediately withholds the old overlay but preserves valid cycle costs. A completed old demand cannot publish a current highlight. Consume pending at start, coalesce identical in-flight demand, and do not re-enqueue an ordinary failure. Schedule one cancellable deferred wake-up at admission's deadline; drain after cycle and supplement completion. Recompute a not-yet-started demand's day at admission and pass that same interval to the collector. Drop pending and cancel its wake-up on owner retirement/logout. Sleep cancels the wake-up but retains the latest requested intent, including an active attempt cancelled for sleep; wake waits for a normal new primary/history batch to replace sleep-era request data before draining. Avoid self-sustaining retries.
- [x] Keep summary fingerprint observation separate from demand matching. Use legacy cadence when percentages cannot support an overlay or a prior complete receipt proves unresolved/invalid attribution or positive-P/zero-C inconsistency; a valid later receipt restores fast cadence. Map a today's complete-but-unreconciled result to unstable backoff. Preserve a valid same-source receipt instead of overwriting it with unavailable attribution, mark its amounts earlier, and withhold today.
- [x] Keep existing profile authority, credential-generation and #128 alert-delivery receipt fences. Do not extend cycle amount task lifetime through a retired split presentation.
- [x] Run focused suites; obtain Grok/Gemini/Opus data-and-scheduling checkpoint and Astra adjudication. Correct blocking findings and repeat affected tests. The completed-demand retirement marker now clears alongside fulfillment on sleep and same-owner authority changes; combined RED/GREEN regressions and 79 focused tests pass.

## Task 4: Render B treatment in the popover

**Files:**
- Modify `Sources/CursorMeter/CircularProgressIcon.swift`, `MenuBarView.swift`, `CursorMeterApp.swift`.
- Extend `Tests/CursorMeterTests/SplitCircularProgressIconTests.swift`, `SplitUsageUITests.swift`, `MenuBarViewLayoutTests.swift`.

- [x] Write renderer checks for default/nil parity, zero, all, tiny, almost-all, swapped pools, independent unavailable pools, over-limit withholding, and total/track geometry preservation. Render all normal/warning/critical states in Aqua, Dark Aqua and increased-contrast appearances.
- [x] Add an explicit default-empty pool-keyed overlay parameter to `makeSplitImage`; leave menu-bar/settings callers unchanged. Draw the existing fill first, clip subsequent drawing to exactly that fill, then paint today's ending arc/wedge in a 32% white blend of the same severity color. Draw a clipped 0.75pt separator only when both earlier and today span at least 0.5 percentage points. Never inflate tiny segments.
- [x] Pass the eligible map only from the popover's 112pt meter. Preserve existing values, layout, total endpoints and fixed 70/90 color thresholds.
- [x] Add concise help only when the today estimate is available:

```text
Lighter segment: today (KST).
Estimated from included usage costs.
```

Keep the image AX-hidden. Use popover-only helpers and preserve shared `pool.line`/menu-bar tooltip. Replace the circle tooltip only when at least one eligible segment has finite, positive percentage points; all-zero and unavailable maps keep the existing tooltip. Append estimated P*T/C percentage points to each eligible row with one decimal (including known zero), or `less than 0.1` for positive sub-0.1 values. Use a dark separator in light appearance and a light separator in dark appearance.
- [x] Observe the new overlay inputs in the popover's re-armed observation block. Re-evaluate on refresh, wake and opening. While open, use one next-KST-midnight presentation invalidation timer and cancel it on close; the timer must never trigger networking.
- [x] Run:

```sh
swift test --filter 'SplitCircularProgressIconTests|SplitUsageUITests|MenuBarViewLayoutTests|TodayUsageTests'
```

- [x] Capture and inspect sanitized native rendering with synthetic data without replacing the installed app. Keep the HTML local. Refresh affected product screenshots with no real name/email. Obtain three-model UI/integration checkpoint and Astra judgment.

## Task 5: Final verification and delivery

- [x] Review the full diff versus `origin/main`, including new files; search for obsolete design-only wording and inappropriate user-visible diagnostics.
- [x] Run the local suite with the two previously recorded real-Keychain cases excluded, `swift build -c release`, and installer tests. Results after the retirement fix: 1,036 Swift tests and release build pass; the 12 installer tests also pass. Preserve logs in `.Codex/issue-130/`. Full hosted CI remains required.
- [x] Run the three-model final review on the complete branch diff, then write independent Astra adjudication. Resolve concrete findings and rerun affected checks.
- [ ] Commit only issue #130 files in coherent units using `[#130]` messages and the Codex co-author trailer. Keep local HTML and unrelated dirt out of commits.
- [ ] Push the feature branch, open a reviewable PR linked to #130, and check both macOS CI jobs. Do not merge or close the issue.
- [ ] Record commit/PR/check evidence in `progress.json`, release only this task's caffeine process, mark the goal complete, and provide a concise Korean result with verification and remaining limitations.
