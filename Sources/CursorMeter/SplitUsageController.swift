import Foundation
import Observation

@MainActor @Observable
final class SplitUsageController {
    typealias Supplement = @Sendable (SplitUsageSnapshot) async -> Void
    typealias Collect = @Sendable (SplitUsageSnapshot, UsageSummaryResponse, String, Int, @escaping Supplement) async -> CycleCollectionResult
    typealias CollectToday = @Sendable (SplitUsageSnapshot, UsageSummaryResponse, String, Int, TodayUsageCollectionContext?, @escaping Supplement) async -> CycleCollectionResult
    typealias WaitUntil = @Sendable (Date) async throws -> Void
    typealias FetchPeriod = @Sendable (String) async throws -> CurrentPeriodUsageResponse

    private(set) var eligibility: SplitUsageEligibility = .legacy
    private(set) var snapshot: SplitUsageSnapshot?
    private(set) var primarySnapshot: SplitUsageSnapshot?
    private(set) var amounts: CycleAmountSnapshot?
    private(set) var todayPercentagePoints: [UsagePoolID: Double]?
    private(set) var amountsAreEarlier = false
    private(set) var historyEpoch: UInt64 = 0
    private(set) var isStale = false
    private(set) var isFetchingSupplement = false
    private(set) var amountState: SplitAmountPresentationState = .pending
    private(set) var persistentSubjectDigest: String?
    private(set) var schedule = CycleCollectionSchedule()
    var suppressesLegacyMeter: Bool { eligibility != .legacy }

    @ObservationIgnored private let collect: CollectToday?
    @ObservationIgnored private let waitUntil: WaitUntil
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
    @ObservationIgnored private var lifecycleRevision: UInt64 = 0
    @ObservationIgnored private var preparationRevision: UInt64 = 0
    @ObservationIgnored private var authorityEpoch: UInt64 = 0
    @ObservationIgnored private var authoritySubjectDigest: String?
    @ObservationIgnored private var authorityFence: Task<Bool, Never>?
    @ObservationIgnored private var preparedForAcceptance = false
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var sessionIdentity = UUID().uuidString
    @ObservationIgnored private var latestRequest: (UsageSummaryResponse, String)?
    @ObservationIgnored private var membership: String?
    @ObservationIgnored private var planLimit: Int?
    @ObservationIgnored private var cycle: UsageCycle?
    private struct TodayRequest {
        let snapshot: SplitUsageSnapshot
        let summary: UsageSummaryResponse
        let cookie: String
        let evidence: CycleEventEvidence
        let epoch: UInt64
    }
    @ObservationIgnored private var pendingToday: TodayRequest?
    @ObservationIgnored private var activeToday: TodayRequest?
    @ObservationIgnored private var activeDemand: CycleCollectionDemand?
    @ObservationIgnored private var latestDemand: CycleCollectionDemand?
    @ObservationIgnored private var fulfilledDemand: CycleCollectionDemand?
    @ObservationIgnored private var lastHistoryRequest: TodayRequest?
    @ObservationIgnored private var amountFingerprint: String?
    @ObservationIgnored private var durableInvalidAttribution = false
    @ObservationIgnored private var admissionTask: Task<Void, Never>?
    @ObservationIgnored private var deferredWake: Task<Void, Never>?
    @ObservationIgnored private var deferredDeadline: Date?
    @ObservationIgnored private var wakeRevision: UInt64 = 0
    private var waitsForWakeRefresh = false
    private var isSleeping = false

    init(apiClient: CursorAPIClient? = nil, store: CycleUsageStore? = nil,
         now: @escaping () -> Date = { Date() }, collect: Collect? = nil, fetchPeriod: FetchPeriod? = nil,
         collectToday: CollectToday? = nil, waitUntil: WaitUntil? = nil) {
        self.store = store
        self.now = now
        self.waitUntil = waitUntil ?? { date in
            try await Task.sleep(for: .seconds(max(0, date.timeIntervalSinceNow)))
        }
        if let fetchPeriod { self.fetchPeriod = fetchPeriod }
        else if let apiClient { self.fetchPeriod = { cookie in try await apiClient.fetchCurrentPeriodUsage(cookieHeader: cookie) } }
        else { self.fetchPeriod = nil }
        if let collectToday { self.collect = collectToday }
        else if let collect { self.collect = { snapshot, summary, cookie, allowance, _, supplement in
            await collect(snapshot, summary, cookie, allowance, supplement)
        } }
        else if let apiClient {
            self.collect = { snapshot, summary, cookie, allowance, context, supplement in
                let collector = CycleUsageCollector(budget: .init(maxPages: allowance), fetchPage: { page, bytes in
                    try await apiClient.fetchCycleUsagePage(cookieHeader: cookie, teamId: 0, userId: nil, page: page, maximumBytes: bytes)
                }, fetchSummary: { try await apiClient.fetchUsageSummaryForCycleValidation(cookieHeader: cookie) }, fetchPeriod: {
                    try await apiClient.fetchCurrentPeriodUsage(cookieHeader: cookie)
                }, onSupplement: supplement)
                return await collector.collect(snapshot: snapshot, summary: summary, todayContext: context)
            }
        } else { self.collect = nil }
    }

