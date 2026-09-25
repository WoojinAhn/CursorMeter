import XCTest
@testable import CursorMeter

@MainActor
final class SplitUsageAlertDispatcherTests: XCTestCase {
    @MainActor private final class PermissionState {
        var allowed = false
    }
    @MainActor private final class Gate {
        private var waiting: CheckedContinuation<Void, Never>?
        private var arrival: CheckedContinuation<Void, Never>?
        func pause() async { await withCheckedContinuation { waiting = $0; arrival?.resume(); arrival = nil } }
        func wait() async { if waiting == nil { await withCheckedContinuation { arrival = $0 } } }
        func release() { waiting?.resume(); waiting = nil }
    }
    private func sample(_ revision: UInt64, percent: Double, cents: Double = 0, account: String = "a", time: Date = Date()) -> SplitUsageObservation {
        SplitUsageObservation(ownership: SplitAlertOwnership(accountDigest: account, requestPlanScope: "personal", generation: 1),
            revision: revision, timestamp: time, includedCents: cents, cursorPercent: percent, otherPercent: percent)
    }
    private func settle(_ dispatcher: SplitUsageAlertDispatcher) async { await dispatcher.waitUntilIdle() }

    func testCorrectionDuringAuthorizationDropsThresholdButKeepsRecentBold() async {
        let gate = Gate()
        var bodies: [String] = []
        let dispatcher = SplitUsageAlertDispatcher(manager: NotificationManager(requestAuthorization: {
            await gate.pause()
            return true
        }, deliver: { bodies.append($0.content.body) }))
        let policy = SplitAlertPolicy(bold: true)
        _ = dispatcher.accept(sample(1, percent: 50), policy: policy)
        _ = dispatcher.accept(sample(2, percent: 95, cents: 40), policy: policy)
        await gate.wait()
        _ = dispatcher.accept(sample(3, percent: 50, cents: 40), policy: policy)
        gate.release()
        await settle(dispatcher)
        XCTAssertEqual(bodies.count, 1)
        XCTAssertFalse(bodies.first?.contains("알림 기준") == true)
        XCTAssertTrue(bodies.first?.contains("+$0.40") == true)
    }

    func testPaidScopeChangeDuringAuthorizationDropsOldBudgetThreshold() async {
        for change in ["cap", "disabled", "unknown", "missingCap"] {
            let gate = Gate()
            var bodies: [String] = []
            var authorizations = 0
            let dispatcher = SplitUsageAlertDispatcher(manager: NotificationManager(requestAuthorization: {
                authorizations += 1
                if authorizations == 1 { await gate.pause() }
                return true
            }, deliver: { bodies.append($0.content.body) }))
            var observation = sample(1, percent: 0)
            observation.paidCents = 95
            observation.paidCapCents = 100
            observation.paidEnabled = true
            _ = dispatcher.accept(observation, policy: .init())
            await gate.wait()
            observation.revision = 2
            switch change {
            case "cap": observation.paidCapCents = 200
            case "disabled": observation.paidEnabled = false
            case "unknown": observation.paidEnabled = nil
            default: observation.paidCapCents = nil
            }
            _ = dispatcher.accept(observation, policy: .init())
            gate.release()
            await settle(dispatcher)
            XCTAssertTrue(bodies.isEmpty, change)
        }
    }

    func testNewPaidBudgetCanNotifyWithoutDeliveringPreviousBudget() async {
        let gate = Gate()
        var bodies: [String] = []
        var authorizations = 0
        let dispatcher = SplitUsageAlertDispatcher(manager: NotificationManager(requestAuthorization: {
            authorizations += 1
            if authorizations == 1 { await gate.pause() }
            return true
        }, deliver: { bodies.append($0.content.body) }))
        var observation = sample(1, percent: 0)
        observation.paidCents = 95
        observation.paidCapCents = 100
        observation.paidEnabled = true
        _ = dispatcher.accept(observation, policy: .init())
        await gate.wait()
        observation.revision = 2
        observation.paidCapCents = 50
        _ = dispatcher.accept(observation, policy: .init())
        gate.release()
        await settle(dispatcher)
        XCTAssertEqual(bodies.count, 1)
        XCTAssertTrue(bodies.first?.contains("현재 190.00%") == true)
    }

