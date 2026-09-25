import Foundation

/// Evaluates synchronously at primary publication; authorization, delivery and disk
/// I/O run in one worker with only the newest pending revision retained.
@MainActor
final class SplitUsageAlertDispatcher {
    private struct Queued {
        var batch: SplitUsageEventBatch
        var ownershipRevision: UInt64
        var thresholdRevision: UInt64
        var boldRevision: UInt64
        var continuityCeiling: TimeInterval
    }
    private struct Components {
        var thresholds: [SplitThresholdEvent]
        var bold: SplitUsageJump?
        var isEmpty: Bool { thresholds.isEmpty && bold == nil }
        var body: String {
            (thresholds.map(\.body) + (bold.map { [$0.body] } ?? [])).joined(separator: "\n")
        }
        var title: String {
            thresholds.isEmpty ? bold?.title ?? "Usage Update" : bold == nil ? "사용량 알림" : "사용량 알림 및 급증"
        }
    }
    private let manager: NotificationManager
    private let store: SplitUsageAlertStore
    private let now: @MainActor () -> Date
    private var engine = SplitUsageAlertEngine()
    private var policy = SplitAlertPolicy()
    private var ownership: SplitAlertOwnership?
    private var latestRevision: UInt64?
    private var latestThresholds: [String: SplitThresholdEvent] = [:]
    private var knownSubjects: [String: String] = [:]
    private var ownershipRevision: UInt64 = 0
    private var thresholdRevision: UInt64 = 0
    private var boldRevision: UInt64 = 0
    private var pending: Queued?
    private var worker: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    var pendingRevision: UInt64? { pending?.batch.revision }

    init(manager: NotificationManager, store: SplitUsageAlertStore = SplitUsageAlertStore(), now: @escaping @MainActor () -> Date = { Date() }) {
        self.manager = manager
        self.store = store
        self.now = now
    }

    @discardableResult
    func accept(_ observation: SplitUsageObservation, policy: SplitAlertPolicy) -> SplitUsageJump? {
        updatePolicy(policy)
        if ownership != observation.ownership {
            ownershipRevision &+= 1
            pending = nil
            ownership = observation.ownership
            latestRevision = nil
        }
        if let subject = observation.ownership.persistentSubjectDigest {
            knownSubjects[observation.ownership.accountDigest] = subject
        }
        guard latestRevision.map({ observation.revision > $0 }) ?? true else { return nil }
        latestRevision = observation.revision
        let previousPending = pending
        pending = nil
        var batch = engine.accept(observation, policy: policy)
        latestThresholds = Dictionary(uniqueKeysWithValues: batch.thresholds.map { ($0.identity, $0) })
        var continuityCeiling = policy.continuityCeiling
        if batch.boldJump == nil, let previousPending,
           let retained = components(previousPending, delivered: []).bold {
            batch.boldJump = retained
            batch.timestamp = previousPending.batch.timestamp
            continuityCeiling = previousPending.continuityCeiling
        }
        if !batch.thresholds.isEmpty || batch.boldJump != nil {
            pending = Queued(batch: batch, ownershipRevision: ownershipRevision,
                             thresholdRevision: thresholdRevision, boldRevision: boldRevision,
                             continuityCeiling: continuityCeiling)
            if worker == nil { worker = Task { await drain() } }
        }
        return batch.jump
    }

    func updatePolicy(_ policy: SplitAlertPolicy) {
        if !self.policy.hasSameThresholds(as: policy) { thresholdRevision &+= 1 }
        if !self.policy.hasSameBold(as: policy) { boldRevision &+= 1 }
        self.policy = policy
    }

    func invalidateOwnership() {
        ownershipRevision &+= 1
        ownership = nil
        latestRevision = nil
        latestThresholds = [:]
        pending = nil
        engine.reset()
    }

    func resetContinuity() {
        boldRevision &+= 1
        engine.resetContinuity()
    }

    func logout(accountDigest: String, persistentSubjectDigest: String? = nil) {
        invalidateOwnership()
        let previous = cleanup
        let knownSubject = knownSubjects.removeValue(forKey: accountDigest)
        let subject = persistentSubjectDigest ?? knownSubject
        cleanup = Task {
            await previous?.value
            await store.logout(accountDigest: accountDigest, persistentSubjectDigest: subject)
        }
    }

    func waitUntilIdle() async {
        await worker?.value
        await cleanup?.value
    }

    private func isCurrent(_ queued: Queued) -> Bool {
        queued.ownershipRevision == ownershipRevision && queued.batch.ownership == ownership && !Task.isCancelled
    }

    private func components(_ queued: Queued, delivered: Set<String>) -> Components {
        guard isCurrent(queued) else { return Components(thresholds: [], bold: nil) }
        // The same owner and policy can publish a correction or change the paid
        // budget while authorization is open. Only currently eligible identities
        // survive, with the newest value in their notification text.
        let thresholds = queued.thresholdRevision == thresholdRevision
            ? queued.batch.thresholds.compactMap { delivered.contains($0.identity) ? nil : latestThresholds[$0.identity] } : []
        let age = now().timeIntervalSince(queued.batch.timestamp)
        let bold = queued.boldRevision == boldRevision && age >= 0 && age <= queued.continuityCeiling
            ? queued.batch.boldJump : nil
        return Components(thresholds: thresholds, bold: bold)
    }

    private func drain() async {
        while let queued = pending {
            pending = nil
            await cleanup?.value
            guard isCurrent(queued) else { continue }
            let state = await store.load(for: queued.batch.ownership, now: now())
            guard !components(queued, delivered: state.identities).isEmpty else { continue }
            let authorized = await manager.authorizeUsageNotifications()
            guard authorized else { continue }
            let submitting = components(queued, delivered: state.identities)
            guard !submitting.isEmpty else { continue }
            let delivered = await manager.submitUsageNotification(title: submitting.title, body: submitting.body,
                identifier: "usage-split-\(UUID().uuidString)")
            guard delivered, isCurrent(queued) else { continue }
            // Successful submission cannot be retracted by a later policy edit
            // or value correction. Record exactly what was delivered; identities
            // include the original threshold value and budget. Ownership and the
            // store lease still prevent logout or account-switch resurrection.
            let identities = submitting.thresholds.reduce(into: Set<String>()) { $0.formUnion($1.coveredIdentities) }
            if !identities.isEmpty {
                await store.recordSuccessful(identities, ownership: queued.batch.ownership, lease: state.lease, now: now())
            }
        }
        worker = nil
    }
}
