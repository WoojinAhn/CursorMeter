import XCTest
@testable import CursorMeter

final class NotificationManagerTests: XCTestCase {

    // MARK: - Threshold Evaluation (Pure Logic)

    func testBelowWarningReturnsNone() {
        let result = NotificationManager.evaluateThreshold(
            percentUsed: 50,
            warningThreshold: 80,
            criticalThreshold: 90,
            notifiedThresholds: []
        )
        XCTAssertEqual(result, .none)
    }

    func testAtWarningReturnsWarning() {
        let result = NotificationManager.evaluateThreshold(
            percentUsed: 80,
            warningThreshold: 80,
            criticalThreshold: 90,
            notifiedThresholds: []
        )
        XCTAssertEqual(result, .warning)
    }

    func testAboveWarningBelowCriticalReturnsWarning() {
        let result = NotificationManager.evaluateThreshold(
            percentUsed: 85,
            warningThreshold: 80,
            criticalThreshold: 90,
            notifiedThresholds: []
        )
        XCTAssertEqual(result, .warning)
    }

    func testAtCriticalReturnsCritical() {
        let result = NotificationManager.evaluateThreshold(
            percentUsed: 90,
            warningThreshold: 80,
            criticalThreshold: 90,
            notifiedThresholds: []
        )
        XCTAssertEqual(result, .critical)
    }

    func testAboveCriticalReturnsCritical() {
        let result = NotificationManager.evaluateThreshold(
            percentUsed: 95,
            warningThreshold: 80,
            criticalThreshold: 90,
            notifiedThresholds: []
        )
        XCTAssertEqual(result, .critical)
    }

    func testWarningAlreadyNotifiedReturnsNone() {
        let result = NotificationManager.evaluateThreshold(
            percentUsed: 85,
            warningThreshold: 80,
            criticalThreshold: 90,
            notifiedThresholds: [80]
        )
        XCTAssertEqual(result, .none)
    }

    func testCriticalAlreadyNotifiedReturnsNone() {
        let result = NotificationManager.evaluateThreshold(
            percentUsed: 95,
            warningThreshold: 80,
            criticalThreshold: 90,
            notifiedThresholds: [80, 90]
        )
        XCTAssertEqual(result, .none)
    }

    func testCriticalNotNotifiedButWarningWasReturnsCritical() {
        let result = NotificationManager.evaluateThreshold(
            percentUsed: 92,
            warningThreshold: 80,
            criticalThreshold: 90,
            notifiedThresholds: [80]
        )
        XCTAssertEqual(result, .critical)
    }

    func testCustomThresholds() {
        let result = NotificationManager.evaluateThreshold(
            percentUsed: 65,
            warningThreshold: 60,
            criticalThreshold: 75,
            notifiedThresholds: []
        )
        XCTAssertEqual(result, .warning)
    }

    func testZeroPercentReturnsNone() {
        let result = NotificationManager.evaluateThreshold(
            percentUsed: 0,
            warningThreshold: 80,
            criticalThreshold: 90,
            notifiedThresholds: []
        )
        XCTAssertEqual(result, .none)
    }

    // MARK: - Usage Jump Notification

    func testUsageJumpRetainsCapturedDollarFraction() {
        let jump = LegacyUsageJumpSnapshot(mode: .credit, reference: 180, current: 210, limit: 2000)
        let content = NotificationManager.legacyUsageContent(percentUsed: 10.5, level: .none,
            threshold: 80, mode: .creditPlan(usedCents: 210, limitCents: 2000), jump: jump)
        XCTAssertEqual(content?.title, "Included usage increased")
        XCTAssertEqual(content?.body, "+$0.30 since last refresh\n$2.10 of $20.00 used")
    }

    func testUsageJumpRequestCopyUsesRequests() {
        let jump = LegacyUsageJumpSnapshot(mode: .request, reference: 15, current: 45, limit: 50)
        XCTAssertEqual(jump.changeBody, "30 more requests since last refresh")
        XCTAssertEqual(jump.currentBody, "45 of 50 requests used")
    }