    func testCorrectionDuringDeliveryStillRecordsActuallyDeliveredThreshold() async {
        let gate = Gate()
        let store = SplitUsageAlertStore()
        var deliveries = 0
        let observation = sample(1, percent: 95)
        let dispatcher = SplitUsageAlertDispatcher(manager: NotificationManager(requestAuthorization: { true }, deliver: { _ in
            deliveries += 1
            if deliveries == 1 { await gate.pause() }
        }), store: store)
        _ = dispatcher.accept(observation, policy: .init())
        await gate.wait()
        _ = dispatcher.accept(sample(2, percent: 50), policy: .init())
        gate.release()
        await settle(dispatcher)
        let state = await store.load(for: observation.ownership, now: Date())
        XCTAssertFalse(state.identities.isEmpty)
        _ = dispatcher.accept(sample(3, percent: 95), policy: .init())
        await settle(dispatcher)
        XCTAssertEqual(deliveries, 1)
    }

    func testUnrelatedThresholdEditDuringDeliveryDoesNotRepeatDeliveredWarning() async {
        let authorizationGate = Gate()
        let deliveryGate = Gate()
        var authorizations = 0
        var bodies: [String] = []
        let dispatcher = SplitUsageAlertDispatcher(manager: NotificationManager(requestAuthorization: {
            authorizations += 1
            if authorizations == 1 { await authorizationGate.pause() }
            return true
        }, deliver: {
            bodies.append($0.content.body)
            if bodies.count == 1 { await deliveryGate.pause() }
        }))
        var policy = SplitAlertPolicy()
        _ = dispatcher.accept(sample(1, percent: 85), policy: policy)
        await authorizationGate.wait()
        authorizationGate.release()
        await deliveryGate.wait()
        policy.critical = 95
        dispatcher.updatePolicy(policy)
        deliveryGate.release()
        await settle(dispatcher)
        _ = dispatcher.accept(sample(2, percent: 85), policy: policy)
        await settle(dispatcher)
        XCTAssertEqual(bodies.count, 1)
    }

    func testMatchingThresholdUsesLatestAcceptedValue() async {
        let gate = Gate()
        var bodies: [String] = []
        var authorizations = 0
        let dispatcher = SplitUsageAlertDispatcher(manager: NotificationManager(requestAuthorization: {
            authorizations += 1
            if authorizations == 1 { await gate.pause() }
            return true
        }, deliver: { bodies.append($0.content.body) }))
        _ = dispatcher.accept(sample(1, percent: 95), policy: .init())
        await gate.wait()
        _ = dispatcher.accept(sample(2, percent: 97), policy: .init())
        gate.release()
        await settle(dispatcher)
        XCTAssertEqual(bodies.count, 1)
        XCTAssertTrue(bodies.first?.contains("현재 97.00%") == true)
        XCTAssertFalse(bodies.first?.contains("현재 95.00%") == true)
    }

    func testEmptyNewestRevisionRetainsPendingJumpWithinOriginalContinuity() async {
        let gate = Gate()
        var bodies: [String] = []
        var requests = 0
        let dispatcher = SplitUsageAlertDispatcher(manager: NotificationManager(requestAuthorization: {
            requests += 1
            if requests == 1 { await gate.pause() }
            return true
        }, deliver: { bodies.append($0.content.body) }))
        let policy = SplitAlertPolicy(thresholdsEnabled: false, bold: true)
        _ = dispatcher.accept(sample(1, percent: 0), policy: policy)
        _ = dispatcher.accept(sample(2, percent: 15), policy: policy)
        await gate.wait()
        _ = dispatcher.accept(sample(3, percent: 30), policy: policy)
        _ = dispatcher.accept(sample(4, percent: 30), policy: policy)
        XCTAssertEqual(dispatcher.pendingRevision, 4)
        gate.release()
        await settle(dispatcher)
        XCTAssertEqual(bodies.count, 2)
    }

    func testEqualObservationRetainsPendingBoldWithLatestThresholds() async {
        let gate = Gate()
        var bodies: [String] = []
        var requests = 0
        let dispatcher = SplitUsageAlertDispatcher(manager: NotificationManager(requestAuthorization: {
            requests += 1
            if requests == 1 { await gate.pause() }
            return true
        }, deliver: { bodies.append($0.content.body) }))
        let policy = SplitAlertPolicy(bold: true)
        _ = dispatcher.accept(sample(1, percent: 81), policy: policy)
        await gate.wait()
        _ = dispatcher.accept(sample(2, percent: 96), policy: policy)
        _ = dispatcher.accept(sample(3, percent: 96), policy: policy)
        gate.release()
        await settle(dispatcher)
        XCTAssertEqual(bodies.count, 1)
        XCTAssertTrue(bodies.first?.contains("알림 기준 90%") == true)
        XCTAssertTrue(bodies.first?.contains("+15.00 pp") == true)
    }

