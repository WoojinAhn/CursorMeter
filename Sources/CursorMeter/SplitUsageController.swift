import Foundation
import Observation

@MainActor @Observable
final class SplitUsageController {
    typealias Supplement = @Sendable (SplitUsageSnapshot) async -> Void
    typealias Collect = @Sendable (SplitUsageSnapshot, UsageSummaryResponse, String, Int, @escaping Supplement) async -> CycleCollectionResult
    typealias FetchPeriod = @Sendable (String) async throws -> CurrentPeriodUsageResponse

    private(set) var eligibility: SplitUsageEligibility = .legacy
    private(set) var snapshot: SplitUsageSnapshot?
    private(set) var primarySnapshot: SplitUsageSnapshot?
    private(set) var amounts: CycleAmountSnapshot?
    private(set) var isStale = false
    private(set) var isFetchingSupplement = false
    private(set) var amountState: SplitAmountPresentationState = .pending
    private(set) var persistentSubjectDigest: String?
    private(set) var schedule = CycleCollectionSchedule()
    var suppressesLegacyMeter: Bool { eligibility != .legacy }

    @ObservationIgnored private let collect: Collect?
    @ObservationIgnored private let fetchPeriod: FetchPeriod?
    @ObservationIgnored private let store: CycleUsageStore?
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var supplementTask: Task<Void, Never>?
    @ObservationIgnored private var supplementRevision: UInt64 = 0
    @ObservationIgnored private var supplementNextAt: Date?
    @ObservationIgnored private var supplementFailures = 0
    @ObservationIgnored private var supplementMemo: (snapshot: SplitUsageSnapshot, fingerprint: String)?
    @ObservationIgnored private var primaryFingerprint: String?
    @ObservationIgnored private var planScopeIdentity: String?
    @ObservationIgnored private var periodCursorPlaces = 0
    @ObservationIgnored private var periodOtherPlaces = 0
    @ObservationIgnored private var taskRevision: UInt64 = 0
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var sessionIdentity = UUID().uuidString
    @ObservationIgnored private var latestRequest: (UsageSummaryResponse, String)?
    @ObservationIgnored private var membership: String?
    @ObservationIgnored private var planLimit: Int?
    @ObservationIgnored private var cycle: UsageCycle?

    init(apiClient: CursorAPIClient? = nil, store: CycleUsageStore? = nil,
         now: @escaping () -> Date = { Date() }, collect: Collect? = nil, fetchPeriod: FetchPeriod? = nil) {
        self.store = store
        self.now = now
        if let fetchPeriod { self.fetchPeriod = fetchPeriod }
        else if let apiClient { self.fetchPeriod = { cookie in try await apiClient.fetchCurrentPeriodUsage(cookieHeader: cookie) } }
        else { self.fetchPeriod = nil }
        if let collect { self.collect = collect }
        else if let apiClient {
            self.collect = { snapshot, summary, cookie, allowance, supplement in
                let collector = CycleUsageCollector(budget: .init(maxPages: allowance), fetchPage: { page, bytes in
                    try await apiClient.fetchCycleUsagePage(cookieHeader: cookie, teamId: 0, userId: nil, page: page, maximumBytes: bytes)
                }, fetchSummary: { try await apiClient.fetchUsageSummary(cookieHeader: cookie) }, fetchPeriod: {
                    try await apiClient.fetchCurrentPeriodUsage(cookieHeader: cookie)
                }, onSupplement: supplement)
                return await collector.collect(snapshot: snapshot, summary: summary)
            }
        } else { self.collect = nil }
    }