    func testUsageJumpPercentUsesCapturedReadings() {
        let jump = LegacyUsageJumpSnapshot(mode: .percent, reference: 63, current: 78, limit: 100)
        XCTAssertEqual(jump.changeBody, "Last refresh 63.0% → now 78.0%")
        XCTAssertNil(jump.currentBody)
    }

    // MARK: - NotificationMode fraction / scope

    func test_body_requestQuota_includesRequestFraction() {
        let s = NotificationMode.requestQuota(used: 757, limit: 500).thresholdBody(level: .warning, at: 80)
        XCTAssertEqual(s, "757 of 500 requests · alert at 80%")
    }

    func test_body_creditPlan_includesUSD() {
        let s = NotificationMode.creditPlan(usedCents: 1600, limitCents: 2000).thresholdBody(level: .warning, at: 80)
        XCTAssertEqual(s, "$16.00 of $20.00 · alert at 80%")
    }

    func test_body_onDemand_includesUSD() {
        let s = NotificationMode.onDemand(usedCents: 3200, limitCents: 4000).thresholdBody(level: .warning, at: 80)
        XCTAssertEqual(s, "$32.00 of $40.00 · alert at 80%")
    }

    func test_scopeLabel_eachMode() {
        XCTAssertEqual(NotificationMode.requestQuota(used: 0, limit: 0).scopeLabel, "Request quota")
        XCTAssertEqual(NotificationMode.creditPlan(usedCents: 0, limitCents: 0).scopeLabel, "Included usage")
        XCTAssertEqual(NotificationMode.onDemand(usedCents: 0, limitCents: 0).scopeLabel, "Paid budget")
        XCTAssertEqual(NotificationMode.percentOnly.scopeLabel, "Included usage")
    }

    // MARK: - #104 percent-only plans (free): no meaningless "0 / 0" fraction

    func test_body_percentOnly_hasNoFraction() {
        let s = NotificationMode.percentOnly.thresholdBody(level: .warning, at: 80)
        XCTAssertEqual(s, "Your warning level is 80%.")
        XCTAssertFalse(s.contains("(0 / 0)"))
    }

    func test_modeSelection_percentOnlyPlanPicksPercentMode() {
        // Free plan shape: no usable used/limit, server percent only.
        let data = UsageDisplayData(
            email: "x", name: "x", membershipType: "free",
            planUsedCents: 0, planLimitCents: 0,
            serverPercentUsed: 82.0,
            requestsUsed: 0, requestsLimit: 0,
            onDemandUsedCents: nil, onDemandLimitCents: nil,
            onDemandEnabled: nil, isOnDemandActive: false,
            cycleStartDate: nil, resetDate: nil
        )
        XCTAssertTrue(data.isPercentOnly)
        XCTAssertEqual(UsageViewModel.notificationMode(for: data), .percentOnly)
    }

    func test_modeSelection_existingModesUnchanged() {
        let credit = UsageDisplayData(
            email: "x", name: "x", membershipType: "pro",
            planUsedCents: 1600, planLimitCents: 2000,
            serverPercentUsed: nil,
            requestsUsed: 0, requestsLimit: 0,
            onDemandUsedCents: nil, onDemandLimitCents: nil,
            onDemandEnabled: nil, isOnDemandActive: false,
            cycleStartDate: nil, resetDate: nil
        )
        XCTAssertEqual(
            UsageViewModel.notificationMode(for: credit),
            .creditPlan(usedCents: 1600, limitCents: 2000)
        )

        let requests = UsageDisplayData(
            email: "x", name: "x", membershipType: "pro",
            planUsedCents: nil, planLimitCents: nil,
            serverPercentUsed: nil,
            requestsUsed: 757, requestsLimit: 500,
            onDemandUsedCents: nil, onDemandLimitCents: nil,
            onDemandEnabled: nil, isOnDemandActive: false,
            cycleStartDate: nil, resetDate: nil
        )
        XCTAssertEqual(
            UsageViewModel.notificationMode(for: requests),
            .requestQuota(used: 757, limit: 500)
        )

        let onDemand = UsageDisplayData(
            email: "x", name: "x", membershipType: "pro",
            planUsedCents: 2000, planLimitCents: 2000,
            serverPercentUsed: nil,
            requestsUsed: 0, requestsLimit: 0,
            onDemandUsedCents: 3200, onDemandLimitCents: 4000,
            onDemandEnabled: true, isOnDemandActive: true,
            cycleStartDate: nil, resetDate: nil
        )
        XCTAssertEqual(
            UsageViewModel.notificationMode(for: onDemand),
            .onDemand(usedCents: 3200, limitCents: 4000)
        )
    }

