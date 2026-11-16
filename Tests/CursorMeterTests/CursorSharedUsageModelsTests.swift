import XCTest
@testable import CursorMeter

final class CursorSharedUsageModelsTests: XCTestCase {
    private func decode<T: Decodable>(_ json: String, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testPlanClassificationUsesMergedFlagAndWeeklyPeriodOnly() throws {
        let weekly: CursorPlanInfoResponse = try decode(#"{"isMerged":true,"planInfo":{"planName":"Any display name","includedUsagePeriod":"INCLUDED_USAGE_PERIOD_WEEKLY"}}"#)
        XCTAssertEqual(weekly.classification, .sharedWeekly)
        for period in ["INCLUDED_USAGE_PERIOD_MONTHLY", "INCLUDED_USAGE_PERIOD_UNSPECIFIED", "FUTURE_PERIOD"] {
            let merged: CursorPlanInfoResponse = try decode("{\"isMerged\":true,\"planInfo\":{\"includedUsagePeriod\":\"\(period)\"}}")
            XCTAssertEqual(merged.classification, .unsupported)
        }
        let missingPeriod: CursorPlanInfoResponse = try decode(#"{"isMerged":true}"#)
        XCTAssertEqual(missingPeriod.classification, .unsupported)
        let legacy: CursorPlanInfoResponse = try decode(#"{"planInfo":{"planName":"Weekly","includedUsagePeriod":"INCLUDED_USAGE_PERIOD_MONTHLY"}}"#)
        XCTAssertEqual(legacy.classification, .legacy)
    }

    func testEmptyAndMalformedPlanAreNotLegacy() {
        for json in ["{}", #"{"planInfo":{}}"#, #"{"isMerged":"true"}"#, #"{"planInfo":null}"#, #"{"isMerged":null}"#] {
            XCTAssertThrowsError(try decode(json, as: CursorPlanInfoResponse.self), json)
        }
    }

    func testMergedPlanWithMissingPeriodCannotBecomeLegacy() throws {
        let response: CursorPlanInfoResponse = try decode(#"{"isMerged":true,"planInfo":{"planName":"Plan"}}"#)
        XCTAssertEqual(response.classification, .unsupported)
    }

    func testMalformedOptionalHistoryTimestampSuppressesOnlyDenominator() throws {
        let record = String(purchase(ticket: "1", amount: "10000").dropLast()) + #", "succeededAtMs":"invalid"}"#
        let response: CursorPrepaidBillingResponse = try decode(prepaid(records: [record]))
        XCTAssertEqual(response.creditUsage.remainingCents, 6200)
        XCTAssertNil(response.creditUsage.totalPurchasedCents)
    }

    func testWeeklyUsesTotalPercentAndCoherentReset() throws {
        let plan: CursorPlanInfoResponse = try decode(#"{"isMerged":true,"planInfo":{"includedUsagePeriod":"INCLUDED_USAGE_PERIOD_WEEKLY","includedUsageResetsAt":"1794873600000"}}"#)
        let period: CurrentPeriodUsageResponse = try decode(#"{"billingCycleStart":"2026-11-10T00:00:00Z","billingCycleEnd":"2026-11-17T00:00:00Z","planUsage":{"autoPercentUsed":90,"apiPercentUsed":70,"totalPercentUsed":0}}"#)
        let usage = try XCTUnwrap(plan.weeklyUsage(from: period))
        XCTAssertEqual(usage.percentUsed, 0)
        XCTAssertNotNil(usage.period)
        XCTAssertEqual(usage.hasIncludedUsage(at: Date(timeIntervalSince1970: 1794873500)), true)
        XCTAssertNil(usage.hasIncludedUsage(at: Date(timeIntervalSince1970: 1794873600)))
        let missing: CurrentPeriodUsageResponse = try decode(#"{"billingCycleStart":"1794268800000","billingCycleEnd":"1794873600000","planUsage":{"autoPercentUsed":90,"apiPercentUsed":70}}"#)
        XCTAssertNil(plan.weeklyUsage(from: missing)?.percentUsed)
        let mismatch: CurrentPeriodUsageResponse = try decode(#"{"billingCycleStart":"1794268800000","billingCycleEnd":"1794873600001","planUsage":{"totalPercentUsed":12}}"#)
        XCTAssertNil(plan.weeklyUsage(from: mismatch)?.period)
        XCTAssertNil(plan.weeklyUsage(from: mismatch)?.percentUsed)
    }

    func testPrepaidReconcilesFundedBalanceAndSuccessfulPurchases() throws {
        let response: CursorPrepaidBillingResponse = try decode(prepaid(records: [purchase(ticket: "1", amount: "10000")]))
        XCTAssertEqual(response.creditUsage.remainingCents, 6200)
        XCTAssertEqual(response.creditUsage.totalPurchasedCents, 10000)
        XCTAssertEqual(response.creditUsage.percentUsed, 38)
        XCTAssertEqual(response.monthlyUsedCents, 700)
    }

    func testTruncatedOrMissingHistoryCannotBePurchaseDenominator() throws {
        for records in [[], [purchase(ticket: "1", amount: "5000")]] {
            let response: CursorPrepaidBillingResponse = try decode(prepaid(records: records))
            XCTAssertEqual(response.creditUsage.remainingCents, 6200)
            XCTAssertEqual(response.monthlyUsedCents, 700)
            XCTAssertNil(response.creditUsage.totalPurchasedCents)
        }
    }

    func testLedgerMismatchSuppressesOnlyDenominator() throws {
        let json = prepaid(records: [purchase(ticket: "1", amount: "10000")]).replacingOccurrences(of: "\"3800\"", with: "\"3799\"")
        let response: CursorPrepaidBillingResponse = try decode(json)
        XCTAssertEqual(response.creditUsage.remainingCents, 6200)
        XCTAssertEqual(response.monthlyUsedCents, 700)
        XCTAssertNil(response.creditUsage.totalPurchasedCents)
    }

    func testIdenticalTicketsDeduplicateAndConflictingTicketsInvalidateCoverage() throws {
        let record = purchase(ticket: "1", amount: "10000")
        let identical: CursorPrepaidBillingResponse = try decode(prepaid(records: [record, record]))
        XCTAssertEqual(identical.creditUsage.totalPurchasedCents, 10000)
        let conflict: CursorPrepaidBillingResponse = try decode(prepaid(records: [record, purchase(ticket: "1", amount: "5000")]))
        XCTAssertNil(conflict.creditUsage.totalPurchasedCents)
    }

    func testUnknownOriginsStatusesAndInvalidRecordsSuppressOnlyDenominator() throws {
        for record in [purchase(ticket: "2", amount: "1", origin: "TOPUP_AUTO"), purchase(ticket: "2", amount: "1", origin: "GRANT"), purchase(ticket: "2", amount: "1", status: "FUTURE"), "null", #"{"ticket":"2"}"#] {
            let response: CursorPrepaidBillingResponse = try decode(prepaid(records: [purchase(ticket: "1", amount: "10000"), record]))
            XCTAssertNil(response.creditUsage.totalPurchasedCents)
            XCTAssertEqual(response.creditUsage.remainingCents, 6200)
            XCTAssertEqual(response.monthlyUsedCents, 700)
        }
    }

    func testConfirmedPendingAndFailedPurchasesDoNotChangeSuccessfulTotal() throws {
        let response: CursorPrepaidBillingResponse = try decode(prepaid(records: [purchase(ticket: "1", amount: "10000"), purchase(ticket: "2", amount: "10000", status: "PENDING"), purchase(ticket: "3", amount: "10000", status: "FAILED")]))
        XCTAssertEqual(response.creditUsage.totalPurchasedCents, 10000)
    }

    func testProtoZerosApplyOnlyToRecognizedEligiblePrepaidEnvelope() throws {
        let zero: CursorPrepaidBillingResponse = try decode(#"{"billingMode":"PREPAID_BILLING_MODE_PREPAID","eligible":true}"#)
        XCTAssertEqual(zero.creditUsage.remainingCents, 0)
        XCTAssertTrue(zero.creditUsage.hasNoPurchases)
        XCTAssertNil(zero.monthlyUsedCents)
        XCTAssertNil(zero.autoTopUp)
        for json in ["{}", #"{"billingMode":"PREPAID_BILLING_MODE_PREPAID"}"#, #"{"billingMode":"PREPAID_BILLING_MODE_ON_DEMAND","eligible":true}"#, #"{"billingMode":"FUTURE","eligible":true}"#] {
            let response: CursorPrepaidBillingResponse = try decode(json)
            XCTAssertNil(response.creditUsage.remainingCents)
            XCTAssertNil(response.creditUsage.totalPurchasedCents)
        }
    }

    func testStrictMoneyDecodingKeepsIndependentValidAmounts() throws {
        for raw in ["-1", "1.5", "0.99999999999999999999", "1.00000000000000000001", "9223372036854775808", "\"1.5\"", "\"-1\"", "\"1e3\"", "true", "null"] {
            let response: CursorPrepaidBillingResponse = try decode("{\"billingMode\":\"PREPAID_BILLING_MODE_PREPAID\",\"eligible\":true,\"availableCents\":\(raw),\"spentThisMonthCents\":700}")
            XCTAssertNil(response.creditUsage.remainingCents, raw)
            XCTAssertNil(response.creditUsage.totalPurchasedCents, raw)
            XCTAssertEqual(response.monthlyUsedCents, 700, raw)
        }
        let exact: CursorPrepaidBillingResponse = try decode(#"{"billingMode":"PREPAID_BILLING_MODE_PREPAID","eligible":true,"availableCents":"9223372036854775807","spentThisMonthCents":0}"#)
        XCTAssertEqual(exact.creditUsage.remainingCents, Decimal(Int64.max))
        XCTAssertEqual(exact.monthlyUsedCents, 0)
    }

    func testAutoTopUpPresenceAndDisabledStateAreIndependentOfPaidCap() throws {
        let response: CursorPrepaidBillingResponse = try decode(#"{"billingMode":"PREPAID_BILLING_MODE_PREPAID","eligible":true,"autoTopUp":{"thresholdCents":"200","topUpAmountCents":500,"monthlyCapCents":"3000"}}"#)
        XCTAssertEqual(response.autoTopUp?.enabled, false)
        XCTAssertEqual(response.autoTopUp?.thresholdCents, 200)
        XCTAssertEqual(response.autoTopUp?.topUpAmountCents, 500)
        XCTAssertEqual(response.autoTopUp?.monthlyCapCents, 3000)
        let absentCap: CursorPrepaidBillingResponse = try decode(#"{"autoTopUp":{"enabled":true}}"#)
        XCTAssertNil(absentCap.autoTopUp?.monthlyCapCents)
    }

    func testPaidCapUsesDollarsAndOfficialSentinel() throws {
        for (json, cap) in [(#"{"hardLimit":25}"#, SharedPaidCap.limited(2500)), (#"{"hardLimit":25.5}"#, .unknown), (#"{"hardLimit":0}"#, .limited(0)), (#"{"hardLimit":-1}"#, .limited(0)), (#"{"hardLimit":2147483647}"#, .uncapped), (#"{"hardLimit":2147483648}"#, .unknown), (#"{"hardLimit":-2147483649}"#, .unknown), (#"{"noUsageBasedAllowed":true}"#, .limited(0)), (#"{"noUsageBasedAllowed":true,"hardLimit":2147483647}"#, .limited(0)), ("{}", .unknown), (#"{"hardLimit":"25"}"#, .unknown), (#"{"hardLimit":null}"#, .unknown)] {
            let response: CursorPaidCapResponse = try decode(json)
            XCTAssertEqual(response.cap, cap, json)
        }
    }

    func testNearIntegerPaidCapsAreUnknown() throws {
        for raw in ["0.99999999999999999999", "1.00000000000000000001"] {
            let response: CursorPaidCapResponse = try decode("{\"hardLimit\":\(raw)}")
            XCTAssertEqual(response.cap, .unknown, raw)
        }
    }

    private func purchase(ticket: String, amount: String, origin: String = "TOPUP_MANUAL", status: String = "SUCCEEDED") -> String {
        "{\"ticket\":\"\(ticket)\",\"origin\":\"\(origin)\",\"amountCents\":\"\(amount)\",\"status\":\"\(status)\",\"createdAtMs\":\"1794268800000\"}"
    }

    private func prepaid(records: [String]) -> String {
        "{\"billingMode\":\"PREPAID_BILLING_MODE_PREPAID\",\"eligible\":true,\"availableCents\":\"6200\",\"fundedCents\":\"10000\",\"spentCents\":\"3800\",\"spentThisMonthCents\":700,\"topUps\":[\(records.joined(separator: ","))]}"
    }
}
