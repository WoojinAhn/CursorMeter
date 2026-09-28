import XCTest
@testable import CursorMeter

@MainActor
final class NotificationSessionTests: XCTestCase {
    @MainActor private final class Gate {
        private var waiting: CheckedContinuation<Void, Never>?
        private var arrival: CheckedContinuation<Void, Never>?

        func pause() async {
            await withCheckedContinuation {
                waiting = $0
                arrival?.resume()
                arrival = nil
            }
        }

        func waitForPause() async {
            if waiting == nil { await withCheckedContinuation { arrival = $0 } }
        }

        func release() { waiting?.resume(); waiting = nil }
    }

    private func check(_ manager: NotificationManager, percent: Double = 85) async {
        await manager.checkAndNotify(
            percentUsed: percent, warningThreshold: 80, criticalThreshold: 90,
            enabled: true, mode: .percentOnly
        )
    }

    func testLegacyJumpUsesInjectedBoundaries() async {
        var deliveries = 0
        let manager = NotificationManager(requestAuthorization: { true }, deliver: { request in
            deliveries += 1
            XCTAssertTrue(request.identifier.hasPrefix("usage-jump-"))
        })
        await manager.notifyUsageJump(displayDelta: "+$0.30", currentUsage: "$1.00")
        XCTAssertEqual(deliveries, 1)
    }

    func testResetWhileAuthorizationPendingPreventsOldDeliveryAndDedup() async {
        let gate = Gate()
        var deliveries = 0
        let manager = NotificationManager(
            requestAuthorization: { await gate.pause(); return true },
            deliver: { _ in deliveries += 1 }
        )
        let old = Task { await check(manager) }
        await gate.waitForPause()
        manager.resetNotifications()
        gate.release()
        await old.value

        XCTAssertEqual(deliveries, 0)
        XCTAssertTrue(manager.notifiedThresholds.isEmpty)
    }

    func testOldSendCompletionCannotPoisonNewThresholdDedup() async {
        let gate = Gate()
        var deliveries = 0
        let manager = NotificationManager(
            requestAuthorization: { true },
            deliver: { _ in
                deliveries += 1
                if deliveries == 1 { await gate.pause() }
            }
        )
        let old = Task { await check(manager, percent: 95) }
        await gate.waitForPause()
        manager.resetNotifications()
        await check(manager)
        gate.release()
        await old.value

        XCTAssertEqual(deliveries, 2)
        XCTAssertEqual(manager.notifiedThresholds, [80])
    }

    func testCancellationWhileAuthorizationPendingSkipsDelivery() async {
        let gate = Gate()
        var deliveries = 0
        let manager = NotificationManager(
            requestAuthorization: { await gate.pause(); return true },
            deliver: { _ in deliveries += 1 }
        )
        let old = Task { await check(manager) }
        await gate.waitForPause()
        old.cancel()
        gate.release()
        await old.value

        XCTAssertEqual(deliveries, 0)
        XCTAssertTrue(manager.notifiedThresholds.isEmpty)
    }

    func testCurrentSessionStillDeduplicatesAndRearmsAfterReset() async {
        var deliveries = 0
        let manager = NotificationManager(requestAuthorization: { true }, deliver: { _ in deliveries += 1 })
        await check(manager)
        await check(manager)
        XCTAssertEqual(deliveries, 1)
        manager.resetNotifications()
        await check(manager)
        XCTAssertEqual(deliveries, 2)
        XCTAssertEqual(manager.notifiedThresholds, [80])
    }

    func testReconnectResetRetiresPendingSessionExpiryBanner() async {
        let gate = Gate()
        var deliveries = 0
        let manager = NotificationManager(
            requestAuthorization: { await gate.pause(); return true },
            deliver: { _ in deliveries += 1 }
        )
        let old = Task { await manager.notifySessionExpired() }
        await gate.waitForPause()
        manager.resetNotifications()
        gate.release()
        await old.value
        XCTAssertEqual(deliveries, 0)
    }
}
