# Shared Usage Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Establish tested purchased-credit accounting and a separately typed shared-usage snapshot before connecting the verified Grok source to the native dual meter.

**Architecture:** Keep weekly consumption, prepaid purchases/balance and monthly paid limits independent. Introduce immutable Foundation-only domain types; never remap these meanings onto legacy Cursor/Other pools or their on-demand latch. Wire decoding and account/session ownership are separate tasks after this foundation.

**Tech Stack:** Swift 6, Foundation Decimal, XCTest, existing UsageCycle; no added dependencies.

**Issue and accepted design:** [#147](https://github.com/WoojinAhn/CursorMeter/issues/147), [design](../../design-147-shared-usage.md), [mockup](../../mockup-147.html). The user requested implementation after the dual-meter correction. Gemini 4 Argon High and Grok XHigh independently review the contract and subsequent implementation.

**Baseline:** isolated feature/147-shared-usage at origin/main efe90d0. `swift test`: 1107 tests, zero failures before production changes.

## Evidence boundary

The current authenticated CLI billing response proves a weekly-usage/balance transport exists. It does not prove cumulative purchases, monthly paid limits, or a complete ledger. A separate verified adapter must supply normalized domain values. Do not invent a wire `totalPurchased` field, silently infer purchase history, or ship fixture values. The native connection remains an explicit outstanding issue milestone; this foundation alone does not complete #147.

## Task 1: Purchased-credit accounting

**Files:**
- Create: `Sources/CursorMeter/PrepaidCreditUsage.swift`
- Create: `Tests/CursorMeterTests/PrepaidCreditUsageTests.swift`

- [x] Add the failing behavior tests. `PrepaidCreditUsage` accepts optional normalized Decimal USD cents. Unavailable purchase total leaves a valid balance visible. Negative/NaN values are unavailable; inconsistent balance above total cannot produce a percentage. Zero purchases and zero balance is a separate not-purchased state, while positive purchases with zero balance is fully consumed.

```swift
import XCTest
@testable import CursorMeter

final class PrepaidCreditUsageTests: XCTestCase {
    func testTopUpRecalculatesConsumptionFromCumulativePurchases() {
        let before = PrepaidCreditUsage(remainingCents: 1240, totalPurchasedCents: 2000)
        let after = PrepaidCreditUsage(remainingCents: 3240, totalPurchasedCents: 4000)
        XCTAssertEqual(before.consumedCents, 760)
        XCTAssertEqual(after.consumedCents, 760)
        XCTAssertEqual(before.percentUsed!, 38, accuracy: 0.000001)
        XCTAssertEqual(after.percentUsed!, 19, accuracy: 0.000001)
    }
    func testUnknownTotalPreservesBalanceWithoutPercentage() {
        let credit = PrepaidCreditUsage(remainingCents: 1240, totalPurchasedCents: nil)
        XCTAssertEqual(credit.remainingCents, 1240)
        XCTAssertNil(credit.consumedCents)
        XCTAssertNil(credit.percentUsed)
        XCTAssertFalse(credit.hasNoPurchases)
    }
    func testNeverPurchasedDiffersFromExhaustedCredit() {
        let empty = PrepaidCreditUsage(remainingCents: 0, totalPurchasedCents: 0)
        XCTAssertTrue(empty.hasNoPurchases)
        XCTAssertNil(empty.percentUsed)
        let used = PrepaidCreditUsage(remainingCents: 0, totalPurchasedCents: 2000)
        XCTAssertFalse(used.hasNoPurchases)
        XCTAssertEqual(used.percentUsed, 100)
    }
    func testUnreconciledAndInvalidInputsDoNotInventConsumption() {
        XCTAssertNil(PrepaidCreditUsage(remainingCents: 3000, totalPurchasedCents: 2000).percentUsed)
        XCTAssertNil(PrepaidCreditUsage(remainingCents: -1, totalPurchasedCents: 2000).remainingCents)
        XCTAssertNil(PrepaidCreditUsage(remainingCents: 1240, totalPurchasedCents: .nan).totalPurchasedCents)
        XCTAssertFalse(PrepaidCreditUsage(remainingCents: nil, totalPurchasedCents: 0).hasNoPurchases)
    }
    func testFractionalCentsRemainDecimalUntilPercentageRendering() {
        let credit = PrepaidCreditUsage(remainingCents: Decimal(string: "12.4"), totalPurchasedCents: 20)
        XCTAssertEqual(credit.consumedCents, Decimal(string: "7.6"))
        XCTAssertEqual(credit.percentUsed!, 38, accuracy: 0.000001)
    }
}
```

- [x] Run `swift test --filter PrepaidCreditUsageTests` and preserve the expected missing-type RED output. Add the type shell if needed to demonstrate a failing assertion before implementation; no placeholder should survive the task.
- [x] Implement the minimal model below, then run the focused tests to GREEN.

```swift
import Foundation

struct PrepaidCreditUsage: Equatable, Sendable {
    let remainingCents: Decimal?
    let totalPurchasedCents: Decimal?

    init(remainingCents: Decimal?, totalPurchasedCents: Decimal?) {
        self.remainingCents = Self.valid(remainingCents)
        self.totalPurchasedCents = Self.valid(totalPurchasedCents)
    }
    var consumedCents: Decimal? {
        guard let remainingCents, let totalPurchasedCents,
              remainingCents <= totalPurchasedCents else { return nil }
        return totalPurchasedCents - remainingCents
    }
    var percentUsed: Double? {
        guard let totalPurchasedCents, totalPurchasedCents > 0,
              let consumedCents else { return nil }
        return NSDecimalNumber(decimal: consumedCents / totalPurchasedCents * 100).doubleValue
    }
    var hasNoPurchases: Bool { totalPurchasedCents == 0 && remainingCents == 0 }
    private static func valid(_ value: Decimal?) -> Decimal? {
        guard let value, !value.isNaN, value >= 0 else { return nil }
        return value
    }
}
```

- [x] Spec review, followed by code-quality review. Address findings and rerun relevant tests.
- [x] Coordinator commits reviewed files with `[#147] feat: model prepaid credit consumption` and Codex attribution. Do not include shared documentation or unrelated files in an implementer commit.

## Task 2: Independent weekly and monthly quantities

**Files:**
- Create: `Sources/CursorMeter/SharedUsageModels.swift`
- Create: `Tests/CursorMeterTests/SharedUsageModelsTests.swift`

- [x] Write tests proving monthly cap exhaustion is independent of weekly availability and credit; `.unknown`, `.uncapped`, and `.limited(0)` are distinct. Weekly/monthly replacement does not mutate wallet totals. Period expiry invalidates availability claims rather than fabricating a new zero-usage cycle. Reject malformed percentages and negative/NaN monetary inputs.

```swift
import XCTest
@testable import CursorMeter

final class SharedUsageModelsTests: XCTestCase {
    func testCapStatesRemainDistinct() {
        XCTAssertNil(SharedPaidUsage(usedCents: 100, cap: .unknown).isCapReached)
        XCTAssertEqual(SharedPaidUsage(usedCents: 100, cap: .uncapped).isCapReached, false)
        XCTAssertEqual(SharedPaidUsage(usedCents: 0, cap: .limited(0)).isCapReached, true)
        XCTAssertEqual(SharedPaidUsage(usedCents: nil, cap: .limited(0)).isCapReached, true)
        XCTAssertEqual(SharedPaidUsage(usedCents: 2500, cap: .limited(2500)).isCapReached, true)
        XCTAssertNil(SharedPaidUsage(usedCents: nil, cap: .limited(2500)).isCapReached)
    }
    func testWeeklyPeriodDoesNotRollOverLocally() {
        let cycle = UsageCycle(start: Date(timeIntervalSince1970: 100), end: Date(timeIntervalSince1970: 200))!
        let weekly = SharedWeeklyUsage(percentUsed: 62.5, period: cycle)
        XCTAssertEqual(weekly.percentUsed, 62.5)
        XCTAssertEqual(weekly.hasIncludedUsage(at: Date(timeIntervalSince1970: 150)), true)
        XCTAssertNil(weekly.hasIncludedUsage(at: Date(timeIntervalSince1970: 200)))
    }
    func testInvalidReadingsRemainUnavailable() {
        XCTAssertNil(SharedWeeklyUsage(percentUsed: .nan, period: nil).percentUsed)
        XCTAssertNil(SharedWeeklyUsage(percentUsed: -1, period: nil).percentUsed)
        XCTAssertNil(SharedPaidUsage(usedCents: -1, cap: .limited(100)).usedCents)
        XCTAssertNil(SharedPaidUsage(usedCents: 0, cap: .limited(-1)).isCapReached)
    }
}
```

- [x] Run `swift test --filter SharedUsageModelsTests` to RED.
- [x] Implement the minimal independent quantities below. No wire decoding, legacy model edits, provider selection or fake monthly period is part of this task.

```swift
import Foundation

struct SharedWeeklyUsage: Equatable, Sendable {
    let percentUsed: Double?
    let period: UsageCycle?
    init(percentUsed: Double?, period: UsageCycle?) {
        self.percentUsed = percentUsed.flatMap { $0.isFinite && $0 >= 0 && $0 <= 100 ? $0 : nil }
        self.period = period
    }
    func hasIncludedUsage(at date: Date) -> Bool? {
        guard let period, period.start <= date, date < period.end, let percentUsed else { return nil }
        return percentUsed < 100
    }
}

enum SharedPaidCap: Equatable, Sendable {
    case unknown, uncapped, limited(Decimal)
}

struct SharedPaidUsage: Equatable, Sendable {
    let usedCents: Decimal?
    let cap: SharedPaidCap
    init(usedCents: Decimal?, cap: SharedPaidCap) {
        self.usedCents = usedCents.flatMap { !$0.isNaN && $0 >= 0 ? $0 : nil }
        if case .limited(let amount) = cap, amount.isNaN || amount < 0 {
            self.cap = .unknown
        } else {
            self.cap = cap
        }
    }
    var isCapReached: Bool? {
        switch cap {
        case .unknown: return nil
        case .uncapped: return false
        case .limited(let limit): return limit == 0 ? true : usedCents.map { $0 >= limit }
        }
    }
}
```

- [x] Run focused tests to GREEN, then `swift test` once after both tasks.
- [x] Spec review, then independent quality review. Coordinator commits reviewed model/test files with issue attribution.

## Following stage and delivery criteria

The next plan must pin the normalized snapshot scope, provider/session invalidation and verified wire contracts before adapter implementation. Known live response fields may be decoded, but unknown purchase total, monthly cap and Auto Top-up must remain unavailable. A raw successful response from `/auto-topup-rule` was `{}`; this is not proof that a rule is disabled. Exact `rule`-present proto3 false/zero semantics are documented by official source tests.

The user offered a minimum top-up for live QA. Capture and identify the read-only consumer ledger first, then use a user-performed purchase to verify credit added, total purchased, balance and the meter transition. Do not purchase on the user's behalf, request funds before an observable verification path exists, or substitute API Console team billing for the consumer wallet.

Finish the issue only after provider integration, live parity for weekly/credit readings, native accessibility screenshots, legacy regression tests, fresh Argon/Grok final review and authorized delivery. Native Chrome control has recovered; the browser-extension host remains unavailable. Dashboard ledger/schema observation succeeded, but app transport and posted-credit parity remain pending.
