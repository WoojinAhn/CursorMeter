# Issue 121 Usability Revision Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development and verification-before-completion. The user explicitly authorizes parallel work on disjoint files; coordinator owns central integration, shared docs and commits.

**Goal:** Implement the approved enlarged usage meter, opt-in estimated limits with information popover, independent alert settings, and removal of diagnostic UI text.

**Architecture:** Keep existing AppKit controllers and observable UsageViewModel. Introduce additive display preferences and scoped alert threshold values; UI consumes compact shared presentation. Retain the collector, source validity gates and split eligibility.

**Tech Stack:** Swift 6, AppKit, XCTest, existing SDKs only.

## Baseline and constraints

- Existing branch feature/121-split-usage, remote main c0225f7 included; preserve existing dirty classification-v2 changes and user .gitignore.
- Issue #121 and draft PR #122 already exist. No main merge, release, or installed-app replacement in this task.
- Specification: ../specs/2026-09-26-issue-121-split-usage-design.md, especially section 9.
- Three requested external reviewers: muse-spark-1.3-max, grok-4.7-xhigh, claude-opus-5-5-max. Fresh read-only review before implementation and at integration/final checkpoints.

## Shared implementation contract

Coordinator owns `UsageViewModel.swift`, `CursorMeterApp.swift`, preferences DTO file,
central integration tests, shared docs, and git actions. No worker edits those files.

```swift
enum PopoverValueMode: Int, CaseIterable { case percent, dollars, both }
// View model state and setters supplied by coordinator:
var popoverValueMode: PopoverValueMode // default .both
var estimatedLimitsEnabled: Bool // default false
var estimateExplanationSeen: Bool // default false
func setPopoverValueMode(_ mode: PopoverValueMode)
func setEstimatedLimitsEnabled(_ enabled: Bool)
func markEstimateExplanationSeen()
var splitAlertThresholds: [SplitAlertScope: SplitAlertThresholds]
func splitThresholds(for scope: SplitAlertScope) -> SplitAlertThresholds
func setSplitThresholds(_ thresholds: SplitAlertThresholds, for scope: SplitAlertScope)
func setSplitWarningThreshold(_ value: Int, for scope: SplitAlertScope)
func setSplitCriticalThreshold(_ value: Int, for scope: SplitAlertScope)
```

The alert worker defines `SplitAlertThresholds` (Sendable/Equatable/Codable) with Int
warning/critical values and normalized init. It adds a default-empty
`thresholdsByScope: [SplitAlertScope: SplitAlertThresholds]` policy parameter; empty
falls back to existing shared warning/critical values only for legacy policy callers/tests;
VM migration eagerly stores all missing scope pairs once and always supplies them. Policy
invalidation must notice per-scope pair changes. The gauge callback publishes its complete
normalized pair atomically through setSplitThresholds, avoiding transient invalid pairs.

Presentation worker adds defaulted `valueMode: PopoverValueMode = .both` and
`showEstimatedLimits: Bool = false` parameters to SplitUsagePresentation.make.
Existing named fields remain usable while diagnostic summary consumers are removed.

## Progress

- [x] Fetch/compare baseline; preserve existing branch and changes; start owned caffeine.
- [x] Reconcile latest decisions in specification and establish shared interfaces.
- [x] Gate A attempts concluded: Grok and late Opus completed; findings reconciled in review ledger. Muse failed without findings. Implementation proceeded with this explicitly reported limitation; no three-model pass claimed.
- [x] Baseline full test run: 841 tests, zero failures; `.Codex/usability-baseline-tests.log`.
- [x] Worker A: alert domain and Alerts UI. Files: SplitUsageAlerts.swift, SplitUsageAlertDispatcher.swift, SettingsNotificationsTabViewController.swift, matching alert tests. Prove independent thresholds/enable, migration-compatible fallback, policy cancellation, no notification replay; retain ThresholdRangeSlider.
- [x] Worker B: shared presentation and popover. Files: SplitUsagePresentation.swift, MenuBarView.swift, CircularProgressIcon.swift if required, new meter view if required, corresponding presentation/UI tests. Prove amount opt-in, compact tooltip/AX, single/dual behavior, missing/stale separation, fitting and preserved actions.
- [x] Worker C: Display and Usage UI. Files: SettingsAppearanceTabViewController.swift, SettingsUsageTabViewController.swift, new help controller if required, dedicated UI tests. Preserve segmented controls, hide irrelevant rows, keyboard-accessible estimate help with first-enable behavior, remove Summary without losing Recent behavior.
- [x] Coordinator: preferences migration/persistence, alert adapter, main observation re-arm, removal of Summary plumbing and integration tests. Defaults: Both, estimate off; per-scope initial thresholds copied from normalized shared values.
- [x] Test evidence recorded: domain behavior RED, stale-cost and label-width regression RED, preference/retry API compile RED, followed by integrated GREEN. Not every initial concurrent worker RED reached an assertion; the review ledger records this limitation. UI verified with offscreen AppKit rendering and inspected screenshots.
- [x] Gate B attempts concluded: Grok and Opus findings resolved or explicitly declined in the ledger; Muse failed without findings. No three-model approval claimed.
- [x] Update before/after mock to exactly reflect segmented controls, information popover and reduced copy. Capture browser and native offscreen UI images, inspect no clipping/PII. Live installed app remains user-controlled.
- [x] Gate C: all three final reviews returned; Muse/Grok no remaining scoped findings, Opus card background fixed. Later CI scrollbar corrections independently reviewed. Full local suite: 872 tests, zero failures; final CI/package tracked in review record.
- [x] Update applicable English/Korean README/SECURITY pairs and screenshots, stale-reference sweep, record known unsupported scopes truthfully.
- [x] Atomic commits pushed to the existing draft PR; unrelated work preserved. ARM/Intel CI passed on final source efdf60c (run 36244732358).
- [x] Source/build/test/review artifacts and manual-check handoff prepared. Installed app remains untouched; release only the task-owned caffeine assertion at the end of delivery.

## Critical acceptance cases

1. Given saved shared thresholds 60/85 and no per-scope values, each scope starts 60/85; changing Cursor to 65/90 leaves Other 60/85 after recreation.
2. Given eligible amount snapshot and default preferences, used dollars remain visible and inferred denominators are absent. Enabling estimation reveals only eligible inferred values; source/cycle mismatch suppresses them.
3. Toggling estimation never changes actual percentage, icon geometry or alert policy.
4. First enable opens informational help if it has not already been viewed; later toggles do not, explicit info activation always does; no modal approval needed.
5. Pro qualifying by API behaves like Ultra; request/percent-only inputs cannot acquire dollar display from the new preference; team scope retains existing supported behavior.
6. Popover, hover and VoiceOver have no residual/coverage/source timestamps or Ready/Unavailable enum dump. Actual failures and old values remain understandable.
7. Quiet/Normal/Bold and both emoji sets retain NSSegmentedControl; %/$/Both is segmented. The dual-thumb alert gauge remains per active family card.
8. Usage opens Recent directly and retains real table refresh, timezone, count, cache/error handling.
