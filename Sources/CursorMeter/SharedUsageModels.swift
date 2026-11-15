import Foundation

struct SharedWeeklyUsage: Equatable, Sendable {
    let percentUsed: Double?
    let period: UsageCycle?

    init(percentUsed: Double?, period: UsageCycle?) {
        self.percentUsed = percentUsed.flatMap { $0.isFinite && (0...100).contains($0) ? $0 : nil }
        self.period = period
    }

    func hasIncludedUsage(at date: Date) -> Bool? {
        guard let period, period.start <= date, date < period.end,
              let percentUsed else { return nil }
        return percentUsed < 100
    }
}

enum SharedPaidCap: Equatable, Sendable {
    case unknown
    case uncapped
    case limited(Decimal)
}

struct SharedPaidUsage: Equatable, Sendable {
    let usedCents: Decimal?
    let cap: SharedPaidCap

    init(usedCents: Decimal?, cap: SharedPaidCap) {
        self.usedCents = usedCents.flatMap { !$0.isNaN && $0 >= 0 ? $0 : nil }
        if case let .limited(limit) = cap, limit.isNaN || limit < 0 {
            self.cap = .unknown
        } else {
            self.cap = cap
        }
    }

    var isCapReached: Bool? {
        switch cap {
        case .unknown:
            return nil
        case .uncapped:
            return false
        case .limited(let limit):
            if limit == 0 { return true }
            guard let usedCents else { return nil }
            return usedCents >= limit
        }
    }
}
