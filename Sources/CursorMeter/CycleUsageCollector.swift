import Foundation

struct CycleUsageCollector: Sendable {
    struct Budget: Sendable {
        var maxPages: Int = 100
        var maxEvents: Int = 10_000
        var maxBytes: Int = 16 * 1024 * 1024
        var maxDuration: TimeInterval = 60
    }
    let budget: Budget
    let fetchPage: @Sendable (Int, Int) async throws -> CycleHistoryPage
    let fetchSummary: @Sendable () async throws -> UsageSummaryResponse
    let fetchPeriod: @Sendable () async throws -> CurrentPeriodUsageResponse
    let onSupplement: (@Sendable (SplitUsageSnapshot) async -> Void)?
    var now: @Sendable () -> Date = { Date() }

    init(budget: Budget = .init(), fetchPage: @escaping @Sendable (Int, Int) async throws -> CycleHistoryPage,
         fetchSummary: @escaping @Sendable () async throws -> UsageSummaryResponse,
         fetchPeriod: @escaping @Sendable () async throws -> CurrentPeriodUsageResponse,
         onSupplement: (@Sendable (SplitUsageSnapshot) async -> Void)? = nil) {
        self.budget = budget; self.fetchPage = fetchPage; self.fetchSummary = fetchSummary; self.fetchPeriod = fetchPeriod
        self.onSupplement = onSupplement
    }