    func reevaluateToday(at date: Date) {
        todayPercentagePoints = TodayUsageAllocation.percentagePoints(snapshot: snapshot, amounts: amounts,
            primaryIsStale: isStale,
            currentSessionAndDemandEligible: fulfilledDemand != nil && fulfilledDemand == latestDemand, now: date)
    }

    func requestAmounts(summary: UsageSummaryResponse, cookieHeader: String, primaryIdentity: UsageRevisionIdentity,
                        eventEvidence: CycleEventEvidence, historyEpoch: UInt64) {
        guard !isSleeping, historyEpoch == self.historyEpoch, eligibility == .eligible, !isStale,
              let primarySnapshot, primarySnapshot.identity == primaryIdentity,
              Self.fingerprint(summary: summary) == primaryFingerprint,
              let day = TodayUsageDay(containing: now()) else { return }
        waitsForWakeRefresh = false
        latestRequest = (summary, cookieHeader)
        let request = TodayRequest(snapshot: primarySnapshot, summary: summary, cookie: cookieHeader,
                                   evidence: eventEvidence, epoch: historyEpoch)
        let demand = CycleCollectionDemand(summaryFingerprint: Self.fingerprint(summary: summary), day: day,
                                           eventEvidence: eventEvidence)
        latestDemand = demand
        reevaluateToday(at: now())
        if lastHistoryRequest?.snapshot.identity == primaryIdentity,
           lastHistoryRequest?.evidence == eventEvidence { return }
        lastHistoryRequest = request
        if activeDemand == demand { pendingToday = nil; return }
        pendingToday = request
        drainToday()
    }

    private var usesFastTodayCadence: Bool {
        guard !durableInvalidAttribution,
              let cursor = SplitUsageSnapshot.validPercent(snapshot?.cursorPercent), cursor < 100,
              let other = SplitUsageSnapshot.validPercent(snapshot?.otherPercent), other < 100 else { return false }
        return true
    }

    private func isCurrent(_ request: TodayRequest) -> Bool {
        !isSleeping && !waitsForWakeRefresh && request.epoch == historyEpoch && eligibility == .eligible && !isStale
            && request.snapshot.identity.cycle != nil && primarySnapshot?.identity == request.snapshot.identity
    }

    private func drainToday() {
        guard task == nil, admissionTask == nil, supplementTask == nil, let request = pendingToday,
              isCurrent(request), let day = TodayUsageDay(containing: now()) else { return }
        let preview = CycleCollectionDemand(summaryFingerprint: Self.fingerprint(summary: request.summary), day: day,
                                             eventEvidence: request.evidence)
        let availability = schedule.availability(at: now(), manual: false,
                                                todayDemand: usesFastTodayCadence ? preview.key : nil)
        guard availability == .ready, collect != nil else {
            if case let .waiting(until) = availability { deferToday(until: until) }
            requestSupplement(snapshot: request.snapshot, summary: request.summary, cookie: request.cookie)
            return
        }
        cancelDeferredWake()
        let owner = taskRevision
        let authority = authorityEpoch
        let fence = authorityFence
        admissionTask = Task { [weak self, store] in
            guard let self else { return }
            let acknowledged = await fence?.value ?? true
            guard acknowledged, !Task.isCancelled, self.taskRevision == owner, self.authorityEpoch == authority else { return }
            let operation = await store?.activate(identity: request.snapshot.identity, authority: authority)
            guard !Task.isCancelled, self.taskRevision == owner, self.authorityEpoch == authority else { return }
            self.admissionTask = nil
            guard let current = self.pendingToday, self.isCurrent(current) else { return }
            guard current.snapshot.identity == request.snapshot.identity, current.evidence == request.evidence else {
                self.drainToday()
                return
            }
            // All authority awaits precede this single day capture and admission.
            guard let context = TodayUsageCollectionContext(admittedAt: self.now()) else { return }
            let demand = CycleCollectionDemand(summaryFingerprint: Self.fingerprint(summary: current.summary),
                                               day: context.day, eventEvidence: current.evidence)
            self.latestDemand = demand
            self.reevaluateToday(at: context.admittedAt)
            guard let allowance = self.schedule.begin(at: context.admittedAt, manual: false,
                    todayDemand: self.usesFastTodayCadence ? demand.key : nil),
                  let attemptID = self.schedule.currentAttemptID else { self.drainToday(); return }
            self.pendingToday = nil
            self.activeToday = current
            self.activeDemand = demand
            self.launchCollection(snapshot: current.snapshot, summary: current.summary, cookie: current.cookie,
                allowance: allowance, attemptID: attemptID, context: context, demand: demand, operation: operation)
        }
    }

