import XCTest
@testable import CursorMeter

final class UsageDisplayDataTests: XCTestCase {

    // MARK: - percentUsed

    func testPercentUsedNormal() {
        let data = makeData(used: 150, limit: 500)
        XCTAssertEqual(data.percentUsed, 30.0, accuracy: 0.01)
    }

    func testPercentUsedZeroLimit() {
        let data = makeData(used: 10, limit: 0)
        XCTAssertEqual(data.percentUsed, 0)
    }

    func testPercentUsedFull() {
        let data = makeData(used: 500, limit: 500)
        XCTAssertEqual(data.percentUsed, 100.0, accuracy: 0.01)
    }

    func testPercentUsedOverLimit() {
        let data = makeData(used: 600, limit: 500)
        XCTAssertEqual(data.percentUsed, 120.0, accuracy: 0.01)
    }

    // MARK: - percentText

    func testPercentText() {
        let data = makeData(used: 1, limit: 3)
        // 33.333...% → Int truncates to 33
        XCTAssertEqual(data.percentText, "33%")
    }

    func testPercentTextZero() {
        let data = makeData(used: 0, limit: 100)
        XCTAssertEqual(data.percentText, "0%")
    }

    // MARK: - usageText

    func testUsageText() {
        let data = makeData(used: 42, limit: 500)
        XCTAssertEqual(data.usageText, "42 / 500")
    }

    // MARK: - resetText

    func testResetTextNilDays() {
        let data = makeData(used: 0, limit: 100, daysUntilReset: nil)
        XCTAssertNil(data.resetText)
    }

    func testResetTextToday() {
        let data = makeData(used: 0, limit: 100, daysUntilReset: 0)
        XCTAssertEqual(data.resetText, "Resets today")
    }

    func testResetTextNegativeDays() {
        let data = makeData(used: 0, limit: 100, daysUntilReset: -1)
        XCTAssertEqual(data.resetText, "Resets today")
    }

    func testResetTextTomorrow() {
        let data = makeData(used: 0, limit: 100, daysUntilReset: 1)
        XCTAssertEqual(data.resetText, "Resets tomorrow")
    }

    func testResetTextMultipleDays() {
        let data = makeData(used: 0, limit: 100, daysUntilReset: 14)
        XCTAssertEqual(data.resetText, "Resets in 14 days")
    }

    // MARK: - from(usage:userInfo:) legacy factory

    func testFromWithValidData() {
        let usage = makeUsageResponse(numRequests: 42, maxRequestUsage: 500)
        let userInfo = UserInfoResponse(email: "test@example.com", name: "Test User")

        let data = UsageDisplayData.from(usage: usage, userInfo: userInfo)

        XCTAssertEqual(data.email, "test@example.com")
        XCTAssertEqual(data.name, "Test User")
        XCTAssertEqual(data.requestsUsed, 42)
        XCTAssertEqual(data.requestsLimit, 500)
    }

    func testFromWithNilFields() {
        let usage = makeUsageResponse(models: [:], startOfMonth: nil)
        let userInfo = UserInfoResponse(email: nil, name: nil)

        let data = UsageDisplayData.from(usage: usage, userInfo: userInfo)

        XCTAssertEqual(data.email, "Unknown")
        XCTAssertEqual(data.name, "Unknown")
        XCTAssertEqual(data.requestsUsed, 0)
        XCTAssertEqual(data.requestsLimit, 0)
        XCTAssertNil(data.resetDate)
        XCTAssertNil(data.daysUntilReset)
    }

    func testFromWithNilModelUsageFields() {
        let usage = makeUsageResponse(numRequests: nil, maxRequestUsage: nil)
        let userInfo = UserInfoResponse(email: "a@b.com", name: "AB")

        let data = UsageDisplayData.from(usage: usage, userInfo: userInfo)

        XCTAssertEqual(data.requestsUsed, 0)
        XCTAssertEqual(data.requestsLimit, 0)
    }