    func testRetainedPendingBoldExpiresAtOriginalTimestamp() async {
        let gate = Gate()
        var time = Date()
        var bodies: [String] = []
        var requests = 0
        let dispatcher = SplitUsageAlertDispatcher(manager: NotificationManager(requestAuthorization: {
            requests += 1
            if requests == 1 { await gate.pause() }
            return true
        }, deliver: { bodies.append($0.content.body) }), now: { time })
        let policy = SplitAlertPolicy(bold: true)
        _ = dispatcher.accept(sample(1, percent: 81, time: time), policy: policy)
        await gate.wait()
        _ = dispatcher.accept(sample(2, percent: 96, time: time), policy: policy)
        time = time.addingTimeInterval(100)
        _ = dispatcher.accept(sample(3, percent: 96, time: time), policy: policy)
        time = time.addingTimeInterval(21)
        gate.release()
        await settle(dispatcher)
        XCTAssertEqual(bodies.count, 1)
        XCTAssertTrue(bodies.first?.contains("알림 기준 90%") == true)
        XCTAssertFalse(bodies.first?.contains("+15.00 pp") == true)
    }

    func testPendingBoldSurvivesThresholdEditButNotBoldDisable() async {
        for disableBold in [false, true] {
            let gate = Gate()
            var bodies: [String] = []
            var requests = 0
            let dispatcher = SplitUsageAlertDispatcher(manager: NotificationManager(requestAuthorization: {
                requests += 1
                if requests == 1 { await gate.pause() }
                return true
            }, deliver: { bodies.append($0.content.body) }))
            var policy = SplitAlertPolicy(bold: true)
            _ = dispatcher.accept(sample(1, percent: 81), policy: policy)
            await gate.wait()
            _ = dispatcher.accept(sample(2, percent: 96), policy: policy)
            policy.thresholdsEnabled = false
            policy.bold = !disableBold
            dispatcher.updatePolicy(policy)
            _ = dispatcher.accept(sample(3, percent: 96), policy: policy)
            gate.release()
            await settle(dispatcher)
            XCTAssertEqual(bodies.count, disableBold ? 0 : 1)
            if !disableBold {
                XCTAssertTrue(bodies.first?.contains("+15.00 pp") == true)
                XCTAssertFalse(bodies.first?.contains("알림 기준") == true)
            }
        }
    }

    func testPendingBoldIsCancelledByOwnershipOrContinuityChange() async {
        for change in ["account", "generation", "continuity"] {
            let gate = Gate()
            var bodies: [String] = []
            var requests = 0
            let dispatcher = SplitUsageAlertDispatcher(manager: NotificationManager(requestAuthorization: {
                requests += 1
                if requests == 1 { await gate.pause() }
                return true
            }, deliver: { bodies.append($0.content.body) }))
            let policy = SplitAlertPolicy(bold: true)
            _ = dispatcher.accept(sample(1, percent: 81), policy: policy)
            await gate.wait()
            _ = dispatcher.accept(sample(2, percent: 96), policy: policy)
            var next = sample(3, percent: 96)
            switch change {
            case "account": next.ownership.accountDigest = "b"
            case "generation": next.ownership.generation = 2
            default: dispatcher.resetContinuity()
            }
            _ = dispatcher.accept(next, policy: policy)
            gate.release()
            await settle(dispatcher)
            XCTAssertEqual(bodies.count, 1, change)
            XCTAssertFalse(bodies.first?.contains("+15.00 pp") == true, change)
        }
    }

    func testNewPendingBoldReplacesPreviousPendingBold() async {
        let gate = Gate()
        var bodies: [String] = []
        var requests = 0
        let dispatcher = SplitUsageAlertDispatcher(manager: NotificationManager(requestAuthorization: {
            requests += 1
            if requests == 1 { await gate.pause() }
            return true
        }, deliver: { bodies.append($0.content.body) }))
        let policy = SplitAlertPolicy(thresholdsEnabled: false, bold: true)
        _ = dispatcher.accept(sample(1, percent: 0), policy: policy)
        _ = dispatcher.accept(sample(2, percent: 15), policy: policy)
        await gate.wait()
        _ = dispatcher.accept(sample(3, percent: 30), policy: policy)
        _ = dispatcher.accept(sample(4, percent: 50), policy: policy)
        _ = dispatcher.accept(sample(5, percent: 50), policy: policy)
        gate.release()
        await settle(dispatcher)
        XCTAssertEqual(bodies.count, 2)
        XCTAssertTrue(bodies.last?.contains("+20.00 pp") == true)
        XCTAssertFalse(bodies.last?.contains("+15.00 pp") == true)
    }