    private func deferToday(until deadline: Date) {
        guard deferredDeadline != deadline else { return }
        cancelDeferredWake()
        deferredDeadline = deadline
        let token = wakeRevision
        deferredWake = Task { [weak self, waitUntil] in
            do { try await waitUntil(deadline) } catch { return }
            guard let self, !Task.isCancelled, token == self.wakeRevision else { return }
            self.deferredWake = nil
            self.deferredDeadline = nil
            self.drainToday()
        }
    }

    private func cancelDeferredWake() {
        wakeRevision &+= 1
        deferredWake?.cancel()
        deferredWake = nil
        deferredDeadline = nil
    }

    func prepareProfileAuthority(freshSubjectDigest: String?) async -> Bool {
        guard !Task.isCancelled else { return false }
        preparationRevision &+= 1
        let preparation = preparationRevision
        let lifecycle = lifecycleRevision
        preparedForAcceptance = false
        if freshSubjectDigest != authoritySubjectDigest {
            retireTask()
            if amounts != nil { amountState = .ready }
            persistentSubjectDigest = nil
            enqueueAuthorityFence(subjectDigest: freshSubjectDigest)
        }
        let epoch = authorityEpoch
        let acknowledged = await authorityFence?.value ?? true
        guard acknowledged, !Task.isCancelled, lifecycle == lifecycleRevision,
              preparation == preparationRevision, epoch == authorityEpoch else {
            if Task.isCancelled, lifecycle == lifecycleRevision,
               preparation == preparationRevision, epoch == authorityEpoch {
                persistentSubjectDigest = nil
                enqueueAuthorityFence(subjectDigest: nil)
            }
            return false
        }
        persistentSubjectDigest = freshSubjectDigest
        preparedForAcceptance = true
        return true
    }

