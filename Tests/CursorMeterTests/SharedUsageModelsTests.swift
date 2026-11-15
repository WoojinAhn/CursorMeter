import XCTest
@testable import CursorMeter

final class SharedUsageModelsTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let week: TimeInterval = 7 * 24 * 60 * 60

    private var period: UsageCycle {
        UsageCycle(start: start, end: start.addingTimeInterval(week))!
    }

    func testActiveWeekHasIncludedUsageBelowOneHundredPercent() {
        for percent in [0.0, 35.5, 99.999] {
            let usage = SharedWeeklyUsage(percentUsed: percent, period: period)

            XCTAssertEqual(usage.percentUsed, percent)
            XCTAssertEqual(usage.hasIncludedUsage(at: start.addingTimeInterval(1)), true)
        }
    }

    func testActiveWeekIsExhaustedAtOneHundredPercent() {
        let usage = SharedWeeklyUsage(percentUsed: 100, period: period)

        XCTAssertEqual(usage.percentUsed, 100)
        XCTAssertEqual(usage.hasIncludedUsage(at: start.addingTimeInterval(1)), false)
    }

    func testWeeklyPeriodIncludesStart() {
        let usage = SharedWeeklyUsage(percentUsed: 25, period: period)

        XCTAssertEqual(usage.hasIncludedUsage(at: period.start), true)
    }

    func testWeeklyPeriodExcludesEnd() {
        let usage = SharedWeeklyUsage(percentUsed: 25, period: period)

        XCTAssertNil(usage.hasIncludedUsage(at: period.end))
    }

    func testFutureWeekHasUnknownIncludedUsage() {
        let usage = SharedWeeklyUsage(percentUsed: 0, period: period)

        XCTAssertNil(usage.hasIncludedUsage(at: start.addingTimeInterval(-1)))
    }

    func testExpiredWeekHasUnknownIncludedUsage() {
        let usage = SharedWeeklyUsage(percentUsed: 0, period: period)

        XCTAssertNil(usage.hasIncludedUsage(at: period.end.addingTimeInterval(1)))
    }

    func testMissingWeeklyPercentageRemainsUnknown() {
        let usage = SharedWeeklyUsage(percentUsed: nil, period: period)

        XCTAssertNil(usage.percentUsed)
        XCTAssertEqual(usage.period, period)
        XCTAssertNil(usage.hasIncludedUsage(at: start))
    }

    func testMissingWeeklyPeriodPreservesPercentage() {
        let usage = SharedWeeklyUsage(percentUsed: 25, period: nil)

        XCTAssertEqual(usage.percentUsed, 25)
        XCTAssertNil(usage.period)
        XCTAssertNil(usage.hasIncludedUsage(at: start))
    }

    func testInvalidWeeklyPercentagesBecomeUnknown() {
        for percent in [-0.1, 100.1, Double.nan, .infinity, -.infinity] {
            let usage = SharedWeeklyUsage(percentUsed: percent, period: period)

            XCTAssertNil(usage.percentUsed)
            XCTAssertEqual(usage.period, period)
            XCTAssertNil(usage.hasIncludedUsage(at: start))
        }
    }

    func testUnknownPaidCapDoesNotInferLimitFromUsage() {
        for used: Decimal? in [nil, 0, 100] {
            let usage = SharedPaidUsage(usedCents: used, cap: .unknown)

            XCTAssertEqual(usage.usedCents, used)
            XCTAssertEqual(usage.cap, .unknown)
            XCTAssertNil(usage.isCapReached)
        }
    }

    func testUncappedPaidUsageNeverReachesCap() {
        for used: Decimal? in [nil, 0, 100] {
            let usage = SharedPaidUsage(usedCents: used, cap: .uncapped)

            XCTAssertEqual(usage.usedCents, used)
            XCTAssertEqual(usage.cap, .uncapped)
            XCTAssertEqual(usage.isCapReached, false)
        }
    }

    func testZeroPaidCapIsReachedEvenWhenUsageIsMissing() {
        for used: Decimal? in [nil, 0, 100] {
            let usage = SharedPaidUsage(usedCents: used, cap: .limited(0))

            XCTAssertEqual(usage.usedCents, used)
            XCTAssertEqual(usage.cap, .limited(0))
            XCTAssertEqual(usage.isCapReached, true)
        }
    }

    func testPositivePaidCapRequiresKnownUsage() {
        let usage = SharedPaidUsage(usedCents: nil, cap: .limited(100))

        XCTAssertNil(usage.usedCents)
        XCTAssertEqual(usage.cap, .limited(100))
        XCTAssertNil(usage.isCapReached)
    }

    func testKnownZeroPaidUsageIsBelowPositiveCap() {
        let usage = SharedPaidUsage(usedCents: 0, cap: .limited(100))

        XCTAssertEqual(usage.usedCents, 0)
        XCTAssertEqual(usage.isCapReached, false)
    }

    func testPositivePaidCapUsesExactDecimalThreshold() throws {
        let limit = try XCTUnwrap(Decimal(string: "100.1"))
        for (rawUsed, expected) in [("100.09", false), ("100.1", true), ("100.11", true)] {
            let used = try XCTUnwrap(Decimal(string: rawUsed))
            let usage = SharedPaidUsage(usedCents: used, cap: .limited(limit))

            XCTAssertEqual(usage.usedCents, used)
            XCTAssertEqual(usage.cap, .limited(limit))
            XCTAssertEqual(usage.isCapReached, expected)
        }
    }

    func testInvalidPaidUsageBecomesUnknownWithoutChangingCap() {
        for used: Decimal in [-1, .nan] {
            let usage = SharedPaidUsage(usedCents: used, cap: .limited(100))

            XCTAssertNil(usage.usedCents)
            XCTAssertEqual(usage.cap, .limited(100))
            XCTAssertNil(usage.isCapReached)
        }
    }

    func testInvalidPaidCapBecomesUnknownWithoutChangingUsage() {
        for limit: Decimal in [-1, .nan] {
            let usage = SharedPaidUsage(usedCents: 100, cap: .limited(limit))

            XCTAssertEqual(usage.usedCents, 100)
            XCTAssertEqual(usage.cap, .unknown)
            XCTAssertNil(usage.isCapReached)
        }
    }

    func testWeeklyResetPreservesLifetimeWalletSnapshot() {
        let wallet = PrepaidCreditUsage(remainingCents: 1240, totalPurchasedCents: 2000)
        let previous = (weekly: SharedWeeklyUsage(percentUsed: 100, period: period), wallet: wallet)
        let nextPeriod = UsageCycle(start: period.end, end: period.end.addingTimeInterval(week))!
        let refreshed = (weekly: SharedWeeklyUsage(percentUsed: 0, period: nextPeriod), wallet: wallet)

        XCTAssertEqual(previous.weekly.hasIncludedUsage(at: period.start), false)
        XCTAssertNil(previous.weekly.hasIncludedUsage(at: nextPeriod.start))
        XCTAssertEqual(refreshed.weekly.hasIncludedUsage(at: nextPeriod.start), true)
        XCTAssertEqual(refreshed.wallet, previous.wallet)
        XCTAssertEqual(refreshed.wallet.consumedCents, 760)
        XCTAssertEqual(refreshed.wallet.percentUsed, 38)
    }

    func testTopUpChangesWalletDenominatorIndependentlyOfWeeklyUsage() {
        let weekly = SharedWeeklyUsage(percentUsed: 55, period: period)
        let previous = (weekly: weekly, wallet: PrepaidCreditUsage(remainingCents: 1240, totalPurchasedCents: 2000))
        let refreshed = (weekly: weekly, wallet: PrepaidCreditUsage(remainingCents: 3240, totalPurchasedCents: 4000))

        XCTAssertEqual(refreshed.weekly, previous.weekly)
        XCTAssertEqual(refreshed.weekly.percentUsed, 55)
        XCTAssertEqual(refreshed.weekly.hasIncludedUsage(at: start), true)
        XCTAssertEqual(refreshed.wallet.consumedCents, previous.wallet.consumedCents)
        XCTAssertEqual(previous.wallet.percentUsed, 38)
        XCTAssertEqual(refreshed.wallet.percentUsed, 19)
    }

    func testTopUpDoesNotChangeReachedPaidCap() {
        let paid = SharedPaidUsage(usedCents: 100, cap: .limited(100))
        let previous = (paid: paid, wallet: PrepaidCreditUsage(remainingCents: 1240, totalPurchasedCents: 2000))
        let refreshed = (paid: paid, wallet: PrepaidCreditUsage(remainingCents: 3240, totalPurchasedCents: 4000))

        XCTAssertEqual(previous.wallet.percentUsed, 38)
        XCTAssertEqual(refreshed.wallet.percentUsed, 19)
        XCTAssertEqual(refreshed.paid.usedCents, previous.paid.usedCents)
        XCTAssertEqual(previous.paid.cap, .limited(100))
        XCTAssertEqual(refreshed.paid.cap, previous.paid.cap)
        XCTAssertEqual(previous.paid.isCapReached, true)
        XCTAssertEqual(refreshed.paid.isCapReached, true)
    }
}
