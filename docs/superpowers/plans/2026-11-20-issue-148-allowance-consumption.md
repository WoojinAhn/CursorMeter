# Shared Allowance Consumption Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development to execute the integrated task below, then independent specification and quality review.

**Goal:** Estimate each included activity entry's share of the full weekly allowance using verified weekly included-token totals and the server-reported percent, while separately exposing observed interval changes.

**Architecture:** Extend the shared activity path with a scope-bound weekly calibration; keep all existing authentication, meters and amount semantics. Read the exact weekly range through the existing aggregate endpoint and confirm the current-period reading after collection. Reconcile aggregate token summaries and UTC buckets; do not download the entire event ledger on each refresh. The live investigation separately verified a complete ledger against this aggregate source. Estimates remain explicitly token-proportional, not measured request deductions.

**Tech Stack:** Swift 6, Foundation, AppKit, XCTest. No new dependencies.

## Approved contract

The owner approved replacing the recent-list denominator with full-week allowance estimation on 2026-11-20. Preserve the existing Usage layout; add a compact estimated percentage-point detail under token counts. Keep paid USD and Included labels in the amount column. The caption shows reported weekly use, conditional effective capacity, and a same-cycle observed change when available. Existing weekly/prepaid rings retain their meanings.

For included tokens `T`, server percent `p`, and entry tokens `t`:

```swift
let estimatedCapacity = Double(T) * 100 / p
let estimatedPercentagePoints = p * Double(t) / Double(T)
```

Accept only valid same-owner, same-cycle readings; current time inside the cycle; finite `0.1 <= p < 100`; positive bounded included totals; exact aggregate range echo; matching included/total sums through the token-ranked series and other bucket; and unchanged percent/cycle on the confirmation read. A weekly cycle may start inside a UTC day, so bucket validation uses the UTC day containing the requested start. Include at most the relevant eight UTC dates. Paid tokens never enter `T`. The aggregate source supplies the full range, independent of the recent-list limit.

Show estimates only for included entries within the accepted range, with a known token count no greater than `T`, and matching fresh current state. Clear or suppress estimates on refresh failure, account/credential/plan/cycle changes, incomplete data, saturation and incompatible snapshots. Do not introduce persistent tracking. Timestamp all calibration/observation evidence and reject expired periods.

Format row estimates as `≈0.047 pp` (three decimals; positive smaller values as `≈<0.001 pp`). Tooltip and accessibility help say these are estimated percentage points of weekly allowance using token proportions; product/model/input/output/cache weights may differ. Capacity is labeled estimated and conditional on the observed usage mix. A reported change is the difference between two accepted same-cycle server snapshots, with an interval; it is not assigned to a request. Unchanged readings mean no reported change. Decreases, resets and invalid reads reset the observation baseline.

## Task 1: Implement and verify the integrated metric

**Files:**
- Create `Sources/CursorMeter/SharedAllowanceUsage.swift` for the validated calibration, observation and formatting logic.
- Modify `SharedActivityModels.swift` to expose validated exact-period included totals without altering the rolling seven-day chart contract.
- Modify `SharedActivityController.swift` to collect/confirm calibration and retain scoped observations; reuse `CursorSharedUsageFetching` for confirmation.
- Modify `UsageViewModel.swift`, `CursorMeterApp.swift` and `SettingsUsageTabViewController.swift` for dependency/state/observation wiring and the approved compact presentation.
- Add focused model/controller/UI cases in `Tests/CursorMeterTests`; extend the existing fixture and test factory only as needed, preserving test isolation.

- [x] Write failing critical tests before implementation. The synthetic baseline is `T=50_000_000`, `p=12.5`, `t=200_000`: capacity 400M and entry estimate 0.05 pp. Paid entries receive no included estimate.
- [x] Cover partial UTC first/last days, mismatched range, duplicate days, totals/series/other reconciliation, invalid included totals, overflow, zero/low/100 percent, absent tokens, out-of-period entries and tiny estimates.
- [x] Cover stable and changed confirmation, owner/cycle changes during suspended work, failure/stale snapshot, and observation intervals that reset on decreases or rollover. Add UI tests for paid amount preservation, fixed columns, and details/help. Legacy behavior stays unchanged.
- [x] Run focused tests and record the failure evidence; implement the smallest change, then rerun to green. Use injected providers; never call real credentials/Keychain/notification center in tests.
- [x] Run `swift test` and `swift build -c release`; retain summarized output and logs. Do not package/install before review.
- [x] Independently review specification, then run Argon High and Grok XHigh quality review on the final patch; resolve findings against source and runtime evidence. Argon approved. Grok rejected for rounding and possible caption clipping; the coordinator retained ordinary approximate rounding and verified both the maximum formatted width and live one-to-four-line caption growth without clipping.

## Task 2: Documentation, capture and local delivery (coordinator)

- [x] Refresh the before/after HTML mockup and inspect a browser screenshot. The user's approved full-week criterion supersedes the withdrawn list-share draft; no separate routine permission gate is needed.
- [x] Update `docs/API_REFERENCE.md` and all four READMEs with measured versus estimated semantics, request bounds and missing-data behavior. Refresh affected synthetic native screenshots; inspect them for PII.
- [ ] Commit with issue reference and Codex co-author, push the existing feature branch, and inspect CI status. No merge, release or issue closure.
- [ ] Fetch/compare origin/main, inspect packaging/install effects, preserve selected signing identity, back up app/settings, package and replace the local app. Verify signature, executable hash, preferences and native current readings through existing login.
- [ ] Update #148 with evidence and remaining limitations; stop task-owned review jobs and preview servers.
