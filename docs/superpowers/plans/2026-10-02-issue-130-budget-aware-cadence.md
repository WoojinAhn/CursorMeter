# Budget-aware today collection implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Resolve PR #131 M1's successful-collection burst/stall without weakening source or budget fences.

**Architecture:** Keep admission in `CycleCollectionSchedule`. Record a deadline after automatic successful completion using its charged page count; the controller already coalesces demand and wakes at scheduler deadlines. Do not change UI, collectors, or authentication.

**Tech Stack:** Swift 6, XCTest, existing injected clock/collector/wake seams.

## Task 1: Approve the amendment

Files: `docs/superpowers/specs/2026-10-02-issue-130-today-usage-highlight-design.md`, `docs/API_REFERENCE.md` (coordinator only).

- [x] Review `.Codex/issue-130/cadence-fix/amendment-draft.md` through Grok, Gemini, and Opus. Adopt only after at least two agree and Astra independently accepts. No production/test edits before this gate.
- [x] Replace the frozen 60-second-only success policy with the reviewed adaptive completion policy; keep the old start floor, failure behavior, and legacy/manual distinctions. Record v1.2 and link this plan from the historical implementation plan.

## Task 2: Critical admission logic, RED then GREEN

Files: `Sources/CursorMeter/CycleCollectionSchedule.swift`; `Tests/CursorMeterTests/CycleCollectionCadenceTests.swift` (new); `Tests/CursorMeterTests/CycleCollectionScheduleTests.swift` (changed contractual expectations).

- [x] Add the following deterministic multi-hour regression before production edits. It must fail on current HEAD because waiting returns the old 60-second deadline, then later cannot admit a full attempt.

```swift
import XCTest
@testable import CursorMeter

final class CycleCollectionCadenceTests: XCTestCase {
    func testSteadySuccessesKeepFullAllowanceAcrossThreeHours() {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        for pages in [5, 11, 21, 51, 100] {
            for duration in [0.0, 60.0] {
                var schedule = CycleCollectionSchedule()
                var time = start
                var index = 0
                var completions: [Date] = []
                while time < start.addingTimeInterval(10_800) {
                    let demand = "revision-\(index)"
                    XCTAssertEqual(schedule.begin(at: time, manual: false, todayDemand: demand), 100)
                    time = time.addingTimeInterval(duration)
                    schedule.finish(.complete, pages: pages, at: time)
                    completions.append(time)
                    let charged = completions.filter { time.timeIntervalSince($0) < 3600 }.count * pages
                    XCTAssertLessThanOrEqual(charged, 300)
                    let next = time.addingTimeInterval(max(60, Double(pages) * 18))
                    XCTAssertEqual(schedule.availability(at: next.addingTimeInterval(-1), manual: false,
                        todayDemand: "revision-\(index + 1)"), .waiting(until: next))
                    time = next
                    index += 1
                }
            }
        }
    }
}
```

- [x] Run `swift test --filter CycleCollectionCadenceTests` and save RED output under `.Codex/issue-130/cadence-fix/`. Confirm assertion failure rather than compilation error.
- [x] Extend behavioral cases before GREEN: actual charged retry cost (22), changing success costs (51 then 5), manual success at +60 preserving the prior +918 deadline, invalidation retaining it, reset clearing it while preserving charged pages, retired success not changing the current deadline, and failure/legacy contracts. Existing hourly fence test that deliberately bursts 100-page successes must use `resetCycle()` between scopes so it tests surviving charges without depending on the retired 60-second-only policy.
- [x] Minimal production change (names may follow current conventions):

```swift
private var nextSuccessfulTodayAt: Date?

private func todayStartAvailability(at now: Date) -> Availability {
    var deadline = lastStartedAt?.addingTimeInterval(60)
    if case .complete = lastOutcome, let paced = nextSuccessfulTodayAt {
        deadline = max(deadline ?? paced, paced)
    }
    if let deadline, now < deadline { return .waiting(until: deadline) }
    return .ready
}
```

