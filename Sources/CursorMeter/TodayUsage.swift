import Foundation

struct TodayUsageDay: Codable, Equatable, Hashable, Sendable {
    let start: Date
    let end: Date

    init?(containing instant: Date) {
        guard instant.timeIntervalSince1970.isFinite else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        guard let interval = calendar.dateInterval(of: .day, for: instant) else { return nil }
        start = interval.start
        end = interval.end
    }

    func contains(_ instant: Date) -> Bool { start <= instant && instant < end }
}

struct TodayUsageCollectionContext: Equatable, Sendable {
    let day: TodayUsageDay
    let admittedAt: Date

    init?(admittedAt: Date) {
        guard let day = TodayUsageDay(containing: admittedAt) else { return nil }
        self.day = day
        self.admittedAt = admittedAt
    }
}

struct TodayUsageAggregate: Codable, Equatable, Sendable {
    let day: TodayUsageDay
    let evidenceAt: Date
    var cursorCents: Decimal = 0
    var otherCents: Decimal = 0
    let sourceIncludedTotalCents: Decimal

    func amountCents(for pool: UsagePoolID) -> Decimal { pool == .cursor ? cursorCents : otherCents }

    func isValid(for amounts: CycleAmountSnapshot) -> Bool {
        guard evidenceAt.timeIntervalSince1970.isFinite,
              day == TodayUsageDay(containing: evidenceAt), day.contains(evidenceAt),
              let cycle = amounts.identity.cycle, cycle.start < day.end, day.start < cycle.end,
              [cursorCents, otherCents, sourceIncludedTotalCents].allSatisfy({ !$0.isNaN && $0 >= 0 }),
              cursorCents <= amounts.cursorCents, otherCents <= amounts.otherCents else { return false }
        return true
    }
}

enum TodayUsageAllocation {
    static func percentagePoints(snapshot: SplitUsageSnapshot?, amounts: CycleAmountSnapshot?, primaryIsStale: Bool,
                                 currentSessionAndDemandEligible: Bool, now: Date) -> [UsagePoolID: Double]? {
        guard !primaryIsStale, currentSessionAndDemandEligible, now.timeIntervalSince1970.isFinite,
              let snapshot, let amounts, !amounts.isCached,
              amounts.identity.sameScope(as: snapshot.identity),
              amounts.identity.credentialGeneration == snapshot.identity.credentialGeneration,
              amounts.classifierVersion == CycleModelClassifier.version,
              let cycle = snapshot.identity.cycle, cycle.start <= now, now < cycle.end,
              snapshot.capturedAt.timeIntervalSince1970.isFinite, snapshot.capturedAt <= now,
              amounts.capturedAt.timeIntervalSince1970.isFinite, amounts.capturedAt <= now,
              amounts.coverage.complete, amounts.status == .estimatedAttribution,
              amounts.unknownCount == 0, amounts.unknownCents == 0,
              let residual = amounts.residualCents, !residual.isNaN, abs(residual) <= 1,
              [amounts.cursorCents, amounts.otherCents].allSatisfy({ !$0.isNaN && $0 >= 0 }),
              let today = amounts.todayUsage, today.isValid(for: amounts),
              today.day == TodayUsageDay(containing: now), today.evidenceAt <= now,
              let included = snapshot.includedUsedCents, !included.isNaN, included >= 0,
              today.sourceIncludedTotalCents == included,
              abs(amounts.cursorCents + amounts.otherCents - included) <= 1,
              let cursorPercent = SplitUsageSnapshot.validPercent(snapshot.cursorPercent),
              let otherPercent = SplitUsageSnapshot.validPercent(snapshot.otherPercent),
              cursorPercent < 100, otherPercent < 100,
              amounts.sourceCursorPercent == cursorPercent, amounts.sourceOtherPercent == otherPercent,
              cursorPercent == 0 || amounts.cursorCents > 0,
              otherPercent == 0 || amounts.otherCents > 0 else { return nil }

        var result: [UsagePoolID: Double] = [:]
        for pool in UsagePoolID.allCases {
            let percent = pool == .cursor ? cursorPercent : otherPercent
            let cycleCost = amounts.amountCents(for: pool)
            guard percent > 0, cycleCost > 0 else { continue }
            let share = NSDecimalNumber(decimal: today.amountCents(for: pool) / cycleCost).doubleValue
            let points = percent * share
            guard share.isFinite, share >= 0, share <= 1, points.isFinite else { return nil }
            result[pool] = points
        }
        return result
    }
}