    func testFromParsesStartOfMonth() {
        let usage = makeUsageResponse(
            numRequests: 10,
            maxRequestUsage: 100,
            startOfMonth: "2099-01-01T00:00:00.000Z"
        )
        let userInfo = UserInfoResponse(email: "u@e.com", name: "U")

        let data = UsageDisplayData.from(usage: usage, userInfo: userInfo)

        XCTAssertNotNil(data.resetDate, "resetDate should be parsed from startOfMonth")
        XCTAssertNotNil(data.daysUntilReset)

        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: data.resetDate!)
        XCTAssertEqual(components.year, 2099)
        XCTAssertEqual(components.month, 2)
    }

    func testFromWithInvalidDateString() {
        let usage = makeUsageResponse(
            numRequests: 5,
            maxRequestUsage: 50,
            startOfMonth: "not-a-date"
        )
        let userInfo = UserInfoResponse(email: "u@e.com", name: "U")

        let data = UsageDisplayData.from(usage: usage, userInfo: userInfo)

        XCTAssertNil(data.resetDate)
        XCTAssertNil(data.daysUntilReset)
    }

    // MARK: - from(summary:usage:userInfo:) integrated factory

    func testFromSummaryWithUsage() {
        let summary = makeSummaryResponse(billingCycleEnd: "2099-04-01T00:00:00.000Z")
        let usage = makeUsageResponse(
            numRequests: 10, numRequestsTotal: 15, maxRequestUsage: 500
        )
        let userInfo = UserInfoResponse(email: "alice@test.com", name: "Alice")

        let data = UsageDisplayData.from(summary: summary, usage: usage, userInfo: userInfo)

        XCTAssertEqual(data.email, "alice@test.com")
        XCTAssertEqual(data.name, "Alice")
        XCTAssertEqual(data.requestsUsed, 15, "Should prefer numRequestsTotal over numRequests")
        XCTAssertEqual(data.requestsLimit, 500)
        XCTAssertNotNil(data.resetDate)
    }

    func testFromSummaryWithoutUsage() {
        let summary = makeSummaryResponse(billingCycleEnd: "2099-04-01T00:00:00.000Z")
        let userInfo = UserInfoResponse(email: "bob@test.com", name: "Bob")

        let data = UsageDisplayData.from(summary: summary, usage: nil, userInfo: userInfo)

        XCTAssertEqual(data.email, "bob@test.com")
        XCTAssertEqual(data.requestsUsed, 0)
        XCTAssertEqual(data.requestsLimit, 0)
    }

    func testFromSummaryParsesBillingCycleEnd() {
        let summary = makeSummaryResponse(billingCycleEnd: "2099-06-15T12:30:00.000Z")
        let userInfo = UserInfoResponse(email: "u@e.com", name: "U")

        let data = UsageDisplayData.from(summary: summary, usage: nil, userInfo: userInfo)

        XCTAssertNotNil(data.resetDate)
        let components = Calendar.current.dateComponents([.year, .month, .day], from: data.resetDate!)
        XCTAssertEqual(components.year, 2099)
        XCTAssertEqual(components.month, 6)
        XCTAssertEqual(components.day, 15)
    }

    func testFromSummaryNilBillingCycleEnd() {
        let summary = makeSummaryResponse(billingCycleEnd: nil)
        let userInfo = UserInfoResponse(email: "u@e.com", name: "U")

        let data = UsageDisplayData.from(summary: summary, usage: nil, userInfo: userInfo)

        XCTAssertNil(data.resetDate)
        XCTAssertNil(data.daysUntilReset)
    }

    // MARK: - Dynamic key parsing (primaryModel)

    func testPrimaryModelPrefersMaxRequestUsage() {
        let usage = makeUsageResponse(models: [
            "some-model": ModelUsage(
                numRequests: 10, numRequestsTotal: nil, numTokens: nil,
                maxRequestUsage: nil, maxTokenUsage: nil
            ),
            "gpt-4": ModelUsage(
                numRequests: 5, numRequestsTotal: nil, numTokens: nil,
                maxRequestUsage: 500, maxTokenUsage: nil
            ),
        ])
        XCTAssertEqual(usage.primaryModel?.maxRequestUsage, 500)
        XCTAssertEqual(usage.primaryModel?.numRequests, 5)
    }

    func testPrimaryModelFallsBackToFirst() {
        let usage = makeUsageResponse(models: [
            "claude-4": ModelUsage(
                numRequests: 7, numRequestsTotal: nil, numTokens: nil,
                maxRequestUsage: nil, maxTokenUsage: nil
            ),
        ])
        XCTAssertEqual(usage.primaryModel?.numRequests, 7)
    }

    func testPrimaryModelNilWhenEmpty() {
        let usage = makeUsageResponse(models: [:])
        XCTAssertNil(usage.primaryModel)
    }

    // MARK: - Credit-based plan

    func testIsCreditBasedTrue() {
        let data = makeCreditData(usedCents: 800, limitCents: 2000)
        XCTAssertTrue(data.isCreditBased)
    }

    func testIsCreditBasedFalseForRequestPlan() {
        let data = makeData(used: 42, limit: 500)
        XCTAssertFalse(data.isCreditBased)
    }

    func testCreditPercentUsed() {
        let data = makeCreditData(usedCents: 800, limitCents: 2000)
        XCTAssertEqual(data.percentUsed, 40.0, accuracy: 0.01)
    }

    func testCreditPercentUsedZeroLimit() {
        let data = makeCreditData(usedCents: 100, limitCents: 0)
        XCTAssertFalse(data.isCreditBased)
        XCTAssertEqual(data.percentUsed, 0)
    }

    func testCreditUsageText() {
        let data = makeCreditData(usedCents: 800, limitCents: 2000)
        XCTAssertEqual(data.usageText, "$8.00 / $20.00")
    }

    func testCreditUsageTextSmallAmounts() {
        let data = makeCreditData(usedCents: 5, limitCents: 2000)
        XCTAssertEqual(data.usageText, "$0.05 / $20.00")
    }

    func testCreditUsageLabel() {
        let data = makeCreditData(usedCents: 800, limitCents: 2000)
        XCTAssertEqual(data.usageLabel, "Plan Usage")
    }

    func testRequestUsageLabel() {
        let data = makeData(used: 42, limit: 500)
        XCTAssertEqual(data.usageLabel, "Requests")
    }

    func testCreditPercentText() {
        let data = makeCreditData(usedCents: 800, limitCents: 2000)
        XCTAssertEqual(data.percentText, "40%")
    }

    // MARK: - from(summary:usage:) credit detection

    func testFromSummaryDetectsCreditBased() {
        let summary = makeSummaryResponse(
            billingCycleEnd: "2099-04-01T00:00:00.000Z",
            planUsed: 800,
            planLimit: 2000
        )
        // No maxRequestUsage → credit-based
        let usage = makeUsageResponse(numRequests: 10, maxRequestUsage: nil)
        let userInfo = UserInfoResponse(email: "pro@test.com", name: "Pro")

        let data = UsageDisplayData.from(summary: summary, usage: usage, userInfo: userInfo)

        XCTAssertTrue(data.isCreditBased)
        XCTAssertEqual(data.planUsedCents, 800)
        XCTAssertEqual(data.planLimitCents, 2000)
        XCTAssertEqual(data.requestsUsed, 0)
        XCTAssertEqual(data.requestsLimit, 0)
        XCTAssertEqual(data.usageText, "$8.00 / $20.00")
    }

    func testFromSummaryDetectsRequestBased() {
        let summary = makeSummaryResponse(
            billingCycleEnd: "2099-04-01T00:00:00.000Z",
            planUsed: nil,
            planLimit: nil
        )
        // maxRequestUsage present → request-based
        let usage = makeUsageResponse(numRequests: 42, maxRequestUsage: 500)
        let userInfo = UserInfoResponse(email: "ent@test.com", name: "Ent")

        let data = UsageDisplayData.from(summary: summary, usage: usage, userInfo: userInfo)

        XCTAssertFalse(data.isCreditBased)
        XCTAssertEqual(data.requestsUsed, 42)
        XCTAssertEqual(data.requestsLimit, 500)
        XCTAssertEqual(data.usageText, "42 / 500")
    }

    func testFromSummaryWithoutUsageIsCreditBased() {
        let summary = makeSummaryResponse(
            billingCycleEnd: "2099-04-01T00:00:00.000Z",
            planUsed: 150,
            planLimit: 6000
        )
        let userInfo = UserInfoResponse(email: "pro@test.com", name: "Pro")

        let data = UsageDisplayData.from(summary: summary, usage: nil, userInfo: userInfo)

        XCTAssertTrue(data.isCreditBased)
        XCTAssertEqual(data.planUsedCents, 150)
        XCTAssertEqual(data.planLimitCents, 6000)
        XCTAssertEqual(data.usageText, "$1.50 / $60.00")
    }

    // MARK: - Helpers

    private func makeData(
        used: Int,
        limit: Int,
        daysUntilReset: Int? = 5
    ) -> UsageDisplayData {
        UsageDisplayData(
            email: "test@test.com",
            name: "Test",
            membershipType: nil,
            planUsedCents: nil,
            planLimitCents: nil,
            serverPercentUsed: nil,
            requestsUsed: used,
            requestsLimit: limit,
            onDemandUsedCents: nil,
            onDemandLimitCents: nil,
            resetDate: nil,
            daysUntilReset: daysUntilReset
        )
    }

    // MARK: - menuBarUsedText / menuBarLimitText

    func testMenuBarTextRequestBased() {
        let data = makeData(used: 150, limit: 500)
        XCTAssertEqual(data.menuBarUsedText, "150")
        XCTAssertEqual(data.menuBarLimitText, "500")
    }

    func testMenuBarTextCreditBased() {
        let data = makeCreditData(usedCents: 1250, limitCents: 5000)
        XCTAssertEqual(data.menuBarUsedText, "12.5")
        XCTAssertEqual(data.menuBarLimitText, "50.0")
    }

    func testMenuBarTextCreditSmallAmount() {
        let data = makeCreditData(usedCents: 5, limitCents: 100)
        XCTAssertEqual(data.menuBarUsedText, "0.1")
        XCTAssertEqual(data.menuBarLimitText, "1.0")
    }

    func testMenuBarTextCreditZero() {
        let data = makeCreditData(usedCents: 0, limitCents: 5000)
        XCTAssertEqual(data.menuBarUsedText, "0.0")
        XCTAssertEqual(data.menuBarLimitText, "50.0")
    }

    // MARK: - formatCompactUSD

    func testFormatCompactUSD() {
        XCTAssertEqual(UsageDisplayData.formatCompactUSD(1250), "12.5")
        XCTAssertEqual(UsageDisplayData.formatCompactUSD(5000), "50.0")
        XCTAssertEqual(UsageDisplayData.formatCompactUSD(0), "0.0")
        XCTAssertEqual(UsageDisplayData.formatCompactUSD(99), "1.0")
    }

    // MARK: - serverPercentUsed

    func testPaidPlanIgnoresServerPercent() {
        let data = makeCreditData(usedCents: 800, limitCents: 2000, serverPercent: 3.0)
        XCTAssertEqual(data.percentUsed, 40.0, accuracy: 0.01, "Paid plan should use local calculation, not server value")
    }

    func testPercentOnlyUsesServerPercent() {
        let data = UsageDisplayData(
            email: "test@test.com", name: "Test", membershipType: "free",
            planUsedCents: nil, planLimitCents: nil, serverPercentUsed: 5.5,
            requestsUsed: 0, requestsLimit: 0,
            onDemandUsedCents: nil, onDemandLimitCents: nil,
            resetDate: nil, daysUntilReset: 5
        )
        XCTAssertTrue(data.isPercentOnly)
        XCTAssertEqual(data.percentUsed, 5.5, accuracy: 0.01)
    }

    // MARK: - Free plan (serverPercentUsed only)

    func testFromSummaryFreePlanUsesServerPercent() {
        let summary = makeSummaryResponse(
            billingCycleEnd: "2099-04-15T00:00:00.000Z",
            membershipType: "free",
            planUsed: 0,
            planLimit: 0,
            totalPercentUsed: 5.5
        )
        let usage = makeUsageResponse(numRequests: 0, maxRequestUsage: nil)
        let userInfo = UserInfoResponse(email: "free@test.com", name: "Free")

        let data = UsageDisplayData.from(summary: summary, usage: usage, userInfo: userInfo)

        XCTAssertEqual(data.percentUsed, 5.5, accuracy: 0.01)
        XCTAssertEqual(data.percentText, "5%")
        XCTAssertEqual(data.membershipType, "free")
    }

    func testFreePlanUsageTextShowsPercentOnly() {
        let summary = makeSummaryResponse(
            billingCycleEnd: "2099-04-15T00:00:00.000Z",
            membershipType: "free",
            planUsed: 0,
            planLimit: 0,
            totalPercentUsed: 5.5
        )
        let userInfo = UserInfoResponse(email: "free@test.com", name: "Free")

        let data = UsageDisplayData.from(summary: summary, usage: nil, userInfo: userInfo)

        XCTAssertEqual(data.usageText, "5%", "Free plan should show percent instead of 0 / 0")
    }

    func testFreePlanMenuBarText() {
        let summary = makeSummaryResponse(
            billingCycleEnd: "2099-04-15T00:00:00.000Z",
            membershipType: "free",
            planUsed: 0,
            planLimit: 0,
            totalPercentUsed: 5.5
        )
        let userInfo = UserInfoResponse(email: "free@test.com", name: "Free")

        let data = UsageDisplayData.from(summary: summary, usage: nil, userInfo: userInfo)

        XCTAssertEqual(data.menuBarUsedText, "5%")
        XCTAssertEqual(data.menuBarLimitText, "")
    }

    // MARK: - Helpers

    private func makeCreditData(
        usedCents: Int,
        limitCents: Int,
        serverPercent: Double? = nil,
        daysUntilReset: Int? = 5
    ) -> UsageDisplayData {
        UsageDisplayData(
            email: "test@test.com",
            name: "Test",
            membershipType: "pro",
            planUsedCents: usedCents,
            planLimitCents: limitCents,
            serverPercentUsed: serverPercent,
            requestsUsed: 0,
            requestsLimit: 0,
            onDemandUsedCents: nil,
            onDemandLimitCents: nil,
            resetDate: nil,
            daysUntilReset: daysUntilReset
        )
    }

    private func makeUsageResponse(
        numRequests: Int? = nil,
        numRequestsTotal: Int? = nil,
        maxRequestUsage: Int? = nil,
        startOfMonth: String? = nil
    ) -> UsageResponse {
        let model = ModelUsage(
            numRequests: numRequests,
            numRequestsTotal: numRequestsTotal,
            numTokens: nil,
            maxRequestUsage: maxRequestUsage,
            maxTokenUsage: nil
        )
        return UsageResponse(
            models: ["gpt-4": model],
            startOfMonth: startOfMonth
        )
    }

    private func makeUsageResponse(
        models: [String: ModelUsage],
        startOfMonth: String? = nil
    ) -> UsageResponse {
        UsageResponse(models: models, startOfMonth: startOfMonth)
    }

    private func makeSummaryResponse(
        billingCycleEnd: String?,
        membershipType: String? = nil,
        planUsed: Int? = nil,
        planLimit: Int? = nil,
        totalPercentUsed: Double? = nil
    ) -> UsageSummaryResponse {
        let plan: PlanUsage? = (planUsed != nil || planLimit != nil || totalPercentUsed != nil)
            ? PlanUsage(enabled: true, used: planUsed, limit: planLimit, remaining: nil, totalPercentUsed: totalPercentUsed)
            : nil
        let individual: IndividualUsage? = plan != nil
            ? IndividualUsage(plan: plan, onDemand: nil)
            : nil
        return UsageSummaryResponse(
            billingCycleStart: nil,
            billingCycleEnd: billingCycleEnd,
            membershipType: membershipType,
            limitType: nil,
            isUnlimited: nil,
            individualUsage: individual,
            teamUsage: nil
        )
    }
}