In the active `.complete` switch branch only:

```swift
if !attempt.manual {
    let chargedPages = min(attempt.pageAllowance, max(0, pages))
    // Preserve room for a full 100-page attempt inside the 300-page rolling hour.
    let spacing = max(60, Double(chargedPages) * 3600 / (300 - 100))
    nextSuccessfulTodayAt = now.addingTimeInterval(spacing)
}
```

In `resetCycle()` set `nextSuccessfulTodayAt = nil`. Do not change hard budget, failure gates, charge ownership or controller APIs.

- [x] Update the two old schedule tests with four-page/45-second success to expect `start + 117` (45 + 72). Unchanged suppression still returns `.unchanged`. Manual waiting remains based on last completion +60.
- [x] Run `swift test --filter 'CycleCollectionScheduleTests|CycleCollectionCadenceTests'`; save GREEN output.

## Task 3: Controller regression and independent review

File: `Tests/CursorMeterTests/TodayUsageIntegrationTests.swift`.

- [x] Extend only the injected `Collector` actor with a default `pageCount = 2`, settable for the new test, returned as the result page count. Existing fixtures keep two pages and their 60-second instantaneous-completion behavior.
- [x] New test: hold the first 51-page collection for 45 simulated seconds before completion. At +55 admit revision b and verify the overlay disappears while costs remain. At +65 replace with revision c; assert only one collector call and a deferred deadline of +963 (45 + 918). At +963 fire the injected wake and assert call two carries c's latest identity, costs carry that identity, and today's overlay returns. This distinguishes completion-based pacing and crosses the legacy +600 boundary and tests automatic draining with no new primary poll.
- [x] Run `swift test --filter 'CycleCollectionCadenceTests|CycleCollectionScheduleTests|TodayUsageIntegrationTests'`.
- [x] Independent spec compliance review, then code quality review. Fix confirmed findings. Coordinator also performs own source review. Do not delegate edits to shared specs/plans/API/README files.
- [ ] Cursor Grok/Gemini/Opus implementation checkpoint over the complete PR diff and amendment; resolve material findings before merge. No automatic retry or model substitution on runtime failures.

## Task 4: Verify and merge

- [x] Run `swift test --skip 'CredentialChainTests/testBrowserLoginClearsSuppression|IDESignInGuidanceTests/test_watch_stopsWhenLoggedInViaBrowser'` (two pre-existing local Keychain-writing tests excluded); `swift build -c release`; `python3 -m unittest discover -s Scripts/tests`. Save outputs locally. CI runs the complete suite in ephemeral runners.
- [x] Sweep docs for stale success-cadence claims; retain historical plan actions with an explicit superseding note. No screenshot change: this correction changes admission only, not rendered UI. Keep mockup local.
- [ ] Explicitly stage only cadence Sources/Tests and related tracked spec/API/plan files. After native reviews pass, commit `[#130] fix: pace today collection within the hourly page budget` with the Codex co-author trailer and push the existing feature branch. CI may run alongside the final model reviews; keep the PR draft until both gates pass.
- [ ] Verify exact-head CI on both macOS architectures; update PR body/review rationale with actual results; mark ready. Re-fetch base/head, adjudicate independently and merge with `--match-head-commit`, without administrative override or branch deletion.
- [ ] Verify GitHub MERGED state and main CI, record remaining open issues after #130 closes. Stop only the task-owned caffeine process. Report the merge result briefly.

## Opus clarification checkpoint

The original draft mechanism remains unchanged. Grok and Opus both independently
verified variable-cost paced-success sequences; Astra adopts that precise
acceptance statement. Add alternating costs (34/100/100, 3/100), durations 0/60,
and the q67/first-duration60 case to the multi-hour test. Manual and retired
completions must leave the stored deadline exactly unchanged. Failure early-retry
semantics remain unchanged. Opus's five design requests are mapped in the local
Astra adjudication; final implementation review must verify their resolution.