    func accept(summary: UsageSummaryResponse, usage: UsageResponse?, userInfo: UserInfoResponse,
                generation: UInt64, enterpriseScope: Bool) {
        let newMembership = (summary.membershipType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            .flatMap { $0.isEmpty ? nil : $0 }
        let newLimit = summary.individualUsage?.plan?.limit
        let newCycle = UsageCycle(start: summary.billingCycleStart, end: summary.billingCycleEnd)
        let verifiedAccount = UsageRevisionIdentity.accountDigest(subject: userInfo.sub, email: userInfo.email)
        let candidateAccount = verifiedAccount ?? UsageRevisionIdentity.digest("session:\(sessionIdentity):\(generation)")
        let contradicted = enterpriseScope || summary.limitType?.lowercased() == "team"
            || summary.teamUsage?.hasUsageData == true
            || ["enterprise", "business", "team", "teams", "free"].contains(newMembership ?? "")
            || (summary.individualUsage?.plan == nil && summary.individualUsage?.overall != nil)
            || usage?.models.values.contains(where: { $0.maxRequestUsage != nil }) == true
        let transition = primarySnapshot.map { previous in
            previous.identity.accountDigest != candidateAccount
                || (newCycle != nil && newCycle != cycle)
                || (newMembership != nil && membership != nil && newMembership != membership)
                || (newLimit != nil && planLimit != nil && newLimit != planLimit)
        } ?? false
        if transition || contradicted { reset(removePersisted: false) }
        membership = newMembership ?? membership
        planLimit = newLimit ?? planLimit
        cycle = newCycle ?? cycle
        persistentSubjectDigest = UsageRevisionIdentity.accountDigest(subject: userInfo.sub, email: nil)
        guard !contradicted else {
            eligibility = .legacy
            snapshot = nil; primarySnapshot = nil
            return
        }
        if eligibility != .eligible {
            eligibility = SplitUsageEligibility.evaluate(summary: summary, usage: usage, enterpriseScope: enterpriseScope)
        }
        guard suppressesLegacyMeter else { snapshot = nil; primarySnapshot = nil; return }
        revision &+= 1
        let account = verifiedAccount ?? UsageRevisionIdentity.digest("session:\(sessionIdentity):\(generation)")
        if planScopeIdentity == nil { planScopeIdentity = "\(membership ?? "unknown"):\(planLimit.map(String.init) ?? "unknown")" }
        let identity = UsageRevisionIdentity(localID: revision, credentialGeneration: generation, accountDigest: account,
            scopeDigest: UsageRevisionIdentity.digest("personal:team:0:user:none"), cycle: cycle,
            planIdentity: planScopeIdentity!)
        let cursor = eligibility == .eligible ? summary.individualUsage?.plan?.autoPercentUsed : nil
        let other = eligibility == .eligible ? summary.individualUsage?.plan?.apiPercentUsed : nil
        let used = summary.individualUsage?.plan?.used.flatMap { $0 >= 0 ? Decimal($0) : nil }
        let old = primarySnapshot
        if let old, old.identity.credentialGeneration != generation || !old.identity.sameScope(as: identity) {
            retireTask()
            supplementMemo = nil
        }
        let fingerprint = Self.fingerprint(summary: summary)
        primarySnapshot = SplitUsageSnapshot(identity: identity, capturedAt: now(), cursorPercent: cursor, otherPercent: other,
            includedUsedCents: used,
            cursorObservedPlaces: max(old?.cursorObservedPlaces ?? 0, SplitUsageSnapshot.fractionalPlaces(cursor)),
            otherObservedPlaces: max(old?.otherObservedPlaces ?? 0, SplitUsageSnapshot.fractionalPlaces(other)),
            periodCursorObservedPlaces: periodCursorPlaces, periodOtherObservedPlaces: periodOtherPlaces)
        primaryFingerprint = fingerprint
        snapshot = primarySnapshot
        if let memo = supplementMemo, memo.fingerprint == fingerprint,
           memo.snapshot.identity.sameScope(as: identity), memo.snapshot.identity.credentialGeneration == generation,
           let capturedAt = memo.snapshot.periodCapturedAt, (0...600).contains(now().timeIntervalSince(capturedAt)) {
            snapshot = applying(memo.snapshot, to: primarySnapshot!)
        } else { supplementMemo = nil }
        isStale = false
        schedule.observe(fingerprint: fingerprint)
    }

    func requestAmounts(summary: UsageSummaryResponse, cookieHeader: String, manual: Bool = false) {
        latestRequest = (summary, cookieHeader)
        requestAmounts(manual: manual)
    }

    func requestAmounts(manual: Bool = true) {
        guard eligibility == .eligible, !isStale, let snapshot = primarySnapshot, snapshot.identity.cycle != nil,
              let (summary, cookie) = latestRequest, supplementTask == nil else { return }
        guard let collect, let allowance = schedule.begin(at: now(), manual: manual),
              let attemptID = schedule.currentAttemptID else {
            requestSupplement(snapshot: snapshot, summary: summary, cookie: cookie)
            return
        }
        taskRevision &+= 1
        let taskID = taskRevision
        let subject = persistentSubjectDigest
        amountState = .refreshing
        task = Task { [weak self, store] in
            guard let self else { return }
            defer { self.schedule.finish(.cancelled, pages: 0, at: self.now(), attemptID: attemptID) }
            guard self.owns(taskID, snapshot: snapshot) else { return }
            let operation = await store?.activate(identity: snapshot.identity, subjectDigest: subject)
            guard self.owns(taskID, snapshot: snapshot) else { return }
            if self.amounts == nil, let operation, let cached = await store?.load(operation: operation, now: self.now()),
               self.owns(taskID, snapshot: snapshot) {
                self.amounts = cached
            }
            guard self.owns(taskID, snapshot: snapshot) else { return }
            let fingerprint = Self.fingerprint(summary: summary)
            let result = await collect(snapshot, summary, cookie, allowance) { [weak self] supplemental in
                await self?.acceptSupplement(supplemental, fingerprint: fingerprint, taskID: taskID)
            }
            self.schedule.finish(Self.outcome(result.status), pages: result.pageCount, at: self.now(), attemptID: attemptID)
            guard self.owns(taskID, snapshot: snapshot) else { return }
            if let supplemental = result.supplementarySnapshot {
                self.acceptSupplement(supplemental, fingerprint: fingerprint, taskID: taskID)
            }
            if let amounts = result.snapshot, amounts.identity.sameScope(as: snapshot.identity),
               amounts.coverage.complete || self.amounts?.coverage.complete != true {
                self.amounts = amounts
                if let operation, subject != nil { try? await store?.save(amounts, operation: operation) }
                guard self.owns(taskID, snapshot: snapshot) else { return }
            }
            switch result.status {
            case .complete: self.amountState = .ready
            case .partial, .unstable: self.amountState = self.amounts == nil ? .unavailable : .ready
            case .cancelled: self.amountState = .pending
            default: self.amountState = .failed
            }
            self.task = nil
        }
    }

    private func owns(_ taskID: UInt64, snapshot captured: SplitUsageSnapshot) -> Bool {
        !Task.isCancelled && taskID == taskRevision && eligibility == .eligible
            && snapshot?.identity.sameScope(as: captured.identity) == true
            && snapshot?.identity.credentialGeneration == captured.identity.credentialGeneration
    }

    private func applying(_ supplement: SplitUsageSnapshot, to primary: SplitUsageSnapshot) -> SplitUsageSnapshot {
        var visible = primary
        if primary.cursorPercent == nil, supplement.cursorSource == .period {
            visible.cursorPercent = supplement.cursorPercent
            visible.cursorSource = .period
            visible.cursorObservedPlaces = supplement.periodCursorObservedPlaces
        }
        if primary.otherPercent == nil, supplement.otherSource == .period {
            visible.otherPercent = supplement.otherPercent
            visible.otherSource = .period
            visible.otherObservedPlaces = supplement.periodOtherObservedPlaces
        }
        visible.periodCapturedAt = supplement.periodCapturedAt
        visible.periodCursorObservedPlaces = supplement.periodCursorObservedPlaces
        visible.periodOtherObservedPlaces = supplement.periodOtherObservedPlaces
        return visible
    }

    private func acceptSupplement(_ supplemental: SplitUsageSnapshot, fingerprint: String, taskID: UInt64? = nil) {
        guard !Task.isCancelled, eligibility == .eligible, !isStale,
              taskID.map({ $0 == taskRevision }) ?? true,
              let primarySnapshot, supplemental.identity == primarySnapshot.identity,
              fingerprint == primaryFingerprint, let capturedAt = supplemental.periodCapturedAt,
              (0...600).contains(now().timeIntervalSince(capturedAt)) else { return }
        periodCursorPlaces = max(periodCursorPlaces, supplemental.periodCursorObservedPlaces)
        periodOtherPlaces = max(periodOtherPlaces, supplemental.periodOtherObservedPlaces)
        supplementMemo = (supplemental, fingerprint)
        snapshot = applying(supplemental, to: primarySnapshot)
    }

    private func requestSupplement(snapshot: SplitUsageSnapshot, summary: UsageSummaryResponse, cookie: String) {
        guard snapshot.cursorPercent == nil || snapshot.otherPercent == nil,
              let fetchPeriod, supplementTask == nil, schedule.canFetchSupplement(at: now()),
              supplementNextAt.map({ now() >= $0 }) ?? true else { return }
        supplementRevision &+= 1
        let supplementID = supplementRevision
        let fingerprint = Self.fingerprint(summary: summary)
        supplementNextAt = now().addingTimeInterval(60)
        isFetchingSupplement = true
        supplementTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if supplementID == self.supplementRevision {
                    self.supplementTask = nil
                    self.isFetchingSupplement = false
                }
            }
            do {
                let period = try await fetchPeriod(cookie)
                guard !Task.isCancelled, supplementID == self.supplementRevision else { return }
                self.supplementFailures = 0
                self.acceptSupplement(snapshot.supplemented(by: period, summary: summary, at: self.now()), fingerprint: fingerprint)
            } catch {
                if case let CycleEnrichmentError.http(status: 429, retryAfter: retryAfter) = error {
                    self.schedule.recordSupplementRateLimit(retryAfter ?? 1800, at: self.now())
                }
                guard !Task.isCancelled, supplementID == self.supplementRevision,
                      !(error is CancellationError), (error as? URLError)?.code != .cancelled else { return }
                let transport: Bool
                switch error {
                case CycleEnrichmentError.transport: transport = true
                case let CycleEnrichmentError.http(status, _): transport = status >= 500
                case is URLError: transport = true
                default: transport = false
                }
                if transport {
                    self.supplementFailures = min(6, self.supplementFailures + 1)
                    self.supplementNextAt = self.now().addingTimeInterval(min(1800, 60 * pow(2, Double(self.supplementFailures - 1))))
                } else if case CycleEnrichmentError.http(status: 429, retryAfter: _) = error {
                    self.supplementNextAt = self.now().addingTimeInterval(60)
                } else {
                    self.supplementFailures = 0
                    self.supplementNextAt = self.now().addingTimeInterval(1800)
                }
            }
        }
    }

    var canRefreshAmounts: Bool {
        eligibility == .eligible && !isStale && !isFetchingSupplement && snapshot?.identity.cycle != nil
            && schedule.availability(at: now(), manual: true) == .ready
    }

    var amountsRefreshStateText: String {
        guard eligibility == .eligible else { return "Amounts unavailable until split usage is verified" }
        guard !isStale else { return "Waiting for a successful usage refresh" }
        guard snapshot?.identity.cycle != nil else { return "Billing cycle unavailable" }
        if isFetchingSupplement { return "Refreshing percentages…" }
        switch schedule.availability(at: now(), manual: true) {
        case .ready: return "Refresh amounts"
        case .collecting: return "Refreshing amounts…"
        case let .waiting(until): return "Available in \(max(1, Int(ceil(until.timeIntervalSince(now())))))s"
        case .cycleLimit: return "Collection limit reached"
        case .unchanged: return "Amounts unchanged"
        }
    }

    func recordFailure() { if suppressesLegacyMeter { isStale = true } }

    func suspend(removePersisted: Bool = false, subjectDigest: String? = nil) {
        retireTask()
        latestRequest = nil
        recordFailure()
        let subject = subjectDigest ?? persistentSubjectDigest
        if let store { Task { try? await store.invalidate(removePersisted: removePersisted, subjectDigest: subject) } }
    }

    func reset(removePersisted: Bool = false, subjectDigest: String? = nil) {
        suspend(removePersisted: removePersisted, subjectDigest: subjectDigest)
        eligibility = .legacy; snapshot = nil; primarySnapshot = nil; amounts = nil; isStale = false
        amountState = .pending; persistentSubjectDigest = nil
        membership = nil; planLimit = nil; cycle = nil
        planScopeIdentity = nil; primaryFingerprint = nil; supplementMemo = nil
        periodCursorPlaces = 0; periodOtherPlaces = 0
        supplementNextAt = nil; supplementFailures = 0
        sessionIdentity = UUID().uuidString
        schedule.resetCycle()
    }

    private func retireTask() {
        taskRevision &+= 1
        task?.cancel()
        task = nil
        supplementRevision &+= 1
        supplementTask?.cancel()
        supplementTask = nil
        isFetchingSupplement = false
        schedule.retireCurrent(at: now())
        if amountState == .refreshing { amountState = .pending }
    }

    static func fingerprint(summary: UsageSummaryResponse) -> String {
        CycleUsageCollector.summaryFingerprint(summary)
    }

    private static func outcome(_ status: CycleCollectionStatus) -> CycleCollectionSchedule.Outcome {
        switch status {
        case .complete: .complete
        case .partial: .budgetPartial
        case .unstable: .unstable
        case .transportFailure: .transportFailure
        case .endpointFailure: .endpointFailure
        case .cancelled: .cancelled
        case let .rateLimited(retryAfter): .rateLimited(retryAfter: retryAfter)
        }
    }
}