    func testUsageJumpIdentifierPrefixIsDistinct() {
        // Sanity check: the prefix used for jump notifications must not collide
        // with any of the integer threshold values used by checkAndNotify.
        XCTAssertEqual(NotificationManager.usageJumpIdentifierPrefix, "usage-jump")
    }

    // Injected authorization and submission are exercised by NotificationSessionTests.

    // MARK: - Notification Click Routing (#79, #83)

    func testClickActionSessionExpiredOpensLoginWindow() {
        XCTAssertEqual(
            NotificationManager.clickAction(
                forNotificationIdentifier: NotificationManager.sessionExpiredIdentifier,
                userInfo: [:]
            ),
            .openLoginWindow
        )
    }

    func testUsageIdentifiersOpenCurrentPopover() {
        for id in ["usage-jump-ABC", "usage-threshold-ABC", "usage-split-ABC"] {
            XCTAssertEqual(NotificationManager.clickAction(forNotificationIdentifier: id, userInfo: [:]), .openPopover)
        }
    }

    func testClickActionLegacyIdentifiersAreNoOps() {
        for id in [UUID().uuidString, ""] {
            XCTAssertEqual(
                NotificationManager.clickAction(forNotificationIdentifier: id, userInfo: [:]),
                .none
            )
        }
    }

    func testClickActionUpdateAvailableParsesReleaseURL() {
        let action = NotificationManager.clickAction(
            forNotificationIdentifier: NotificationManager.updateAvailableIdentifier,
            userInfo: [NotificationManager.releaseURLUserInfoKey: "https://github.com/WoojinAhn/CursorMeter/releases/tag/v0.8.0"]
        )
        XCTAssertEqual(
            action,
            .openReleaseURL(URL(string: "https://github.com/WoojinAhn/CursorMeter/releases/tag/v0.8.0")!)
        )
    }

    func testClickActionUpdateAvailableMissingOrMalformedURLIsNoOp() {
        XCTAssertEqual(
            NotificationManager.clickAction(
                forNotificationIdentifier: NotificationManager.updateAvailableIdentifier,
                userInfo: [:]
            ),
            .none
        )
        XCTAssertEqual(
            NotificationManager.clickAction(
                forNotificationIdentifier: NotificationManager.updateAvailableIdentifier,
                userInfo: [NotificationManager.releaseURLUserInfoKey: ""]
            ),
            .none
        )
        XCTAssertEqual(
            NotificationManager.clickAction(
                forNotificationIdentifier: NotificationManager.updateAvailableIdentifier,
                userInfo: [NotificationManager.releaseURLUserInfoKey: 42]
            ),
            .none
        )
    }

    func testClickActionRefreshFailingOpensPopover() {
        XCTAssertEqual(
            NotificationManager.clickAction(
                forNotificationIdentifier: NotificationManager.refreshFailingIdentifier,
                userInfo: [:]
            ),
            .openPopover
        )
    }

    // MARK: - Update-available body (#83)

    func testUpdateAvailableBody() {
        XCTAssertEqual(
            NotificationManager.updateAvailableBody,
            "See what’s new on GitHub."
        )
    }
}
