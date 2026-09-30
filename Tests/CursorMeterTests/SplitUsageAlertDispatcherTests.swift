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
    private func makeDispatcher(manager: NotificationManager, store: SplitUsageAlertStore = SplitUsageAlertStore(),
                                now: @escaping @MainActor () -> Date = { Date() }) async -> SplitUsageAlertDispatcher {
        let dispatcher = SplitUsageAlertDispatcher(manager: manager, store: store, now: now)
        let prepared = await dispatcher.prepareProfileAuthority(freshSubjectDigest: nil)
        XCTAssertTrue(prepared)
        return dispatcher
    }

    private func settle(_ dispatcher: SplitUsageAlertDispatcher) async { await dispatcher.waitUntilIdle() }

    private func persistentSample(_ revision: UInt64, subject: String? = "verified-subject", percent: Double = 95) -> SplitUsageObservation {
        var value = sample(revision, percent: percent, time: Date(timeIntervalSince1970: 2900000))
        value.ownership.persistentSubjectDigest = subject
        value.ownership.cycleStart = Date(timeIntervalSince1970: 500000)
        value.ownership.cycleEnd = Date(timeIntervalSince1970: 3000000)
        return value
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testUnpreparedAuthorityCannotSubmitOrPersist() async throws {
        let directory = try directory()
        var deliveries = 0
        let dispatcher = SplitUsageAlertDispatcher(manager: NotificationManager(requestAuthorization: { true },
            deliver: { _ in deliveries += 1 }), store: SplitUsageAlertStore(directory: directory))
        _ = dispatcher.accept(persistentSample(1), policy: .init())
        await settle(dispatcher)
        XCTAssertEqual(deliveries, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        let prepared = await dispatcher.prepareProfileAuthority(freshSubjectDigest: nil)
        XCTAssertTrue(prepared)
        _ = dispatcher.accept(persistentSample(2, subject: nil), policy: .init())
        await settle(dispatcher)
        XCTAssertEqual(deliveries, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testCancelledAuthorityPreparationCannotAcceptPublication() async {
        let dispatcher = SplitUsageAlertDispatcher(manager: NotificationManager(requestAuthorization: { true }, deliver: { _ in
            XCTFail("Cancelled preparation must not authorize publication")
        }))
        let task = Task { await dispatcher.prepareProfileAuthority(freshSubjectDigest: "verified-subject") }
        task.cancel()
        let prepared = await task.value
        XCTAssertFalse(prepared)
        _ = dispatcher.accept(persistentSample(1), policy: .init())
        await settle(dispatcher)
    }

    func testSuccessfulDeliveryAcrossDowngradeAndRecoveryIsSessionOnlyAndNotRepeated() async throws {
        for recoverBeforeReceipt in [false, true] {
            let directory = try directory()
            let gate = Gate()
            var deliveries = 0
            let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: { true }, deliver: { _ in
                deliveries += 1
                if deliveries == 1 { await gate.pause() }
            }), store: SplitUsageAlertStore(directory: directory))
            let fresh = await dispatcher.prepareProfileAuthority(freshSubjectDigest: "verified-subject")
            XCTAssertTrue(fresh)
            _ = dispatcher.accept(persistentSample(1), policy: .init())
            await gate.wait()
            let degraded = await dispatcher.prepareProfileAuthority(freshSubjectDigest: nil)
            XCTAssertTrue(degraded)
            _ = dispatcher.accept(persistentSample(2, subject: nil), policy: .init())
            if recoverBeforeReceipt {
                let recovered = await dispatcher.prepareProfileAuthority(freshSubjectDigest: "verified-subject")
                XCTAssertTrue(recovered)
                _ = dispatcher.accept(persistentSample(3), policy: .init())
            }
            gate.release()
            await settle(dispatcher)
            XCTAssertEqual(deliveries, 1)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)

            let recovered = await dispatcher.prepareProfileAuthority(freshSubjectDigest: "verified-subject")
            XCTAssertTrue(recovered)
            _ = dispatcher.accept(persistentSample(4), policy: .init())
            await settle(dispatcher)
            XCTAssertEqual(deliveries, 1)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    func testAcknowledgedDegradedThresholdSurvivesOwnershipInvalidation() async throws {
        let recoverySubjects: [String?] = [nil, "verified-subject"]
        for recoveredSubject in recoverySubjects {
            let directory = try directory()
            var deliveries = 0
            let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: { true },
                deliver: { _ in deliveries += 1 }), store: SplitUsageAlertStore(directory: directory))
            _ = dispatcher.accept(persistentSample(1, subject: nil), policy: .init())
            await settle(dispatcher)
            XCTAssertEqual(deliveries, 1)

            dispatcher.invalidateOwnership()
            let prepared = await dispatcher.prepareProfileAuthority(freshSubjectDigest: recoveredSubject)
            XCTAssertTrue(prepared)
            _ = dispatcher.accept(persistentSample(2, subject: recoveredSubject), policy: .init())
            await settle(dispatcher)

            XCTAssertEqual(deliveries, 1, "Ownership invalidation must retain acknowledged same-scope delivery knowledge")
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty,
                          "Recovery must not promote an earlier session-only receipt to disk")
        }
    }

    func testLoadedLedgerKnowledgeSuppressesDegradedAndRecoveredNotifications() async throws {
        let directory = try directory()
        var deliveries = 0
        let manager = NotificationManager(requestAuthorization: { true }, deliver: { _ in deliveries += 1 })
        let writer = await makeDispatcher(manager: manager, store: SplitUsageAlertStore(directory: directory))
        let initial = await writer.prepareProfileAuthority(freshSubjectDigest: "verified-subject")
        XCTAssertTrue(initial)
        _ = writer.accept(persistentSample(1), policy: .init())
        await settle(writer)
        XCTAssertEqual(deliveries, 1)
        let url = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let original = try Data(contentsOf: url)

        let dispatcher = await makeDispatcher(manager: manager, store: SplitUsageAlertStore(directory: directory))
        let fresh = await dispatcher.prepareProfileAuthority(freshSubjectDigest: "verified-subject")
        XCTAssertTrue(fresh)
        _ = dispatcher.accept(persistentSample(1), policy: .init())
        await settle(dispatcher)
        let degraded = await dispatcher.prepareProfileAuthority(freshSubjectDigest: nil)
        XCTAssertTrue(degraded)
        try Data("must-not-be-read".utf8).write(to: url)
        _ = dispatcher.accept(persistentSample(2, subject: nil), policy: .init())
        await settle(dispatcher)
        XCTAssertEqual(deliveries, 1)
        XCTAssertEqual(try Data(contentsOf: url), Data("must-not-be-read".utf8))
        try original.write(to: url)
        let recovered = await dispatcher.prepareProfileAuthority(freshSubjectDigest: "verified-subject")
        XCTAssertTrue(recovered)
        _ = dispatcher.accept(persistentSample(3), policy: .init())
        await settle(dispatcher)
        XCTAssertEqual(deliveries, 1)
        XCTAssertEqual(try Data(contentsOf: url), original)
    }

    func testLifecycleChangeRejectsLateSuccessfulDelivery() async throws {
        for change in ["logout", "account", "scope", "cycle", "generation"] {
            let directory = try directory()
            let gate = Gate()
            var deliveries = 0
            let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: { true }, deliver: { _ in
                deliveries += 1
                if deliveries == 1 { await gate.pause() }
            }), store: SplitUsageAlertStore(directory: directory))
            let prepared = await dispatcher.prepareProfileAuthority(freshSubjectDigest: "verified-subject")
            XCTAssertTrue(prepared)
            let original = persistentSample(1)
            _ = dispatcher.accept(original, policy: .init())
            await gate.wait()
            if change == "logout" {
                dispatcher.logout(accountDigest: original.ownership.accountDigest)
            } else {
                var next = persistentSample(2, percent: 20)
                switch change {
                case "account": next.ownership.accountDigest = "other-account"
                case "scope": next.ownership.requestPlanScope = "team"
                case "cycle": next.ownership.cycleEnd = next.ownership.cycleEnd?.addingTimeInterval(86400)
                default: next.ownership.generation += 1
                }
                _ = dispatcher.accept(next, policy: .init())
            }
            gate.release()
            await settle(dispatcher)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty, change)
            let recovered = await dispatcher.prepareProfileAuthority(freshSubjectDigest: "verified-subject")
            XCTAssertTrue(recovered)
            _ = dispatcher.accept(persistentSample(3), policy: .init())
            await settle(dispatcher)
            XCTAssertEqual(deliveries, 2, change)
        }
    }

    func testPresentationFallbackRetiresUnsubmittedThresholdAndBold() async {
        let gate = Gate()
        var deliveries = 0
        let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: {
            await gate.pause()
            return true
        }, deliver: { _ in deliveries += 1 }))
        let policy = SplitAlertPolicy(bold: true)
        let initial = sample(1, percent: 10)
        dispatcher.accept(initial, policy: policy)
        dispatcher.accept(sample(2, percent: 95, cents: 1000), policy: policy)
        await gate.wait()
        XCTAssertFalse(dispatcher.reconcilePresentation(ownership: initial.ownership, isSplit: false))
        XCTAssertFalse(dispatcher.reconcilePresentation(ownership: initial.ownership, isSplit: true))
        gate.release()
        await settle(dispatcher)
        XCTAssertEqual(deliveries, 0, "Returning to split must not revive unsent threshold or Bold components")
        var baselinePolicy = policy
        baselinePolicy.thresholdsEnabled = false
        XCTAssertNil(dispatcher.accept(sample(3, percent: 100), policy: baselinePolicy), "Fallback must reset the jump baseline")
        await settle(dispatcher)
    }

    func testOwnershipChangeDuringPresentationGapRejectsInFlightReceipt() async throws {
        for change in ["account", "scope", "cycle", "generation", "unavailable", "logout"] {
            let directory = try directory()
            let gate = Gate()
            var deliveries = 0
            let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: { true }, deliver: { _ in
                deliveries += 1
                if deliveries == 1 { await gate.pause() }
            }), store: SplitUsageAlertStore(directory: directory))
            let original = persistentSample(1, subject: nil)
            dispatcher.accept(original, policy: .init())
            await gate.wait()
            XCTAssertFalse(dispatcher.reconcilePresentation(ownership: original.ownership, isSplit: false))
            var changed = original.ownership
            switch change {
            case "account": changed.accountDigest = "other-account"
            case "scope": changed.requestPlanScope = "other-scope"
            case "cycle": changed.cycleEnd = changed.cycleEnd?.addingTimeInterval(86400)
            case "generation": changed.generation += 1
            default: break
            }
            if change == "logout" {
                dispatcher.logout(accountDigest: original.ownership.accountDigest)
            } else {
                XCTAssertTrue(dispatcher.reconcilePresentation(ownership: change == "unavailable" ? nil : changed,
                                                              isSplit: false), change)
            }
            let prepared = await dispatcher.prepareProfileAuthority(freshSubjectDigest: nil)
            XCTAssertTrue(prepared)
            dispatcher.reconcilePresentation(ownership: original.ownership, isSplit: true)
            dispatcher.accept(persistentSample(2, subject: nil), policy: .init())
            gate.release()
            await settle(dispatcher)
            XCTAssertEqual(deliveries, 2, "Returning to the original owner cannot resurrect a retired receipt: \(change)")
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    func testNewThresholdAndBoldStayTogetherWhenAuthorizationWaits() async {
        let gate = Gate()
        var payloads: [UsageNotificationContent] = []
        var authorizations = 0
        let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: {
            authorizations += 1
            if authorizations == 1 { await gate.pause() }
            return true
        }, deliver: { payloads.append(.init(title: $0.content.title, body: $0.content.body)) }))
        let policy = SplitAlertPolicy(warning: 50, critical: 100, targets: [.cursor], bold: true)
        func observation(_ revision: UInt64, percent: Double) -> SplitUsageObservation {
            var value = sample(revision, percent: percent)
            value.otherPercent = 0
            return value
        }
        _ = dispatcher.accept(observation(1, percent: 40), policy: policy)
        _ = dispatcher.accept(observation(2, percent: 55), policy: policy)
        await gate.wait()
        _ = dispatcher.accept(observation(3, percent: 70), policy: policy)
        gate.release()
        await settle(dispatcher)
        _ = dispatcher.accept(observation(4, percent: 70), policy: policy)
        await settle(dispatcher)
        XCTAssertEqual(payloads, [.init(title: "Cursor Models 70.0% · Warning",
                                       body: "Your warning level is 50%.\nLast refresh 55.0% → now 70.0%")])
    }

    func testNewerThresholdOmitsOlderBoldWithoutReplayingIt() async {
        let gate = Gate()
        var payloads: [UsageNotificationContent] = []
        var authorizations = 0
        let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: {
            authorizations += 1
            if authorizations == 1 { await gate.pause() }
            return true
        }, deliver: { payloads.append(.init(title: $0.content.title, body: $0.content.body)) }))
        let policy = SplitAlertPolicy(targets: [.cursor], bold: true)
        _ = dispatcher.accept(sample(1, percent: 65), policy: policy)
        _ = dispatcher.accept(sample(2, percent: 82), policy: policy)
        await gate.wait()
        _ = dispatcher.accept(sample(3, percent: 86), policy: policy)
        gate.release()
        await settle(dispatcher)
        _ = dispatcher.accept(sample(4, percent: 86), policy: policy)
        await settle(dispatcher)
        XCTAssertEqual(payloads, [.init(title: "Cursor Models 86.0% · Warning", body: "Your warning level is 80%.")])
        XCTAssertFalse(payloads.contains { $0.body.contains("since last refresh") })
    }

    func testScopeEditCancelsPendingThresholdUntilFreshObservation() async {
        let gate = Gate()
        var bodies: [String] = []
        var requests = 0
        let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: {
            requests += 1
            if requests == 1 { await gate.pause() }
            return true
        }, deliver: { bodies.append($0.content.title + "\n" + $0.content.body) }))
        var policy = SplitAlertPolicy(targets: [.cursor])
        _ = dispatcher.accept(sample(1, percent: 85), policy: policy)
        await gate.wait()
        policy.thresholdsByScope[.cursor] = .init(warning: 70, critical: 95)
        dispatcher.updatePolicy(policy)
        gate.release()
        await settle(dispatcher)
        XCTAssertTrue(bodies.isEmpty)
        _ = dispatcher.accept(sample(2, percent: 85), policy: policy)
        await settle(dispatcher)
        XCTAssertEqual(bodies.count, 1)
        XCTAssertTrue(bodies[0].contains("level is 70%"))
        _ = dispatcher.accept(sample(3, percent: 85), policy: policy)
        await settle(dispatcher)
        XCTAssertEqual(bodies.count, 1)
    }

    func testCriticalPromotionRetiresOlderWarningCompanion() async {
        let gate = Gate()
        var payloads: [UsageNotificationContent] = []
        var authorizations = 0
        let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: {
            authorizations += 1
            if authorizations == 1 { await gate.pause() }
            return true
        }, deliver: { payloads.append(.init(title: $0.content.title, body: $0.content.body)) }))
        let policy = SplitAlertPolicy(targets: [.cursor], bold: true)
        _ = dispatcher.accept(sample(1, percent: 65), policy: policy)
        _ = dispatcher.accept(sample(2, percent: 82), policy: policy)
        await gate.wait()
        _ = dispatcher.accept(sample(3, percent: 95), policy: policy)
        gate.release()
        await settle(dispatcher)
        XCTAssertEqual(payloads, [.init(title: "Cursor Models 95.0% · Critical", body: "Your critical level is 90%.")])
    }

    func testFreshThresholdAfterPolicyEditRetiresOlderBold() async {
        let gate = Gate()
        var payloads: [UsageNotificationContent] = []
        var authorizations = 0
        let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: {
            authorizations += 1
            if authorizations == 1 { await gate.pause() }
            return true
        }, deliver: { payloads.append(.init(title: $0.content.title, body: $0.content.body)) }))
        var policy = SplitAlertPolicy(targets: [.cursor], bold: true)
        _ = dispatcher.accept(sample(1, percent: 65), policy: policy)
        _ = dispatcher.accept(sample(2, percent: 82), policy: policy)
        await gate.wait()
        policy.thresholdsByScope[.cursor] = .init(warning: 75, critical: 95)
        dispatcher.updatePolicy(policy)
        _ = dispatcher.accept(sample(3, percent: 86), policy: policy)
        gate.release()
        await settle(dispatcher)
        XCTAssertEqual(payloads, [.init(title: "Cursor Models 86.0% · Warning", body: "Your warning level is 75%.")])
    }

    func testAlreadyDeliveredThresholdDoesNotRetirePendingBold() async {
        let gate = Gate()
        var payloads: [UsageNotificationContent] = []
        var authorizations = 0
        let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: {
            authorizations += 1
            if authorizations == 2 { await gate.pause() }
            return true
        }, deliver: { payloads.append(.init(title: $0.content.title, body: $0.content.body)) }))
        let policy = SplitAlertPolicy(warning: 20, critical: 100, targets: [.cursor], bold: true)
        _ = dispatcher.accept(sample(1, percent: 30), policy: policy)
        await settle(dispatcher)
        _ = dispatcher.accept(sample(2, percent: 45), policy: policy)
        await gate.wait()
        _ = dispatcher.accept(sample(3, percent: 60), policy: policy)
        _ = dispatcher.accept(sample(4, percent: 60), policy: policy)
        gate.release()
        await settle(dispatcher)
        XCTAssertEqual(payloads.count, 3)
        XCTAssertTrue(payloads.last?.body.contains("45.0% → now 60.0%") == true)
    }

    func testMaterializingSamePairDoesNotCancelPendingThreshold() async {
        let gate = Gate()
        var bodies: [String] = []
        let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: {
            await gate.pause()
            return true
        }, deliver: { bodies.append($0.content.title + "\n" + $0.content.body) }))
        var policy = SplitAlertPolicy(targets: [.cursor])
        _ = dispatcher.accept(sample(1, percent: 85), policy: policy)
        await gate.wait()
        policy.thresholdsByScope[.cursor] = .init(warning: 80, critical: 90)
        dispatcher.updatePolicy(policy)
        gate.release()
        await settle(dispatcher)
        XCTAssertEqual(bodies.count, 1)
    }

    func testCorrectionDuringAuthorizationDropsThresholdButKeepsRecentBold() async {
        let gate = Gate()
        var bodies: [String] = []
        let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: {
            await gate.pause()
            return true
        }, deliver: { bodies.append($0.content.title + "\n" + $0.content.body) }))
        let policy = SplitAlertPolicy(bold: true)
        _ = dispatcher.accept(sample(1, percent: 50), policy: policy)
        _ = dispatcher.accept(sample(2, percent: 95, cents: 40), policy: policy)
        await gate.wait()
        _ = dispatcher.accept(sample(3, percent: 50, cents: 40), policy: policy)
        gate.release()
        await settle(dispatcher)
        XCTAssertEqual(bodies.count, 1)
        XCTAssertFalse(bodies.first?.contains("level is") == true)
        XCTAssertTrue(bodies.first?.contains("+$0.40") == true)
    }

    func testPaidScopeChangeDuringAuthorizationDropsOldBudgetThreshold() async {
        for change in ["cap", "disabled", "unknown", "missingCap"] {
            let gate = Gate()
            var bodies: [String] = []
            var authorizations = 0
            let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: {
                authorizations += 1
                if authorizations == 1 { await gate.pause() }
                return true
            }, deliver: { bodies.append($0.content.title + "\n" + $0.content.body) }))
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
        let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: {
            authorizations += 1
            if authorizations == 1 { await gate.pause() }
            return true
        }, deliver: { bodies.append($0.content.title + "\n" + $0.content.body) }))
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
        XCTAssertTrue(bodies.first?.contains("190.0% ·") == true)
    }

    func testCorrectionDuringDeliveryStillRecordsActuallyDeliveredThreshold() async {
        let gate = Gate()
        let store = SplitUsageAlertStore()
        var deliveries = 0
        let observation = sample(1, percent: 95)
        let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: { true }, deliver: { _ in
            deliveries += 1
            if deliveries == 1 { await gate.pause() }
        }), store: store)
        _ = dispatcher.accept(observation, policy: .init())
        await gate.wait()
        _ = dispatcher.accept(sample(2, percent: 50), policy: .init())
        gate.release()
        await settle(dispatcher)
        _ = dispatcher.accept(sample(3, percent: 95), policy: .init())
        await settle(dispatcher)
        XCTAssertEqual(deliveries, 1)
    }

    func testUnrelatedThresholdEditDuringDeliveryDoesNotRepeatDeliveredWarning() async {
        let authorizationGate = Gate()
        let deliveryGate = Gate()
        var authorizations = 0
        var bodies: [String] = []
        let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: {
            authorizations += 1
            if authorizations == 1 { await authorizationGate.pause() }
            return true
        }, deliver: {
            bodies.append($0.content.title + "\n" + $0.content.body)
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
        let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: {
            authorizations += 1
            if authorizations == 1 { await gate.pause() }
            return true
        }, deliver: { bodies.append($0.content.title + "\n" + $0.content.body) }))
        _ = dispatcher.accept(sample(1, percent: 95), policy: .init())
        await gate.wait()
        _ = dispatcher.accept(sample(2, percent: 97), policy: .init())
        gate.release()
        await settle(dispatcher)
        XCTAssertEqual(bodies.count, 1)
        XCTAssertTrue(bodies.first?.contains("97.0% ·") == true)
        XCTAssertFalse(bodies.first?.contains("95.0% ·") == true)
    }

    func testEmptyNewestRevisionRetainsPendingJumpWithinOriginalContinuity() async {
        let gate = Gate()
        var bodies: [String] = []
        var requests = 0
        let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: {
            requests += 1
            if requests == 1 { await gate.pause() }
            return true
        }, deliver: { bodies.append($0.content.title + "\n" + $0.content.body) }))
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

    func testEqualObservationOmitsPendingBoldFromAnOlderRevision() async {
        let gate = Gate()
        var bodies: [String] = []
        var requests = 0
        let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: {
            requests += 1
            if requests == 1 { await gate.pause() }
            return true
        }, deliver: { bodies.append($0.content.title + "\n" + $0.content.body) }))
        let policy = SplitAlertPolicy(bold: true)
        _ = dispatcher.accept(sample(1, percent: 81), policy: policy)
        await gate.wait()
        _ = dispatcher.accept(sample(2, percent: 96), policy: policy)
        _ = dispatcher.accept(sample(3, percent: 96), policy: policy)
        gate.release()
        await settle(dispatcher)
        XCTAssertEqual(bodies.count, 1)
        XCTAssertTrue(bodies.first?.contains("level is 90%") == true)
        XCTAssertFalse(bodies.first?.contains("→") == true)
    }

    func testRetainedPendingBoldExpiresAtOriginalTimestamp() async {
        let gate = Gate()
        var time = Date()
        var bodies: [String] = []
        var requests = 0
        let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: {
            requests += 1
            if requests == 1 { await gate.pause() }
            return true
        }, deliver: { bodies.append($0.content.body) }), now: { time })
        let policy = SplitAlertPolicy(thresholdsEnabled: false, bold: true)
        _ = dispatcher.accept(sample(1, percent: 0, time: time), policy: policy)
        _ = dispatcher.accept(sample(2, percent: 15, time: time), policy: policy)
        await gate.wait()
        _ = dispatcher.accept(sample(3, percent: 30, time: time), policy: policy)
        time = time.addingTimeInterval(100)
        _ = dispatcher.accept(sample(4, percent: 30, time: time), policy: policy)
        time = time.addingTimeInterval(21)
        gate.release()
        await settle(dispatcher)
        XCTAssertTrue(bodies.isEmpty)
    }

    func testPendingBoldSurvivesThresholdEditButNotBoldDisable() async {
        for disableBold in [false, true] {
            let gate = Gate()
            var bodies: [String] = []
            var requests = 0
            let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: {
                requests += 1
                if requests == 1 { await gate.pause() }
                return true
            }, deliver: { bodies.append($0.content.title + "\n" + $0.content.body) }))
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
                XCTAssertTrue(bodies.first?.contains("81.0% → now 96.0%") == true)
                XCTAssertFalse(bodies.first?.contains("level is") == true)
            }
        }
    }

    func testPendingBoldIsCancelledByOwnershipOrContinuityChange() async {
        for change in ["account", "generation", "continuity"] {
            let gate = Gate()
            var bodies: [String] = []
            var requests = 0
            let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: {
                requests += 1
                if requests == 1 { await gate.pause() }
                return true
            }, deliver: { bodies.append($0.content.title + "\n" + $0.content.body) }))
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
            XCTAssertFalse(bodies.first?.contains("→") == true, change)
        }
    }

    func testNewPendingBoldReplacesPreviousPendingBold() async {
        let gate = Gate()
        var bodies: [String] = []
        var requests = 0
        let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: {
            requests += 1
            if requests == 1 { await gate.pause() }
            return true
        }, deliver: { bodies.append($0.content.title + "\n" + $0.content.body) }))
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
        XCTAssertTrue(bodies.last?.contains("30.0% → now 50.0%") == true)
        XCTAssertFalse(bodies.last?.contains("15.0% → now 30.0%") == true)
    }

    func testContinuityResetRetiresAwaitingBoldAndRetainsCycleHighWater() async {
        let gate = Gate()
        var bodies: [String] = []
        let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: {
            await gate.pause()
            return true
        }, deliver: { bodies.append($0.content.title + "\n" + $0.content.body) }))
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
        let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: {
            await gate.pause()
            return true
        }, deliver: { bodies.append($0.content.title + "\n" + $0.content.body) }))
        let policy = SplitAlertPolicy(bold: true)
        _ = dispatcher.accept(sample(1, percent: 50), policy: policy)
        _ = dispatcher.accept(sample(2, percent: 95, cents: 40), policy: policy)
        await gate.wait()
        dispatcher.resetContinuity()
        gate.release()
        await settle(dispatcher)
        XCTAssertEqual(bodies.count, 1)
        XCTAssertTrue(bodies.first?.contains("level is") == true)
        XCTAssertFalse(bodies.first?.contains("+$0.40") == true)
        XCTAssertFalse(bodies.first?.contains("→") == true)
    }

    func testDefaultPermissionQueryIsMemoryOnly() async {
        let state = await NotificationManager().permissionState()
        XCTAssertEqual(state, .unknown)
    }

    func testGroupedThresholdsAndBoldAreOneSubmissionAndCriticalCoversWarning() async {
        var bodies: [String] = []
        let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: { true }, deliver: { bodies.append($0.content.title + "\n" + $0.content.body) }))
        let policy = SplitAlertPolicy(bold: true)
        _ = dispatcher.accept(sample(1, percent: 50), policy: policy)
        _ = dispatcher.accept(sample(2, percent: 95, cents: 40), policy: policy)
        await settle(dispatcher)
        XCTAssertEqual(bodies, ["Other Models 95.0% · Critical\nYour critical level is 90%.\nCursor Models 95.0% · Critical\nOther Models: 50.0% → 95.0%"])
        _ = dispatcher.accept(sample(3, percent: 85, cents: 40), policy: policy)
        await settle(dispatcher)
        XCTAssertEqual(bodies.count, 1)
    }

    func testHeldAuthorizationDoesNotBlockNewRevisionAndKeepsOnlyNewestPending() async {
        let gate = Gate()
        var authorizationCount = 0
        var bodies: [String] = []
        let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: {
            authorizationCount += 1
            if authorizationCount == 1 { await gate.pause() }
            return true
        }, deliver: { bodies.append($0.content.title + "\n" + $0.content.body) }))
        _ = dispatcher.accept(sample(1, percent: 81), policy: .init())
        await gate.wait()
        _ = dispatcher.accept(sample(2, percent: 86), policy: .init())
        _ = dispatcher.accept(sample(3, percent: 95), policy: .init())
        XCTAssertEqual(dispatcher.pendingRevision, 3)
        gate.release()
        await settle(dispatcher)
        XCTAssertEqual(bodies.count, 1)
        XCTAssertTrue(bodies.last?.contains("95.0% ·") == true)
    }

    func testThresholdPolicyEditRetainsBoldWhileAwaitingAuthorization() async {
        let gate = Gate()
        var bodies: [String] = []
        let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: { await gate.pause(); return true }, deliver: { bodies.append($0.content.title + "\n" + $0.content.body) }))
        var policy = SplitAlertPolicy(bold: true)
        _ = dispatcher.accept(sample(1, percent: 50), policy: policy)
        _ = dispatcher.accept(sample(2, percent: 95, cents: 40), policy: policy)
        await gate.wait()
        policy.thresholdsEnabled = false
        dispatcher.updatePolicy(policy)
        gate.release()
        await settle(dispatcher)
        XCTAssertEqual(bodies.count, 1)
        XCTAssertFalse(bodies[0].contains("level is"))
        XCTAssertTrue(bodies[0].contains("+$0.40"))
    }

    func testBoldEditRetainsThresholdWhileAwaitingAuthorization() async {
        let gate = Gate()
        var bodies: [String] = []
        let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: { await gate.pause(); return true }, deliver: { bodies.append($0.content.title + "\n" + $0.content.body) }))
        var policy = SplitAlertPolicy(bold: true)
        _ = dispatcher.accept(sample(1, percent: 50), policy: policy)
        _ = dispatcher.accept(sample(2, percent: 95, cents: 40), policy: policy)
        await gate.wait()
        policy.bold = false
        dispatcher.updatePolicy(policy)
        gate.release()
        await settle(dispatcher)
        XCTAssertEqual(bodies.count, 1)
        XCTAssertTrue(bodies[0].contains("level is"))
        XCTAssertFalse(bodies[0].contains("+$0.40"))
        XCTAssertFalse(bodies[0].contains("→"))
    }

    func testFailedDeliveryAndDeniedAuthorizationRetryOnNextFreshRevision() async {
        enum Failure: Error { case rejected }
        var attempts = 0
        let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: { true }, deliver: { _ in
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
        let denied = await makeDispatcher(manager: NotificationManager(requestAuthorization: { permission.allowed }, deliver: { _ in sent += 1 }))
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
        let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: { await gate.pause(); return true }, deliver: { _ in sent += 1 }))
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
        let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: { true }, deliver: { _ in await gate.pause() }), store: store)
        _ = dispatcher.accept(observation, policy: .init())
        await gate.wait()
        dispatcher.logout(accountDigest: "a")
        gate.release()
        await settle(dispatcher)
        let authority = await store.prepareProfileAuthority(freshSubjectDigest: nil, revision: 100)
        let lease = await store.activate(for: observation.ownership, revision: 100, authority: authority!)
        let state = await store.load(for: observation.ownership, lease: lease!, now: Date())
        XCTAssertTrue(state.identities.isEmpty)
    }

    func testStaleBoldExpiresWhileFreshThresholdRemainsEligible() async {
        let gate = Gate()
        var time = Date()
        var bodies: [String] = []
        let dispatcher = await makeDispatcher(manager: NotificationManager(requestAuthorization: { await gate.pause(); return true }, deliver: { bodies.append($0.content.title + "\n" + $0.content.body) }), now: { time })
        let policy = SplitAlertPolicy(bold: true)
        _ = dispatcher.accept(sample(1, percent: 50, time: time), policy: policy)
        _ = dispatcher.accept(sample(2, percent: 95, cents: 40, time: time), policy: policy)
        await gate.wait()
        time = time.addingTimeInterval(121)
        gate.release()
        await settle(dispatcher)
        XCTAssertEqual(bodies.count, 1)
        XCTAssertFalse(bodies[0].contains("+$0.40"))
        XCTAssertFalse(bodies[0].contains("→"))
        XCTAssertTrue(bodies[0].contains("level is"))
    }
}
