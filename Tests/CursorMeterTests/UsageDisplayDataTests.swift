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

    // MARK: - from() factory

    func testFromWithValidData() {
        let usage = UsageResponse(
            gpt4: ModelUsage(numRequests: 42, maxRequestUsage: 500),
            startOfMonth: nil
        )
        let userInfo = UserInfoResponse(email: "test@example.com", name: "Test User")

        let data = UsageDisplayData.from(usage: usage, userInfo: userInfo)

        XCTAssertEqual(data.email, "test@example.com")
        XCTAssertEqual(data.name, "Test User")
        XCTAssertEqual(data.requestsUsed, 42)
        XCTAssertEqual(data.requestsLimit, 500)
    }

    func testFromWithNilFields() {
        let usage = UsageResponse(gpt4: nil, startOfMonth: nil)
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
        let usage = UsageResponse(
            gpt4: ModelUsage(numRequests: nil, maxRequestUsage: nil),
            startOfMonth: nil
        )
        let userInfo = UserInfoResponse(email: "a@b.com", name: "AB")

        let data = UsageDisplayData.from(usage: usage, userInfo: userInfo)

        XCTAssertEqual(data.requestsUsed, 0)
        XCTAssertEqual(data.requestsLimit, 0)
    }

    func testFromParsesStartOfMonth() {
        // Use a fixed date far in the future to ensure daysUntilReset > 0
        let usage = UsageResponse(
            gpt4: ModelUsage(numRequests: 10, maxRequestUsage: 100),
            startOfMonth: "2099-01-01T00:00:00.000Z"
        )
        let userInfo = UserInfoResponse(email: "u@e.com", name: "U")

        let data = UsageDisplayData.from(usage: usage, userInfo: userInfo)

        XCTAssertNotNil(data.resetDate, "resetDate should be parsed from startOfMonth")
        XCTAssertNotNil(data.daysUntilReset)

        // resetDate should be one month after startOfMonth (2099-02-01)
        let calendar = Calendar.current
        let components = calendar.dateComponents([.year, .month], from: data.resetDate!)
        XCTAssertEqual(components.year, 2099)
        XCTAssertEqual(components.month, 2)
    }

    func testFromWithInvalidDateString() {
        let usage = UsageResponse(
            gpt4: ModelUsage(numRequests: 5, maxRequestUsage: 50),
            startOfMonth: "not-a-date"
        )
        let userInfo = UserInfoResponse(email: "u@e.com", name: "U")

        let data = UsageDisplayData.from(usage: usage, userInfo: userInfo)

        XCTAssertNil(data.resetDate)
        XCTAssertNil(data.daysUntilReset)
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
            requestsUsed: used,
            requestsLimit: limit,
            resetDate: nil,
            daysUntilReset: daysUntilReset
        )
    }
}
