import Foundation

struct PrepaidCreditUsage: Equatable, Sendable {
    let remainingCents: Decimal?
    let totalPurchasedCents: Decimal?

    init(remainingCents: Decimal?, totalPurchasedCents: Decimal?) {
        self.remainingCents = Self.validAmount(remainingCents)
        self.totalPurchasedCents = Self.validAmount(totalPurchasedCents)
    }

    var consumedCents: Decimal? {
        guard let remainingCents, let totalPurchasedCents,
              remainingCents <= totalPurchasedCents else { return nil }
        return totalPurchasedCents - remainingCents
    }

    var percentUsed: Double? {
        guard let totalPurchasedCents, totalPurchasedCents > 0,
              let consumedCents else { return nil }
        return NSDecimalNumber(decimal: consumedCents / totalPurchasedCents * 100).doubleValue
    }

    var hasNoPurchases: Bool {
        totalPurchasedCents == 0 && remainingCents == 0
    }

    private static func validAmount(_ amount: Decimal?) -> Decimal? {
        guard let amount, !amount.isNaN, amount >= 0 else { return nil }
        return amount
    }
}
