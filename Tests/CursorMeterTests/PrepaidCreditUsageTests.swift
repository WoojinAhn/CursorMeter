import XCTest
@testable import CursorMeter

final class PrepaidCreditUsageTests: XCTestCase {
    func testRefreshedPurchaseSnapshotPreservesConsumedAmount() {
        let initial = PrepaidCreditUsage(remainingCents: 1240, totalPurchasedCents: 2000)
        let refreshed = PrepaidCreditUsage(remainingCents: 3240, totalPurchasedCents: 4000)

        XCTAssertEqual(initial.remainingCents, 1240)
        XCTAssertEqual(initial.totalPurchasedCents, 2000)
        XCTAssertEqual(initial.consumedCents, 760)
        XCTAssertEqual(initial.percentUsed, 38)
        XCTAssertEqual(refreshed.remainingCents, 3240)
        XCTAssertEqual(refreshed.totalPurchasedCents, 4000)
        XCTAssertEqual(refreshed.consumedCents, 760)
        XCTAssertEqual(refreshed.percentUsed, 19)
        XCTAssertFalse(initial.hasNoPurchases)
        XCTAssertFalse(refreshed.hasNoPurchases)
    }

    func testUnknownPurchaseTotalPreservesBalance() {
        for balance: Decimal in [1240, 0] {
            let usage = PrepaidCreditUsage(remainingCents: balance, totalPurchasedCents: nil)

            XCTAssertEqual(usage.remainingCents, balance)
            XCTAssertNil(usage.totalPurchasedCents)
            XCTAssertNil(usage.consumedCents)
            XCTAssertNil(usage.percentUsed)
            XCTAssertFalse(usage.hasNoPurchases)
        }
    }

    func testKnownZeroAmountsConfirmNoPurchases() {
        let usage = PrepaidCreditUsage(remainingCents: 0, totalPurchasedCents: 0)

        XCTAssertEqual(usage.remainingCents, 0)
        XCTAssertEqual(usage.totalPurchasedCents, 0)
        XCTAssertEqual(usage.consumedCents, 0)
        XCTAssertNil(usage.percentUsed)
        XCTAssertTrue(usage.hasNoPurchases)
    }

    func testExhaustedPurchaseIsFullyUsed() {
        let usage = PrepaidCreditUsage(remainingCents: 0, totalPurchasedCents: 2000)

        XCTAssertEqual(usage.consumedCents, 2000)
        XCTAssertEqual(usage.percentUsed, 100)
        XCTAssertFalse(usage.hasNoPurchases)
    }

    func testBalanceAbovePurchaseTotalRemainsUnreconciled() {
        let usage = PrepaidCreditUsage(remainingCents: 3000, totalPurchasedCents: 2000)

        XCTAssertEqual(usage.remainingCents, 3000)
        XCTAssertEqual(usage.totalPurchasedCents, 2000)
        XCTAssertNil(usage.consumedCents)
        XCTAssertNil(usage.percentUsed)
        XCTAssertFalse(usage.hasNoPurchases)
    }

    func testNegativeBalanceIsUnknown() {
        let usage = PrepaidCreditUsage(remainingCents: -1, totalPurchasedCents: 2000)

        XCTAssertNil(usage.remainingCents)
        XCTAssertEqual(usage.totalPurchasedCents, 2000)
        XCTAssertNil(usage.consumedCents)
        XCTAssertNil(usage.percentUsed)
        XCTAssertFalse(usage.hasNoPurchases)
    }

    func testNegativePurchaseTotalPreservesBalance() {
        let usage = PrepaidCreditUsage(remainingCents: 1240, totalPurchasedCents: -1)

        XCTAssertEqual(usage.remainingCents, 1240)
        XCTAssertNil(usage.totalPurchasedCents)
        XCTAssertNil(usage.consumedCents)
        XCTAssertNil(usage.percentUsed)
        XCTAssertFalse(usage.hasNoPurchases)
    }

    func testNaNBalanceIsUnknown() {
        let usage = PrepaidCreditUsage(remainingCents: .nan, totalPurchasedCents: 2000)

        XCTAssertNil(usage.remainingCents)
        XCTAssertEqual(usage.totalPurchasedCents, 2000)
        XCTAssertNil(usage.consumedCents)
        XCTAssertNil(usage.percentUsed)
        XCTAssertFalse(usage.hasNoPurchases)
    }

    func testNaNPurchaseTotalPreservesBalance() {
        let usage = PrepaidCreditUsage(remainingCents: 1240, totalPurchasedCents: .nan)

        XCTAssertEqual(usage.remainingCents, 1240)
        XCTAssertNil(usage.totalPurchasedCents)
        XCTAssertNil(usage.consumedCents)
        XCTAssertNil(usage.percentUsed)
        XCTAssertFalse(usage.hasNoPurchases)
    }

    func testMissingBalanceDoesNotConfirmNoPurchases() {
        for total: Decimal? in [nil, 0, 2000] {
            let usage = PrepaidCreditUsage(remainingCents: nil, totalPurchasedCents: total)

            XCTAssertNil(usage.remainingCents)
            XCTAssertEqual(usage.totalPurchasedCents, total)
            XCTAssertNil(usage.consumedCents)
            XCTAssertNil(usage.percentUsed)
            XCTAssertFalse(usage.hasNoPurchases)
        }
    }

    func testFractionalCentsUseDecimalArithmetic() throws {
        let balance = try XCTUnwrap(Decimal(string: "12.4"))
        let consumed = try XCTUnwrap(Decimal(string: "7.6"))
        let usage = PrepaidCreditUsage(remainingCents: balance, totalPurchasedCents: 20)

        XCTAssertEqual(usage.remainingCents, balance)
        XCTAssertEqual(usage.consumedCents, consumed)
        XCTAssertEqual(usage.percentUsed, 38)
        XCTAssertFalse(usage.hasNoPurchases)
    }

    func testUnusedPurchaseHasZeroPercentUsed() {
        let usage = PrepaidCreditUsage(remainingCents: 2000, totalPurchasedCents: 2000)

        XCTAssertEqual(usage.consumedCents, 0)
        XCTAssertEqual(usage.percentUsed, 0)
        XCTAssertFalse(usage.hasNoPurchases)
    }
}
