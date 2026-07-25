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
        // 33.333...% rounds to 33
        XCTAssertEqual(data.percentText, "33%")
    }

    func testPercentTextZero() {
        let data = makeData(used: 0, limit: 100)
        XCTAssertEqual(data.percentText, "0%")
    }

    func testPercentTextRoundsHalfUpLikeDashboard() {
        // #106: dashboard says "3%" for totalPercentUsed 2.5 — round, don't truncate.
        let data = makeData(used: 1, limit: 40) // 2.5%
        XCTAssertEqual(data.percentText, "3%")
    }

    func testPercentTextRoundsDown() {
        let data = makeData(used: 12, limit: 500) // 2.4%
        XCTAssertEqual(data.percentText, "2%")
    }

    // MARK: - resolvedMenuBarDisplayMode (#105)

    func testResolvedModeRespectsNoneOnPercentOnly() {
        XCTAssertEqual(UsageViewModel.resolvedMenuBarDisplayMode(isPercentOnly: true, setting: 0), 0)
    }

    func testResolvedModeCoercesRatioToPercentOnPercentOnly() {
        XCTAssertEqual(UsageViewModel.resolvedMenuBarDisplayMode(isPercentOnly: true, setting: 1), 2)
    }

    func testResolvedModePercentPassesThrough() {
        XCTAssertEqual(UsageViewModel.resolvedMenuBarDisplayMode(isPercentOnly: true, setting: 2), 2)
    }

    func testResolvedModeUntouchedWhenNotPercentOnly() {
        for mode in 0...2 {
            XCTAssertEqual(
                UsageViewModel.resolvedMenuBarDisplayMode(isPercentOnly: false, setting: mode),
                mode
            )
        }
    }

    // MARK: - usageText

    func testUsageText() {
        let data = makeData(used: 42, limit: 500)
        XCTAssertEqual(data.usageText, "42 / 500")
    }

    // MARK: - resetText

    func testResetTextNilWhenNoResetDate() {
        let data = makeData(used: 0, limit: 100)
        XCTAssertNil(data.resetText)
    }

    func testResetTextComputedFromResetDate() {
        let data = makeData(used: 0, limit: 100, resetDate: Date().addingTimeInterval(14 * 86400 + 3600))
        XCTAssertEqual(data.resetText, "Resets in 14 days")
    }

    // MARK: - resetCountdownText (#85 fine-grained countdown)

    private static let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)

    private func countdown(_ delta: TimeInterval) -> String {
        UsageDisplayData.resetCountdownText(
            until: Self.fixedNow.addingTimeInterval(delta),
            now: Self.fixedNow
        )
    }

    func testCountdownPastDeadline() {
        XCTAssertEqual(countdown(-3600), "Resets today")
        XCTAssertEqual(countdown(0), "Resets today")
    }

    func testCountdownSubMinute() {
        XCTAssertEqual(countdown(59), "Resets in <1m")
    }

    func testCountdownMinutes() {
        XCTAssertEqual(countdown(60), "Resets in 1m")
        XCTAssertEqual(countdown(40 * 60 + 30), "Resets in 40m")
        XCTAssertEqual(countdown(59 * 60 + 59), "Resets in 59m")
    }

    func testCountdownHours() {
        XCTAssertEqual(countdown(3600), "Resets in 1h")
        XCTAssertEqual(countdown(3600 + 60), "Resets in 1h")
        XCTAssertEqual(countdown(31 * 3600), "Resets in 31h")
        XCTAssertEqual(countdown(48 * 3600 - 60), "Resets in 47h")
    }

    func testCountdownDays() {
        XCTAssertEqual(countdown(48 * 3600), "Resets in 2 days")
        XCTAssertEqual(countdown(49 * 3600), "Resets in 2 days")
        XCTAssertEqual(countdown(14 * 86400), "Resets in 14 days")
    }

    // MARK: - resetAbsoluteText (#85 tooltip)

    func testResetAbsoluteTextFormat() {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 10
        components.hour = 7; components.minute = 24
        // Explicit Gregorian: the production formatter is pinned to Gregorian,
        // so building the fixture with Calendar.current would diverge on a
        // non-Gregorian system calendar (Japanese/Buddhist/etc.).
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .current
        let date = gregorian.date(from: components)!
        let data = makeData(used: 0, limit: 100, resetDate: date)
        XCTAssertEqual(data.resetAbsoluteText, "7/10 07:24")
    }

    func testResetAbsoluteTextNilWhenNoResetDate() {
        let data = makeData(used: 0, limit: 100)
        XCTAssertNil(data.resetAbsoluteText)
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
        XCTAssertNil(data.resetText)
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
        XCTAssertNotNil(data.resetText)

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
        XCTAssertNil(data.resetText)
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
        XCTAssertNil(data.resetText)
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
        resetDate: Date? = nil
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
            onDemandEnabled: nil,
            isOnDemandActive: false,
            cycleStartDate: nil,
            resetDate: resetDate
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
            onDemandEnabled: nil,
            isOnDemandActive: false,
            cycleStartDate: nil, resetDate: nil
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
        XCTAssertEqual(data.percentText, "6%")
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

        XCTAssertEqual(data.usageText, "6%", "Free plan should show percent instead of 0 / 0")
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

        XCTAssertEqual(data.menuBarUsedText, "6%")
        XCTAssertEqual(data.menuBarLimitText, "")
    }

    // MARK: - Token-based enterprise (issue #71)

    /// Primary path: with the hard-limit endpoint's `perUserMonthlyLimitDollars`
    /// available, the token plan renders as credit-based `$used / $limit`,
    /// mirroring Cursor's own dashboard ("$0.17 / $100").
    func test_tokenEnterprise_withHardLimit_showsDollars() {
        let summary = makeSummaryResponse(
            billingCycleEnd: "2099-07-09T00:00:00.000Z",
            membershipType: "enterprise",
            autoMessage: "You've used 0% of your included total usage",
            overallUsed: 17 // cents → $0.17
        )
        let usage = makeUsageResponse(numRequests: 0, maxRequestUsage: nil)
        let userInfo = UserInfoResponse(email: "ent@11st.com", name: "Woojin")

        let data = UsageDisplayData.from(
            summary: summary, usage: usage, userInfo: userInfo,
            perUserMonthlyLimitDollars: 100) // dollars → $100

        XCTAssertTrue(data.isCreditBased)
        XCTAssertFalse(data.isPercentOnly)
        XCTAssertEqual(data.usageText, "$0.17 / $100.00")
        XCTAssertEqual(data.usageLabel, "Plan Usage")
        XCTAssertEqual(data.percentUsed, 0.17, accuracy: 0.001)
    }

    /// Fallback path: no hard limit yet (first refresh, or non-usage-based) →
    /// percent-only from the display message instead of the old `0 / 0`.
    func test_tokenEnterprise_withoutHardLimit_fallsBackToPercent() {
        let summary = makeSummaryResponse(
            billingCycleEnd: "2099-07-09T00:00:00.000Z",
            membershipType: "enterprise",
            autoMessage: "You've used 0% of your included total usage",
            overallUsed: 17
        )
        // maxRequestUsage nil → not request-based; no hard limit passed
        let usage = makeUsageResponse(numRequests: 0, maxRequestUsage: nil)
        let userInfo = UserInfoResponse(email: "ent@11st.com", name: "Woojin")

        let data = UsageDisplayData.from(summary: summary, usage: usage, userInfo: userInfo)

        XCTAssertTrue(data.isPercentOnly)
        XCTAssertEqual(data.usageText, "0%", "Must not render 0 / 0")
        XCTAssertEqual(data.usageLabel, "Plan Usage")
        XCTAssertEqual(data.menuBarUsedText, "0%")
        XCTAssertEqual(data.menuBarLimitText, "")
    }

    func test_tokenEnterprise_nonZeroPercentFallback() {
        let summary = makeSummaryResponse(
            billingCycleEnd: "2099-07-09T00:00:00.000Z",
            membershipType: "enterprise",
            autoMessage: "You've used 37% of your included total usage"
        )
        let usage = makeUsageResponse(numRequests: 0, maxRequestUsage: nil)
        let userInfo = UserInfoResponse(email: "ent@11st.com", name: "Woojin")

        let data = UsageDisplayData.from(summary: summary, usage: usage, userInfo: userInfo)

        XCTAssertEqual(data.percentUsed, 37.0, accuracy: 0.01)
        XCTAssertEqual(data.usageText, "37%")
    }

    /// Accepted residual: no hard limit AND no parseable percent → `0 / 0`
    /// rather than inventing a number (documented in issue #71).
    func test_tokenEnterprise_noMessageNoLimit_fallsBackToRequests() {
        let summary = makeSummaryResponse(
            billingCycleEnd: "2099-07-09T00:00:00.000Z",
            membershipType: "enterprise",
            autoMessage: nil
        )
        let usage = makeUsageResponse(numRequests: 0, maxRequestUsage: nil)
        let userInfo = UserInfoResponse(email: "ent@11st.com", name: "Woojin")

        let data = UsageDisplayData.from(summary: summary, usage: usage, userInfo: userInfo)

        XCTAssertFalse(data.isPercentOnly)
        XCTAssertEqual(data.usageText, "0 / 0")
    }

    /// Regression guard for the `??` chain: a real `plan` object must win over
    /// the token-based overall/hard-limit fallback.
    func test_realPlan_winsOverOverallAndHardLimit() {
        let summary = makeSummaryResponse(
            billingCycleEnd: "2099-07-09T00:00:00.000Z",
            membershipType: "pro",
            planUsed: 800,
            planLimit: 2000,
            overallUsed: 999
        )
        let usage = makeUsageResponse(numRequests: 0, maxRequestUsage: nil)
        let userInfo = UserInfoResponse(email: "pro@test.com", name: "Pro")

        let data = UsageDisplayData.from(
            summary: summary, usage: usage, userInfo: userInfo,
            perUserMonthlyLimitDollars: 50)

        XCTAssertEqual(data.usageText, "$8.00 / $20.00", "Real plan must win over overall/hard-limit")
    }

    func test_hardLimitResponse_decodesNoUsageBasedAllowed() throws {
        let json = Data(#"{"noUsageBasedAllowed":true}"#.utf8)
        let decoded = try JSONDecoder().decode(HardLimitResponse.self, from: json)
        XCTAssertNil(decoded.perUserMonthlyLimitDollars)
        XCTAssertNil(decoded.hardLimit)
    }

    func test_hardLimitResponse_decodesLimits() throws {
        let json = Data(#"{"hardLimit":3000,"hardLimitPerUser":200,"perUserMonthlyLimitDollars":100}"#.utf8)
        let decoded = try JSONDecoder().decode(HardLimitResponse.self, from: json)
        XCTAssertEqual(decoded.perUserMonthlyLimitDollars, 100)
        XCTAssertEqual(decoded.hardLimit, 3000)
    }

    // MARK: - Token-based enterprise: personal on-demand (#71)

    /// Personal on-demand = spend beyond the included limit, against the member's
    /// per-seat cap. $0 until included is exhausted → "$0.00 / $40.00".
    func test_tokenEnterprise_personalOnDemand_zeroUntilIncludedExhausted() {
        let summary = makeSummaryResponse(
            billingCycleEnd: "2099-07-09T00:00:00.000Z",
            membershipType: "enterprise",
            overallUsed: 223 // $2.23 of $100 included
        )
        let usage = makeUsageResponse(numRequests: 0, maxRequestUsage: nil)
        let data = UsageDisplayData.from(
            summary: summary, usage: usage,
            userInfo: UserInfoResponse(email: "ent@11st.com", name: "Woojin"),
            perUserMonthlyLimitDollars: 100,
            perUserOnDemandLimitDollars: 40)

        XCTAssertEqual(data.onDemandUsedCents, 0)
        XCTAssertEqual(data.onDemandLimitCents, 4000)
        XCTAssertTrue(data.hasOnDemand)
        XCTAssertEqual(data.onDemandText, "$0.00 / $40.00")
    }

    /// Once included ($100) is exceeded, the overflow shows as on-demand spend.
    func test_tokenEnterprise_personalOnDemand_overflowAboveIncluded() {
        let summary = makeSummaryResponse(
            billingCycleEnd: "2099-07-09T00:00:00.000Z",
            membershipType: "enterprise",
            overallUsed: 12000 // $120 — $20 past the $100 included
        )
        let usage = makeUsageResponse(numRequests: 0, maxRequestUsage: nil)
        let data = UsageDisplayData.from(
            summary: summary, usage: usage,
            userInfo: UserInfoResponse(email: "ent@11st.com", name: "Woojin"),
            perUserMonthlyLimitDollars: 100,
            perUserOnDemandLimitDollars: 40)

        XCTAssertEqual(data.onDemandUsedCents, 2000) // $20.00 overflow
        XCTAssertEqual(data.onDemandText, "$20.00 / $40.00")
    }

    /// No per-seat cap resolved → hide the on-demand row rather than fall back to
    /// the misleading team-wide figure.
    func test_tokenEnterprise_noOnDemandCap_hidesRow() {
        let summary = makeSummaryResponse(
            billingCycleEnd: "2099-07-09T00:00:00.000Z",
            membershipType: "enterprise",
            overallUsed: 223
        )
        let usage = makeUsageResponse(numRequests: 0, maxRequestUsage: nil)
        let data = UsageDisplayData.from(
            summary: summary, usage: usage,
            userInfo: UserInfoResponse(email: "ent@11st.com", name: "Woojin"),
            perUserMonthlyLimitDollars: 100,
            perUserOnDemandLimitDollars: nil)

        XCTAssertNil(data.onDemandLimitCents)
        XCTAssertFalse(data.hasOnDemand)
    }

    /// Token-based members must NOT show the team-wide `teamUsage.onDemand`.
    func test_tokenEnterprise_ignoresTeamOnDemand() {
        let summary = UsageSummaryResponse(
            billingCycleStart: "2026-06-09T00:00:00.000Z",
            billingCycleEnd: "2099-07-09T00:00:00.000Z",
            membershipType: "enterprise",
            limitType: "team",
            isUnlimited: false,
            autoModelSelectedDisplayMessage: "You've used 0% of your included total usage",
            individualUsage: IndividualUsage(
                plan: nil, onDemand: nil,
                overall: OverallUsage(enabled: true, used: 223, limit: 10000, remaining: 9777)),
            teamUsage: TeamUsage(onDemand: OnDemandUsage(
                enabled: true, used: 26192, limit: 300000, remaining: 273808))
        )
        let usage = makeUsageResponse(numRequests: 0, maxRequestUsage: nil)
        let data = UsageDisplayData.from(
            summary: summary, usage: usage,
            userInfo: UserInfoResponse(email: "ent@11st.com", name: "Woojin"),
            perUserMonthlyLimitDollars: 100,
            perUserOnDemandLimitDollars: 40)

        XCTAssertEqual(data.onDemandLimitCents, 4000, "Must be personal $40, not team $3000")
        XCTAssertNotEqual(data.onDemandLimitCents, 300000)
        XCTAssertEqual(data.onDemandUsedCents, 0, "Must be personal $0, not team $261.92")
    }

    /// `overall.limit`, when populated, sources the included limit without the
    /// hard-limit endpoint.
    func test_tokenEnterprise_usesOverallLimitWhenPresent() {
        let summary = UsageSummaryResponse(
            billingCycleStart: nil,
            billingCycleEnd: "2099-07-09T00:00:00.000Z",
            membershipType: "enterprise",
            limitType: "team",
            isUnlimited: false,
            autoModelSelectedDisplayMessage: nil,
            individualUsage: IndividualUsage(
                plan: nil, onDemand: nil,
                overall: OverallUsage(enabled: true, used: 223, limit: 10000, remaining: 9777)),
            teamUsage: nil
        )
        let usage = makeUsageResponse(numRequests: 0, maxRequestUsage: nil)
        // No perUserMonthlyLimitDollars passed — limit must come from overall.limit
        let data = UsageDisplayData.from(
            summary: summary, usage: usage,
            userInfo: UserInfoResponse(email: "ent@11st.com", name: "Woojin"))

        XCTAssertTrue(data.isCreditBased)
        XCTAssertEqual(data.usageText, "$2.23 / $100.00")
    }

    func test_fromSummary_creditBased_ignoresDisplayMessage() {
        let summary = makeSummaryResponse(
            billingCycleEnd: "2099-07-09T00:00:00.000Z",
            membershipType: "pro",
            planUsed: 800,
            planLimit: 2000,
            autoMessage: "You've used 50% of your included total usage"
        )
        let usage = makeUsageResponse(numRequests: 0, maxRequestUsage: nil)
        let userInfo = UserInfoResponse(email: "pro@test.com", name: "Pro")

        let data = UsageDisplayData.from(summary: summary, usage: usage, userInfo: userInfo)

        XCTAssertTrue(data.isCreditBased)
        XCTAssertFalse(data.isPercentOnly)
        XCTAssertEqual(data.usageText, "$8.00 / $20.00", "Credit calc must win over message")
        XCTAssertEqual(data.percentUsed, 40.0, accuracy: 0.01)
    }

    func test_fromSummary_requestBased_ignoresDisplayMessage() {
        let summary = makeSummaryResponse(
            billingCycleEnd: "2099-07-09T00:00:00.000Z",
            membershipType: "enterprise",
            autoMessage: "You've used 99% of your included total usage"
        )
        let usage = makeUsageResponse(numRequests: 42, maxRequestUsage: 500)
        let userInfo = UserInfoResponse(email: "ent@test.com", name: "Ent")

        let data = UsageDisplayData.from(summary: summary, usage: usage, userInfo: userInfo)

        XCTAssertFalse(data.isPercentOnly)
        XCTAssertEqual(data.usageText, "42 / 500")
    }

    // MARK: - hasOnDemand (OnDemandUsage.enabled plumbing)

    func test_hasOnDemand_falseWhenEnabledFalse() {
        let data = UsageDisplayData(
            email: "test@test.com",
            name: "Test",
            membershipType: "pro",
            planUsedCents: 5000,
            planLimitCents: 5000,
            serverPercentUsed: nil,
            requestsUsed: 0,
            requestsLimit: 0,
            onDemandUsedCents: 0,
            onDemandLimitCents: 4000,
            onDemandEnabled: false,
            isOnDemandActive: false,
            cycleStartDate: nil,
            resetDate: nil
        )
        XCTAssertFalse(data.hasOnDemand)
    }

    func test_hasOnDemand_trueWhenEnabledNil() {
        let data = UsageDisplayData(
            email: "test@test.com",
            name: "Test",
            membershipType: "pro",
            planUsedCents: 5000,
            planLimitCents: 5000,
            serverPercentUsed: nil,
            requestsUsed: 0,
            requestsLimit: 0,
            onDemandUsedCents: 0,
            onDemandLimitCents: 4000,
            onDemandEnabled: nil,
            isOnDemandActive: false,
            cycleStartDate: nil,
            resetDate: nil
        )
        XCTAssertTrue(data.hasOnDemand)
    }

    // MARK: - wouldActivateOnDemand (derived trigger flag)

    func test_wouldActivate_requestQuotaExceeded() {
        let data = makeOnDemandData(
            requestsUsed: 757,
            requestsLimit: 500,
            onDemandLimitCents: 4000,
            onDemandEnabled: true
        )
        XCTAssertTrue(data.wouldActivateOnDemand)
    }

    func test_wouldActivate_requestBoundaryEqual() {
        let data = makeOnDemandData(
            requestsUsed: 500,
            requestsLimit: 500,
            onDemandLimitCents: 4000,
            onDemandEnabled: true
        )
        XCTAssertTrue(data.wouldActivateOnDemand)
    }

    func test_wouldActivate_underQuota() {
        let data = makeOnDemandData(
            requestsUsed: 400,
            requestsLimit: 500,
            onDemandLimitCents: 4000,
            onDemandEnabled: true
        )
        XCTAssertFalse(data.wouldActivateOnDemand)
    }

    func test_wouldActivate_noOnDemand() {
        let data = makeOnDemandData(
            requestsUsed: 757,
            requestsLimit: 500,
            onDemandLimitCents: 0,
            onDemandEnabled: nil
        )
        XCTAssertFalse(data.wouldActivateOnDemand)
    }

    func test_wouldActivate_creditBasedExhausted() {
        let data = makeOnDemandData(
            planUsedCents: 2000,
            planLimitCents: 2000,
            requestsUsed: 0,
            requestsLimit: 0,
            onDemandLimitCents: 4000,
            onDemandEnabled: true
        )
        XCTAssertTrue(data.wouldActivateOnDemand)
    }

    func test_wouldActivate_creditBasedZeroLimitNoActivation() {
        let data = makeOnDemandData(
            planUsedCents: 0,
            planLimitCents: 0,
            requestsUsed: 0,
            requestsLimit: 0,
            onDemandLimitCents: 4000,
            onDemandEnabled: true
        )
        XCTAssertFalse(data.wouldActivateOnDemand)
    }

    // MARK: - isOnDemandActive branched presentation

    func test_percentUsed_onDemandMode_usesOnDemandRatio() {
        // 584 / 4000 = 14.6%
        let data = makeOnDemandData(
            requestsUsed: 757, requestsLimit: 500,
            onDemandUsedCents: 584, onDemandLimitCents: 4000,
            onDemandEnabled: true, isOnDemandActive: true)
        XCTAssertEqual(data.percentUsed, 14.6, accuracy: 0.05)
    }

    func test_usageLabel_onDemandMode_isOnDemand() {
        let data = makeOnDemandData(
            onDemandUsedCents: 584, onDemandLimitCents: 4000,
            onDemandEnabled: true, isOnDemandActive: true)
        XCTAssertEqual(data.usageLabel, "On-demand")
    }

    func test_usageText_onDemandMode_isUSD() {
        let data = makeOnDemandData(
            onDemandUsedCents: 584, onDemandLimitCents: 4000,
            onDemandEnabled: true, isOnDemandActive: true)
        XCTAssertEqual(data.usageText, "$5.84 / $40.00")
    }

    func test_menuBarText_onDemandMode_compactUSD() {
        let data = makeOnDemandData(
            onDemandUsedCents: 584, onDemandLimitCents: 4000,
            onDemandEnabled: true, isOnDemandActive: true)
        XCTAssertEqual(data.menuBarUsedText, "5.8")
        XCTAssertEqual(data.menuBarLimitText, "40.0")
    }

    func test_presentationUnchanged_whenLatchInactive() {
        // Same data with isOnDemandActive=false should preserve legacy behavior.
        let data = makeOnDemandData(
            requestsUsed: 757, requestsLimit: 500,
            onDemandUsedCents: 584, onDemandLimitCents: 4000,
            onDemandEnabled: true, isOnDemandActive: false)
        XCTAssertEqual(data.usageLabel, "Requests")
        XCTAssertEqual(data.usageText, "757 / 500")
        XCTAssertEqual(data.percentUsed, 151.4, accuracy: 0.5)
    }

    func test_withOnDemandActive_returnsCopyWithFlagSet() {
        let base = makeOnDemandData(
            onDemandUsedCents: 100, onDemandLimitCents: 4000,
            onDemandEnabled: true, isOnDemandActive: false)
        let active = base.withOnDemandActive(true)
        XCTAssertFalse(base.isOnDemandActive)
        XCTAssertTrue(active.isOnDemandActive)
        // Other fields preserved
        XCTAssertEqual(active.onDemandUsedCents, base.onDemandUsedCents)
    }

    // MARK: - Secondary row computeds (inverted display in on-demand mode)

    func test_secondaryRow_onDemandMode_showsRequests() {
        let data = makeOnDemandData(
            requestsUsed: 757, requestsLimit: 500,
            onDemandUsedCents: 584, onDemandLimitCents: 4000,
            onDemandEnabled: true, isOnDemandActive: true)
        XCTAssertEqual(data.secondaryUsageLabel, "Requests")
        XCTAssertEqual(data.secondaryUsageValue, "757 / 500")
        XCTAssertTrue(data.secondaryUsageIsOverLimit)
    }

    func test_secondaryRow_onDemandMode_showsPlan_whenCreditBased() {
        let data = makeOnDemandData(
            planUsedCents: 2000, planLimitCents: 2000,
            requestsUsed: 0, requestsLimit: 0,
            onDemandUsedCents: 0, onDemandLimitCents: 4000,
            onDemandEnabled: true, isOnDemandActive: true)
        XCTAssertEqual(data.secondaryUsageLabel, "Plan")
        XCTAssertEqual(data.secondaryUsageValue, "$20.00 / $20.00")
        XCTAssertTrue(data.secondaryUsageIsOverLimit)
    }

    func test_secondaryRow_requestMode_showsOnDemand() {
        let data = makeOnDemandData(
            requestsUsed: 200, requestsLimit: 500,
            onDemandUsedCents: 0, onDemandLimitCents: 4000,
            onDemandEnabled: true, isOnDemandActive: false)
        XCTAssertEqual(data.secondaryUsageLabel, "On-demand")
        XCTAssertEqual(data.secondaryUsageValue, "$0.00 / $40.00")
        XCTAssertFalse(data.secondaryUsageIsOverLimit)
    }

    func test_secondaryRow_requestMode_nil_whenNoOnDemand() {
        let data = makeOnDemandData(
            requestsUsed: 200, requestsLimit: 500,
            onDemandUsedCents: nil, onDemandLimitCents: nil,
            onDemandEnabled: nil, isOnDemandActive: false)
        XCTAssertNil(data.secondaryUsageLabel)
        XCTAssertNil(data.secondaryUsageValue)
    }

    // MARK: - teamUsage.onDemand fallback (Enterprise team members)

    func test_teamUsage_onDemand_populatesDisplayData() {
        let summary = UsageSummaryResponse(
            billingCycleStart: "2026-05-01T00:00:00.000Z",
            billingCycleEnd: "2026-06-01T00:00:00.000Z",
            membershipType: "enterprise",
            limitType: nil,
            isUnlimited: false,
            autoModelSelectedDisplayMessage: nil,
            individualUsage: IndividualUsage(plan: nil, onDemand: nil, overall: nil),
            teamUsage: TeamUsage(onDemand: OnDemandUsage(
                enabled: true, used: 584, limit: 4000, remaining: 3416))
        )
        let usage = UsageResponse(
            models: ["gpt-4": ModelUsage(
                numRequests: 757,
                numRequestsTotal: 757,
                numTokens: nil,
                maxRequestUsage: 500,
                maxTokenUsage: nil
            )],
            startOfMonth: "2026-05-01T00:00:00.000Z"
        )
        let userInfo = UserInfoResponse(email: "test@example.com", name: "Test")

        let data = UsageDisplayData.from(summary: summary, usage: usage, userInfo: userInfo)

        XCTAssertEqual(data.onDemandUsedCents, 584)
        XCTAssertEqual(data.onDemandLimitCents, 4000)
        XCTAssertEqual(data.onDemandEnabled, true)
        XCTAssertTrue(data.hasOnDemand)
    }

    // MARK: - Helpers

    /// Helper for wouldActivateOnDemand / isOnDemandActive tests —
    /// exposes all quota + on-demand fields.
    private func makeOnDemandData(
        planUsedCents: Int? = nil,
        planLimitCents: Int? = nil,
        requestsUsed: Int = 0,
        requestsLimit: Int = 0,
        onDemandUsedCents: Int? = 0,
        onDemandLimitCents: Int?,
        onDemandEnabled: Bool?,
        isOnDemandActive: Bool = false
    ) -> UsageDisplayData {
        UsageDisplayData(
            email: "test@test.com",
            name: "Test",
            membershipType: nil,
            planUsedCents: planUsedCents,
            planLimitCents: planLimitCents,
            serverPercentUsed: nil,
            requestsUsed: requestsUsed,
            requestsLimit: requestsLimit,
            onDemandUsedCents: onDemandUsedCents,
            onDemandLimitCents: onDemandLimitCents,
            onDemandEnabled: onDemandEnabled,
            isOnDemandActive: isOnDemandActive,
            cycleStartDate: nil,
            resetDate: nil
        )
    }

    private func makeCreditData(
        usedCents: Int,
        limitCents: Int,
        serverPercent: Double? = nil
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
            onDemandEnabled: nil,
            isOnDemandActive: false,
            cycleStartDate: nil,
            resetDate: nil
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
        totalPercentUsed: Double? = nil,
        autoMessage: String? = nil,
        overallUsed: Int? = nil
    ) -> UsageSummaryResponse {
        let plan: PlanUsage? = (planUsed != nil || planLimit != nil || totalPercentUsed != nil)
            ? PlanUsage(enabled: true, used: planUsed, limit: planLimit, remaining: nil, totalPercentUsed: totalPercentUsed)
            : nil
        let overall: OverallUsage? = overallUsed.map {
            OverallUsage(enabled: false, used: $0, limit: nil, remaining: nil)
        }
        let individual: IndividualUsage? = (plan != nil || overall != nil)
            ? IndividualUsage(plan: plan, onDemand: nil, overall: overall)
            : nil
        return UsageSummaryResponse(
            billingCycleStart: nil,
            billingCycleEnd: billingCycleEnd,
            membershipType: membershipType,
            limitType: nil,
            isUnlimited: nil,
            autoModelSelectedDisplayMessage: autoMessage,
            individualUsage: individual,
            teamUsage: nil
        )
    }
}