    func testContinuityResetRetiresAwaitingBoldAndRetainsCycleHighWater() async {
        let gate = Gate()
        var bodies: [String] = []
        let dispatcher = SplitUsageAlertDispatcher(manager: NotificationManager(requestAuthorization: {
            await gate.pause()
            return true
        }, deliver: { bodies.append($0.content.body) }))
        let policy = SplitAlertPolicy(thresholdsEnabled: false, bold: true)
        _ = dispatcher.accept(sample(1, percent: 35), policy: policy)
        XCTAssertEqual(dispatcher.accept(sample(2, percent: 50), policy: policy)?.tier, 2)
        await gate.wait()
        dispatcher.resetContinuity()
        gate.release()
        await settle(dispatcher)
        XCTAssertTrue(bodies.isEmpty)
        XCTAssertNil(dispatcher.accept(sample(3, percent: 40), policy: policy))
        let rebound = dispatcher.accept(sample(4, percent: 56), policy: policy)
        XCTAssertEqual(rebound?.tier, 1)
        XCTAssertEqual(rebound?.deltas[.cursor], 6)
        XCTAssertEqual(rebound?.deltas[.other], 6)
    }

    func testContinuityResetKeepsAwaitingThresholdComponent() async {
        let gate = Gate()
        var bodies: [String] = []
        let dispatcher = SplitUsageAlertDispatcher(manager: NotificationManager(requestAuthorization: {
            await gate.pause()
            return true
        }, deliver: { bodies.append($0.content.body) }))
        let policy = SplitAlertPolicy(bold: true)
        _ = dispatcher.accept(sample(1, percent: 50), policy: policy)
        _ = dispatcher.accept(sample(2, percent: 95, cents: 40), policy: policy)
        await gate.wait()
        dispatcher.resetContinuity()
        gate.release()
        await settle(dispatcher)
        XCTAssertEqual(bodies.count, 1)
        XCTAssertTrue(bodies.first?.contains("알림 기준") == true)
        XCTAssertFalse(bodies.first?.contains("+$0.40") == true)
    }

    func testDefaultPermissionQueryIsMemoryOnly() async {
        let state = await NotificationManager().permissionState()
        XCTAssertEqual(state, .unknown)
    }

    func testGroupedThresholdsAndBoldAreOneSubmissionAndCriticalCoversWarning() async {
        var bodies: [String] = []
        let dispatcher = SplitUsageAlertDispatcher(manager: NotificationManager(requestAuthorization: { true }, deliver: { bodies.append($0.content.body) }))
        let policy = SplitAlertPolicy(bold: true)
        _ = dispatcher.accept(sample(1, percent: 50), policy: policy)
        _ = dispatcher.accept(sample(2, percent: 95, cents: 40), policy: policy)
        await settle(dispatcher)
        XCTAssertEqual(bodies.count, 1)
        XCTAssertTrue(bodies.first?.contains("알림 기준 90%") == true)
        XCTAssertTrue(bodies.first?.contains("+$0.40") == true)
        _ = dispatcher.accept(sample(3, percent: 85, cents: 40), policy: policy)
        await settle(dispatcher)
        XCTAssertEqual(bodies.count, 1)
    }

    func testHeldAuthorizationDoesNotBlockNewRevisionAndKeepsOnlyNewestPending() async {
        let gate = Gate()
        var authorizationCount = 0
        var bodies: [String] = []
        let dispatcher = SplitUsageAlertDispatcher(manager: NotificationManager(requestAuthorization: {
            authorizationCount += 1
            if authorizationCount == 1 { await gate.pause() }
            return true
        }, deliver: { bodies.append($0.content.body) }))
        _ = dispatcher.accept(sample(1, percent: 81), policy: .init())
        await gate.wait()
        _ = dispatcher.accept(sample(2, percent: 86), policy: .init())
        _ = dispatcher.accept(sample(3, percent: 95), policy: .init())
        XCTAssertEqual(dispatcher.pendingRevision, 3)
        gate.release()
        await settle(dispatcher)
        XCTAssertEqual(bodies.count, 1)
        XCTAssertTrue(bodies.last?.contains("현재 95") == true)
    }

    func testThresholdPolicyEditRetainsBoldWhileAwaitingAuthorization() async {
        let gate = Gate()
        var bodies: [String] = []
        let dispatcher = SplitUsageAlertDispatcher(manager: NotificationManager(requestAuthorization: { await gate.pause(); return true }, deliver: { bodies.append($0.content.body) }))
        var policy = SplitAlertPolicy(bold: true)
        _ = dispatcher.accept(sample(1, percent: 50), policy: policy)
        _ = dispatcher.accept(sample(2, percent: 95, cents: 40), policy: policy)
        await gate.wait()
        policy.thresholdsEnabled = false
        dispatcher.updatePolicy(policy)
        gate.release()
        await settle(dispatcher)
        XCTAssertEqual(bodies.count, 1)
        XCTAssertFalse(bodies[0].contains("알림 기준"))
        XCTAssertTrue(bodies[0].contains("+$0.40"))
    }