    @discardableResult
    func accept(summary: UsageSummaryResponse, usage: UsageResponse?, userInfo: UserInfoResponse,
                generation: UInt64, enterpriseScope: Bool, allowsSplitPresentation: Bool = true) -> UsageRevisionIdentity? {
        let hasPreparedAuthority = preparedForAcceptance
        preparedForAcceptance = false
        let newMembership = (summary.membershipType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            .flatMap { $0.isEmpty ? nil : $0 }
        let newLimit = summary.individualUsage?.plan?.limit
        let newCycle = UsageCycle(start: summary.billingCycleStart, end: summary.billingCycleEnd)
        let memoryAccount = UsageRevisionIdentity.accountDigest(subject: userInfo.sub, email: userInfo.email)
        let candidateAccount = memoryAccount ?? UsageRevisionIdentity.digest("session:\(sessionIdentity):\(generation)")
        let scopeContradicted = enterpriseScope || summary.limitType?.lowercased() == "team"
            || summary.teamUsage?.hasUsageData == true
            || ["enterprise", "business", "team", "teams", "free"].contains(newMembership ?? "")
            || (summary.individualUsage?.plan == nil && summary.individualUsage?.overall != nil)
            || usage?.models.values.contains(where: { $0.maxRequestUsage != nil }) == true
        let contradicted = !allowsSplitPresentation || scopeContradicted
        let transition = primarySnapshot.map { previous in
            previous.identity.accountDigest != candidateAccount
                || (newCycle != nil && newCycle != cycle)
                || (newMembership != nil && membership != nil && newMembership != membership)
                || (newLimit != nil && planLimit != nil && newLimit != planLimit)
        } ?? false
        if transition || contradicted {
            if hasPreparedAuthority {
                retireTask()
                latestRequest = nil
                resetMemory()
                // Scope retirement must keep only this batch's explicitly prepared authority.
                enqueueAuthorityFence(subjectDigest: persistentSubjectDigest)
            } else { reset(removePersisted: false) }
        }
        membership = newMembership ?? membership
        planLimit = newLimit ?? planLimit
        cycle = newCycle ?? cycle
        // A display fallback can retire split data without retiring a submitted
        // alert's owner. Return its scope for receipt validation even while legacy.
        let account = memoryAccount ?? UsageRevisionIdentity.digest("session:\(sessionIdentity):\(generation)")
        let identity = UsageRevisionIdentity(localID: revision &+ 1, credentialGeneration: generation, accountDigest: account,
            scopeDigest: UsageRevisionIdentity.digest("personal:team:0:user:none"), cycle: cycle,
            planIdentity: planScopeIdentity ?? "\(membership ?? "unknown"):\(planLimit.map(String.init) ?? "unknown")")
        guard !contradicted else {
            eligibility = .legacy
            snapshot = nil; primarySnapshot = nil
            return scopeContradicted ? nil : identity
        }
        if eligibility != .eligible {
            eligibility = SplitUsageEligibility.evaluate(summary: summary, usage: usage, enterpriseScope: enterpriseScope)
        }
        guard suppressesLegacyMeter else { snapshot = nil; primarySnapshot = nil; return nil }
        revision &+= 1
        planScopeIdentity = identity.planIdentity
        let cursor = eligibility == .eligible ? summary.individualUsage?.plan?.autoPercentUsed : nil
        let other = eligibility == .eligible ? summary.individualUsage?.plan?.apiPercentUsed : nil
        let used = summary.individualUsage?.plan?.used.flatMap { $0 >= 0 ? Decimal($0) : nil }
        let old = primarySnapshot
        if let old, old.identity.credentialGeneration != generation || !old.identity.sameScope(as: identity) {
            retireTask()
            clearToday()
            schedule.resetCycle()
            amounts = nil
            amountState = .pending
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
        reevaluateToday(at: now())
        return identity
    }

    func requestAmounts(summary: UsageSummaryResponse, cookieHeader: String, manual: Bool = false) {
        latestRequest = (summary, cookieHeader)
        requestAmounts(manual: manual)
    }

    func requestAmounts(manual: Bool = true) {
        if let authorityFence {
            let lifecycle = lifecycleRevision
            let epoch = authorityEpoch
            Task { [weak self] in
                let acknowledged = await authorityFence.value
                guard let self, acknowledged, !Task.isCancelled,
                      self.lifecycleRevision == lifecycle, self.authorityEpoch == epoch else { return }
                self.requestAmounts(manual: manual)
            }
            return
        }
        guard !isSleeping, eligibility == .eligible, !isStale, let snapshot = primarySnapshot, snapshot.identity.cycle != nil,
              let (summary, cookie) = latestRequest, supplementTask == nil, admissionTask == nil else { return }
        guard collect != nil, let allowance = schedule.begin(at: now(), manual: manual),
              let attemptID = schedule.currentAttemptID else {
            requestSupplement(snapshot: snapshot, summary: summary, cookie: cookie)
            return
        }
        fulfilledDemand = nil
        reevaluateToday(at: now())
        launchCollection(snapshot: snapshot, summary: summary, cookie: cookie, allowance: allowance,
                         attemptID: attemptID, context: nil, demand: nil)
    }

    private func launchCollection(snapshot: SplitUsageSnapshot, summary: UsageSummaryResponse, cookie: String,
                                  allowance: Int, attemptID: UInt64, context: TodayUsageCollectionContext?,
                                  demand: CycleCollectionDemand?, operation preparedOperation: UInt64? = nil) {
        guard let collect else { return }
        taskRevision &+= 1
        let taskID = taskRevision
        let subject = persistentSubjectDigest
        let authority = authorityEpoch
        amountState = .refreshing
        task = Task { [weak self, store] in
            guard let self else { return }
            defer {
                self.schedule.finish(.cancelled, pages: 0, at: self.now(), attemptID: attemptID)
                if self.taskRevision == taskID {
                    self.task = nil
                    self.activeToday = nil
                    self.activeDemand = nil
                }
                self.drainToday()
            }
            guard self.owns(taskID, snapshot: snapshot) else { return }
            let operation: UInt64?
            if context != nil { operation = preparedOperation }
            else { operation = await store?.activate(identity: snapshot.identity, authority: authority) }
            guard self.owns(taskID, snapshot: snapshot) else { return }
            if self.amounts == nil, let operation, let cached = await store?.load(operation: operation, now: self.now()),
               self.owns(taskID, snapshot: snapshot) {
                self.amounts = cached
                self.fulfilledDemand = nil
                self.reevaluateToday(at: self.now())
            }
            guard self.owns(taskID, snapshot: snapshot) else { return }
            let fingerprint = Self.fingerprint(summary: summary)
            let result = await collect(snapshot, summary, cookie, allowance, context) { [weak self] supplemental in
                await self?.acceptSupplement(supplemental, fingerprint: fingerprint, taskID: taskID)
            }
            let unreconciled = demand != nil && result.status == .complete && result.snapshot.map {
                $0.coverage.complete && ($0.residualCents.map { $0.isNaN || abs($0) > 1 } ?? true)
            } == true
            self.schedule.finish(unreconciled ? .unstable : Self.outcome(result.status), pages: result.pageCount,
                                 at: self.now(), attemptID: attemptID)
            guard self.owns(taskID, snapshot: snapshot) else { return }
            if let supplemental = result.supplementarySnapshot {
                self.acceptSupplement(supplemental, fingerprint: fingerprint, taskID: taskID)
            }
            if let amounts = result.snapshot, amounts.identity.sameScope(as: snapshot.identity),
               amounts.identity.credentialGeneration == snapshot.identity.credentialGeneration {
                if amounts.coverage.complete {
                    self.durableInvalidAttribution = amounts.unknownCount > 0 || amounts.unknownCents != 0
                        || [amounts.cursorCents, amounts.otherCents].contains { $0.isNaN || $0 < 0 }
                        || ((amounts.sourceCursorPercent ?? 0) > 0 && amounts.cursorCents == 0)
                        || ((amounts.sourceOtherPercent ?? 0) > 0 && amounts.otherCents == 0)
                }
                let retainEarlier = unreconciled && self.amountFingerprint == fingerprint
                    && self.amounts?.coverage.complete == true && self.amounts?.status == .estimatedAttribution
                if retainEarlier {
                    self.amountsAreEarlier = true
                    self.fulfilledDemand = nil
                } else if amounts.coverage.complete || self.amounts?.coverage.complete != true {
                    self.amounts = amounts
                    self.amountFingerprint = fingerprint
                    self.amountsAreEarlier = false
                    self.fulfilledDemand = result.status == .complete && !unreconciled ? demand : nil
                    if let operation, subject != nil { try? await store?.save(amounts, operation: operation) }
                    guard self.owns(taskID, snapshot: snapshot) else { return }
                }
            }
            self.reevaluateToday(at: self.now())
            switch result.status {
            case .complete: self.amountState = .ready
            case .partial, .unstable: self.amountState = self.amounts == nil ? .unavailable : .ready
            case .cancelled: self.amountState = .pending
            default: self.amountState = .failed
            }
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
              let primarySnapshot, supplemental.identity.sameScope(as: primarySnapshot.identity),
              supplemental.identity.credentialGeneration == primarySnapshot.identity.credentialGeneration,
              fingerprint == primaryFingerprint, let capturedAt = supplemental.periodCapturedAt,
              (0...600).contains(now().timeIntervalSince(capturedAt)) else { return }
        periodCursorPlaces = max(periodCursorPlaces, supplemental.periodCursorObservedPlaces)
        periodOtherPlaces = max(periodOtherPlaces, supplemental.periodOtherObservedPlaces)
        supplementMemo = (supplemental, fingerprint)
        snapshot = applying(supplemental, to: primarySnapshot)
        reevaluateToday(at: now())
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
                    self.drainToday()
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
        !isSleeping && eligibility == .eligible && !isStale && !isFetchingSupplement && snapshot?.identity.cycle != nil
            && schedule.availability(at: now(), manual: true) == .ready
    }

    var isAmountCollectionPaused: Bool {
        schedule.availability(at: now(), manual: false) == .cycleLimit
    }

    func retryStoppedAmounts() async {
        guard isAmountCollectionPaused else { return }
        let owner = taskRevision
        // Primary refresh may have started a period lookup before this manual retry.
        await supplementTask?.value
        guard !Task.isCancelled, taskRevision == owner, isAmountCollectionPaused else { return }
        requestAmounts(manual: true)
    }

    var amountsRefreshStateText: String {
        guard eligibility == .eligible else { return "Amounts unavailable until split usage is verified" }
        guard !isSleeping else { return "Paused while Mac sleeps" }
        guard !isStale else { return "Waiting for a successful usage refresh" }
        guard snapshot?.identity.cycle != nil else { return "Billing cycle unavailable" }
        if isFetchingSupplement { return "Refreshing percentages…" }
        switch schedule.availability(at: now(), manual: true) {
        case .ready:
            return schedule.availability(at: now(), manual: false) == .cycleLimit
                ? "Auto collection paused · Retry manually" : "Refresh amounts"
        case .collecting: return "Refreshing amounts…"
        case let .waiting(until): return "Available in \(max(1, Int(ceil(until.timeIntervalSince(now())))))s"
        case .cycleLimit: return "Collection limit reached"
        case .unchanged: return "Amounts unchanged"
        }
    }

    func recordFailure() {
        if suppressesLegacyMeter { isStale = true }
        reevaluateToday(at: now())
    }

    func prepareForSleep() {
        isSleeping = true
        historyEpoch &+= 1
        waitsForWakeRefresh = true
        if pendingToday == nil { pendingToday = activeToday }
        retireTask()
        reevaluateToday(at: now())
    }

    func resumeAfterWake() {
        isSleeping = false
        historyEpoch &+= 1
        reevaluateToday(at: now())
    }

    func suspend(removePersisted: Bool = false, subjectDigest: String? = nil) {
        lifecycleRevision &+= 1
        preparationRevision &+= 1
        preparedForAcceptance = false
        retireTask()
        latestRequest = nil
        clearToday()
        recordFailure()
        let subject = subjectDigest ?? persistentSubjectDigest
        persistentSubjectDigest = nil
        enqueueAuthorityFence(subjectDigest: nil, invalidate: true,
                              removePersisted: removePersisted, removalSubjectDigest: subject)
    }

    func reset(removePersisted: Bool = false, subjectDigest: String? = nil) {
        suspend(removePersisted: removePersisted, subjectDigest: subjectDigest)
        resetMemory()
        sessionIdentity = UUID().uuidString
    }

    private func resetMemory() {
        eligibility = .legacy; snapshot = nil; primarySnapshot = nil; amounts = nil; isStale = false
        amountState = .pending
        membership = nil; planLimit = nil; cycle = nil
        planScopeIdentity = nil; primaryFingerprint = nil; supplementMemo = nil
        periodCursorPlaces = 0; periodOtherPlaces = 0
        supplementNextAt = nil; supplementFailures = 0
        schedule.resetCycle()
        clearToday()
    }

    private func enqueueAuthorityFence(subjectDigest: String?, invalidate: Bool = false,
                                       removePersisted: Bool = false, removalSubjectDigest: String? = nil) {
        authorityEpoch &+= 1
        let epoch = authorityEpoch
        authoritySubjectDigest = subjectDigest
        let previous = authorityFence
        authorityFence = Task { [weak self, store] in
            _ = await previous?.value
            let acknowledged: Bool
            if invalidate {
                try? await store?.invalidate(authority: epoch, removePersisted: removePersisted,
                                            subjectDigest: removalSubjectDigest)
                acknowledged = true
            } else {
                acknowledged = await store?.prepareAuthority(epoch: epoch, subjectDigest: subjectDigest) ?? true
            }
            if self?.authorityEpoch == epoch { self?.authorityFence = nil }
            return acknowledged
        }
    }

    private func clearToday() {
        pendingToday = nil; activeToday = nil; activeDemand = nil; latestDemand = nil; fulfilledDemand = nil
        lastHistoryRequest = nil; amountFingerprint = nil; durableInvalidAttribution = false
        todayPercentagePoints = nil; amountsAreEarlier = false
        cancelDeferredWake()
    }

    private func retireTask() {
        admissionTask?.cancel()
        admissionTask = nil
        cancelDeferredWake()
        activeToday = nil
        activeDemand = nil
        fulfilledDemand = nil
        taskRevision &+= 1
        task?.cancel()
        task = nil
        supplementRevision &+= 1
        supplementTask?.cancel()
        supplementTask = nil
        isFetchingSupplement = false
        schedule.retireCurrent(at: now())
        schedule.invalidateCompletedTodayDemand()
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