    func collect(snapshot: SplitUsageSnapshot, summary: UsageSummaryResponse) async -> CycleCollectionResult {
        let began = now()
        var pages = 0, bytes = 0, receivedEvents = 0
        var partial: CycleAmountSnapshot?
        var retryingUnreconciledSource = false
        var supplementary: SplitUsageSnapshot?
        func result(_ status: CycleCollectionStatus, _ amount: CycleAmountSnapshot? = nil) -> CycleCollectionResult {
            .init(status: status, snapshot: amount, pageCount: pages, byteCount: bytes, supplementarySnapshot: status == .complete ? supplementary : nil)
        }
        func checkBudget() throws {
            try Task.checkCancellation()
            if now().timeIntervalSince(began) >= budget.maxDuration { throw CycleEnrichmentError.payloadBudget }
        }
        func bounded<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
            try checkBudget()
            let remaining = max(0, budget.maxDuration - now().timeIntervalSince(began))
            return try await withThrowingTaskGroup(of: T.self) { group in
                group.addTask { try await operation() }
                group.addTask {
                    try await Task.sleep(for: .seconds(remaining))
                    throw CycleEnrichmentError.payloadBudget
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw CancellationError() }
                return result
            }
        }
        func optionalPeriod() async throws -> (response: CurrentPeriodUsageResponse?, fingerprint: String) {
            do {
                let response = try await bounded { try await fetchPeriod() }
                return (response, "available:" + Self.periodFingerprint(response))
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as CycleEnrichmentError {
                switch error {
                case .payloadBudget, .oversizedPayload: throw error
                case let .http(status, _) where status == 429: throw error
                case let .http(status, _): return (nil, "unavailable:http:\(status)")
                case .transport: return (nil, "unavailable:transport")
                case .invalidResponse: return (nil, "unavailable:invalidResponse")
                }
            } catch {
                try Task.checkCancellation()
                return (nil, "unavailable:" + String(reflecting: type(of: error)))
            }
        }
        func page(_ number: Int) async throws -> CycleHistoryPage {
            try checkBudget()
            guard pages < budget.maxPages, bytes < budget.maxBytes else { throw CycleEnrichmentError.payloadBudget }
            pages += 1
            let remainingBytes = budget.maxBytes - bytes
            let response = try await bounded { try await fetchPage(number, remainingBytes) }
            try Task.checkCancellation()
            guard response.byteCount >= 0 else { throw CycleEnrichmentError.invalidResponse }
            bytes += response.byteCount
            receivedEvents += response.page.events.count
            guard bytes <= budget.maxBytes, receivedEvents <= budget.maxEvents else { throw CycleEnrichmentError.payloadBudget }
            try checkBudget()
            return response
        }
        guard let cycle = snapshot.identity.cycle,
              cycle == UsageCycle(start: summary.billingCycleStart, end: summary.billingCycleEnd) else { return result(.endpointFailure) }
        do {
            for attempt in 0...1 {
                partial = nil
                try checkBudget()
                let period = try await optionalPeriod()
                try checkBudget()
                let coherentPeriod = period.response?.isCoherent(with: summary) == true
                let rawModels = coherentPeriod ? period.response?.autoBucketModels : nil
                let models = rawModels.flatMap { values in
                    let names = values.map(CycleModelClassifier.normalize).filter { !$0.isEmpty }
                    return names.isEmpty ? nil : names
                }
                let plan = summary.individualUsage?.plan
                guard snapshot.cursorPercent == plan?.autoPercentUsed, snapshot.otherPercent == plan?.apiPercentUsed,
                      snapshot.includedUsedCents == plan?.used.flatMap({ $0 >= 0 ? Decimal($0) : nil }) else {
                    return result(.unstable)
                }
                let resolved = snapshot.supplemented(by: period.response, summary: summary, at: now())
                supplementary = resolved == snapshot ? nil : resolved
                if let supplementary, let onSupplement {
                    try await bounded { await onSupplement(supplementary) }
                    try checkBudget()
                }
                var aggregate = CycleAmountSnapshot(identity: snapshot.identity, capturedAt: snapshot.capturedAt)
                aggregate.sourceCursorPercent = resolved.cursorPercent
                aggregate.sourceOtherPercent = resolved.otherPercent
                aggregate.cursorObservedPlaces = resolved.cursorObservedPlaces
                aggregate.otherObservedPlaces = resolved.otherObservedPlaces
                var included: Decimal = 0
                var reachedCycleStart = false
                var unresolved = false, invalid = false
                var lastDate: Date?, seenPages = Set<String>(), priorRows = Set<String>()
                var reportedTotal: Int?, totalPresence: Bool?, visited = 0
                var head: CycleUsagePage?
                var pageNumber = 1
                while !aggregate.coverage.complete && !invalid {
                    let response = try await page(pageNumber)
                    let current = response.page
                    if head == nil { head = current }
                    aggregate.coverage.pageCount = pages
                    aggregate.coverage.byteCount = bytes
                    if let presence = totalPresence, presence != (current.total != nil) { invalid = true }
                    totalPresence = current.total != nil
                    if let total = current.total {
                        if total < 0 || (reportedTotal != nil && reportedTotal != total) { invalid = true }
                        reportedTotal = total
                    }
                    if current.events.isEmpty {
                        aggregate.coverage.complete = (current.hasEvents || current.total == 0) && (reportedTotal == nil || visited == reportedTotal)
                        aggregate.coverage.reason = aggregate.coverage.complete ? "Empty termination" : "Empty data below reported total"
                        if !aggregate.coverage.complete { invalid = true }
                    } else {
                        if !seenPages.insert(current.fingerprint).inserted { invalid = true }
                        let fingerprints = Set(current.events.map(\.fingerprint))
                        if !priorRows.isDisjoint(with: fingerprints) { invalid = true }
                        priorRows.formUnion(fingerprints)
                        var crossedStart = false
                        for event in current.events {
                            visited += 1
                            guard let date = event.date else { invalid = true; continue }
                            if let previous = lastDate, date > previous { invalid = true }
                            lastDate = date
                            aggregate.coverage.oldest = date
                            if aggregate.coverage.newest == nil { aggregate.coverage.newest = date }
                            if date < cycle.start { crossedStart = true; reachedCycleStart = true; continue }
                            guard date < cycle.end else { continue }
                            aggregate.coverage.eventCount += 1
                            let classification = CycleModelClassifier.classify(event.model, serverModels: models)
                            if !aggregate.provenance.contains(classification.provenance) { aggregate.provenance.append(classification.provenance) }
                            let cents = event.chargedCents
                            let validCost = cents.map { !$0.isNaN && $0 >= 0 } ?? false
                            let cost = validCost ? cents! : 0
                            let excluded = event.kind == "USAGE_EVENT_KIND_ERRORED_NOT_CHARGED" && (cents == nil || cents == 0)
                            if excluded { continue }
                            if !validCost || (event.isChargeable == false && cost > 0) {
                                unresolved = true; aggregate.unknownCount += 1; aggregate.unknownCents += cost; continue
                            }
                            if event.kind == "USAGE_EVENT_KIND_USAGE_BASED" { aggregate.paidCents += cost; continue }
                            guard ["USAGE_EVENT_KIND_INCLUDED_IN_ULTRA", "USAGE_EVENT_KIND_INCLUDED_IN_BUSINESS", "USAGE_EVENT_KIND_FREE_CREDIT"].contains(event.kind ?? "") else {
                                unresolved = true; aggregate.unknownCount += 1; aggregate.unknownCents += cost; continue
                            }
                            switch classification.family {
                            case .bot: aggregate.botCents += cost
                            case .cursor: aggregate.cursorCents += cost; included += cost
                            case .other: aggregate.otherCents += cost; included += cost
                            case .unknown: aggregate.unknownCents += cost; aggregate.unknownCount += 1; included += cost; unresolved = true
                            }
                        }
                        if let total = reportedTotal, visited > total { invalid = true }
                        if crossedStart || (reportedTotal != nil && visited == reportedTotal) {
                            aggregate.coverage.complete = true
                            aggregate.coverage.reason = crossedStart ? "Reached cycle start" : "Reached stable total"
                        }
                    }
                    partial = aggregate
                    pageNumber += 1
                }
                if invalid {
                    partial = nil
                    if attempt == 0 { continue }
                    return result(.unstable)
                }
                let endSummary = try await bounded { try await fetchSummary() }
                try checkBudget()
                guard Self.summaryFingerprint(summary) == Self.summaryFingerprint(endSummary) else {
                    partial = nil
                    return result(.unstable)
                }
                let endPeriod = try await optionalPeriod()
                try checkBudget()
                if period.fingerprint != endPeriod.fingerprint {
                    partial = nil
                    if attempt == 0 { continue }
                    return result(.unstable)
                }
                let recheck = try await page(1)
                let stable = head?.fingerprint == recheck.page.fingerprint && head?.total == recheck.page.total
                    && head?.hasEvents == recheck.page.hasEvents
                if !stable {
                    partial = nil
                    if attempt == 0 { continue }
                    return result(.unstable)
                }
                aggregate.coverage.pageCount = pages; aggregate.coverage.byteCount = bytes
                aggregate.residualCents = snapshot.includedUsedCents.map { included - $0 }
                let reconciled = aggregate.residualCents.map { abs($0) <= 1 } == true
                if !reachedCycleStart && !reconciled {
                    partial = nil
                    if attempt == 0 {
                        retryingUnreconciledSource = true
                        continue
                    }
                    return result(.unstable)
                }
                aggregate.status = reconciled && !unresolved ? .estimatedAttribution : .unavailable
                let noSpillover = (resolved.cursorPercent.map { $0 < 100 } == true) && (resolved.otherPercent.map { $0 < 100 } == true)
                if reconciled && !unresolved && noSpillover {
                    aggregate.estimatedCursorLimitCents = Self.estimate(amount: aggregate.cursorCents, percent: resolved.cursorPercent, places: resolved.cursorObservedPlaces)
                    aggregate.estimatedOtherLimitCents = Self.estimate(amount: aggregate.otherCents, percent: resolved.otherPercent, places: resolved.otherObservedPlaces)
                }
                return result(.complete, aggregate)
            }
            return result(.unstable)
        } catch is CancellationError { return result(.cancelled) }
        catch let error as CycleEnrichmentError {
            switch error {
            case let .oversizedPayload(byteCount):
                bytes += max(0, byteCount)
                return result(retryingUnreconciledSource ? .unstable : .partial)
            case .payloadBudget:
                if retryingUnreconciledSource { return result(.unstable) }
                if var amount = partial { amount.coverage.complete = false; amount.coverage.reason = "Collection budget exhausted"; amount.coverage.pageCount = pages; amount.coverage.byteCount = bytes; return result(.partial, amount) }
                return result(.partial)
            case .transport: return result(.transportFailure)
            case let .http(status, retryAfter):
                if status == 429 { return result(.rateLimited(retryAfter: max(60, retryAfter ?? 1800))) }
                return result(status >= 500 ? .transportFailure : .endpointFailure)
            case .invalidResponse: return result(.endpointFailure)
            }
        } catch { return result(.endpointFailure) }
    }

