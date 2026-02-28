import XCTest
@testable import CursorBar

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

    func testJumpPastBothReturnsCritical() {
        // When usage jumps from below warning to above critical,
        // critical takes priority
        let result = NotificationManager.evaluateThreshold(
            percentUsed: 95,
            warningThreshold: 80,
            criticalThreshold: 90,
            notifiedThresholds: []
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

    // MARK: - NotificationManager State

    @MainActor
    func testResetClearsNotifiedThresholds() {
        let manager = NotificationManager()
        // Simulate having notified
        Task {
            await manager.checkAndNotify(
                percentUsed: 85,
                warningThreshold: 80,
                criticalThreshold: 90,
                enabled: false // disabled to avoid actual notification
            )
        }
        manager.resetNotifications()
        XCTAssertTrue(manager.notifiedThresholds.isEmpty)
    }
}
