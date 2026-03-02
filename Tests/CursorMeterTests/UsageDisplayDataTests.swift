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
            requestsUsed: used,
            requestsLimit: limit,
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
        billingCycleEnd: String?
    ) -> UsageSummaryResponse {
        UsageSummaryResponse(
            billingCycleStart: nil,
            billingCycleEnd: billingCycleEnd,
            membershipType: nil,
            limitType: nil,
            isUnlimited: nil,
            individualUsage: nil,
            teamUsage: nil
        )
    }
}