    static func estimate(amount: Decimal, percent: Double?, places: Int) -> Decimal? {
        guard amount > 0, let percent, percent.isFinite, percent >= 0.1, percent < 100,
              (pow(10, -Double(min(3, max(0, places)))) / 2) / percent <= 0.05,
              let decimalPercent = Decimal(string: String(percent), locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        return amount * 100 / decimalPercent
    }
    static func summaryFingerprint(_ summary: UsageSummaryResponse) -> String {
        let plan = summary.individualUsage?.plan
        var fields: [String] = []
        fields.append(UsageCycle(start: summary.billingCycleStart, end: summary.billingCycleEnd).map { "\($0.start.timeIntervalSince1970):\($0.end.timeIntervalSince1970)" } ?? "nil")
        fields.append(summary.membershipType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "")
        fields.append(summary.limitType?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "")
        fields.append(summary.teamUsage?.hasUsageData == true ? "team" : "personal")
        fields.append(plan?.used.map { String($0) } ?? "nil")
        fields.append(plan?.limit.map { String($0) } ?? "nil")
        fields.append(plan?.autoPercentUsed.map { String($0) } ?? "nil")
        fields.append(plan?.apiPercentUsed.map { String($0) } ?? "nil")
        return fields.joined(separator: "|")
    }
    static func periodFingerprint(_ period: CurrentPeriodUsageResponse) -> String {
        var fields: [String] = []
        fields.append(period.cycle.map { "\($0.start.timeIntervalSince1970):\($0.end.timeIntervalSince1970)" } ?? "nil")
        fields.append(period.planUsage?.includedSpend.map { NSDecimalNumber(decimal: $0).stringValue } ?? "nil")
        fields.append(period.planUsage?.autoPercentUsed.map { String($0) } ?? "nil")
        fields.append(period.planUsage?.apiPercentUsed.map { String($0) } ?? "nil")
        fields.append(period.autoBucketModels.map { $0.map(CycleModelClassifier.normalize).sorted().joined(separator: ",") } ?? "nil")
        return fields.joined(separator: "|")
    }
}