    func testBoldEditRetainsThresholdWhileAwaitingAuthorization() async {
        let gate = Gate()
        var bodies: [String] = []
        let dispatcher = SplitUsageAlertDispatcher(manager: NotificationManager(requestAuthorization: { await gate.pause(); return true }, deliver: { bodies.append($0.content.body) }))
        var policy = SplitAlertPolicy(bold: true)
        _ = dispatcher.accept(sample(1, percent: 50), policy: policy)
        _ = dispatcher.accept(sample(2, percent: 95, cents: 40), policy: policy)
        await gate.wait()
        policy.bold = false
        dispatcher.updatePolicy(policy)
        gate.release()
        await settle(dispatcher)
        XCTAssertEqual(bodies.count, 1)
        XCTAssertTrue(bodies[0].contains("알림 기준"))
        XCTAssertFalse(bodies[0].contains("+$0.40"))
    }

    func testFailedDeliveryAndDeniedAuthorizationRetryOnNextFreshRevision() async {
        enum Failure: Error { case rejected }
        var attempts = 0
        let dispatcher = SplitUsageAlertDispatcher(manager: NotificationManager(requestAuthorization: { true }, deliver: { _ in
            attempts += 1
            if attempts == 1 { throw Failure.rejected }
        }))
        _ = dispatcher.accept(sample(1, percent: 95), policy: .init())
        await settle(dispatcher)
        _ = dispatcher.accept(sample(2, percent: 95), policy: .init())
        await settle(dispatcher)
        _ = dispatcher.accept(sample(3, percent: 95), policy: .init())
        await settle(dispatcher)
        XCTAssertEqual(attempts, 2)

        let permission = PermissionState()
        var sent = 0
        let denied = SplitUsageAlertDispatcher(manager: NotificationManager(requestAuthorization: { permission.allowed }, deliver: { _ in sent += 1 }))
        _ = denied.accept(sample(1, percent: 95), policy: .init())
        await settle(denied)
        permission.allowed = true
        _ = denied.accept(sample(2, percent: 95), policy: .init())
        await settle(denied)
        XCTAssertEqual(sent, 1)
    }

    func testAccountChangeDuringAuthorizationSuppressesOldAccount() async {
        let gate = Gate()
        var sent = 0
        let dispatcher = SplitUsageAlertDispatcher(manager: NotificationManager(requestAuthorization: { await gate.pause(); return true }, deliver: { _ in sent += 1 }))
        _ = dispatcher.accept(sample(1, percent: 95), policy: .init())
        await gate.wait()
        _ = dispatcher.accept(sample(2, percent: 20, account: "b"), policy: .init())
        gate.release()
        await settle(dispatcher)
        XCTAssertEqual(sent, 0)
    }

    func testOldSubmissionCannotRecordSuccessAfterLogout() async {
        let gate = Gate()
        let store = SplitUsageAlertStore()
        let observation = sample(1, percent: 95)
        let dispatcher = SplitUsageAlertDispatcher(manager: NotificationManager(requestAuthorization: { true }, deliver: { _ in await gate.pause() }), store: store)
        _ = dispatcher.accept(observation, policy: .init())
        await gate.wait()
        dispatcher.logout(accountDigest: "a")
        gate.release()
        await settle(dispatcher)
        let state = await store.load(for: observation.ownership, now: Date())
        XCTAssertTrue(state.identities.isEmpty)
    }

    func testStaleBoldExpiresWhileFreshThresholdRemainsEligible() async {
        let gate = Gate()
        var time = Date()
        var bodies: [String] = []
        let dispatcher = SplitUsageAlertDispatcher(manager: NotificationManager(requestAuthorization: { await gate.pause(); return true }, deliver: { bodies.append($0.content.body) }), now: { time })
        let policy = SplitAlertPolicy(bold: true)
        _ = dispatcher.accept(sample(1, percent: 50, time: time), policy: policy)
        _ = dispatcher.accept(sample(2, percent: 95, cents: 40, time: time), policy: policy)
        await gate.wait()
        time = time.addingTimeInterval(121)
        gate.release()
        await settle(dispatcher)
        XCTAssertEqual(bodies.count, 1)
        XCTAssertFalse(bodies[0].contains("+$0.40"))
        XCTAssertTrue(bodies[0].contains("알림 기준"))
    }
}
