import Foundation

enum CursorPlanClassification: Equatable, Sendable {
    case legacy, sharedWeekly, unsupported
}

struct CursorPlanInfoResponse: Decodable, Sendable {
    let isMerged: Bool
    let planInfo: CursorPlanInfo?

    enum CodingKeys: String, CodingKey { case isMerged, planInfo }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isMerged = c.contains(.isMerged) ? try c.decode(Bool.self, forKey: .isMerged) : false
        if isMerged {
            planInfo = try? c.decode(CursorPlanInfo.self, forKey: .planInfo)
        } else {
            planInfo = try c.decodeIfPresent(CursorPlanInfo.self, forKey: .planInfo)
        }
        guard c.contains(.isMerged) || planInfo != nil else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Missing plan metadata"))
        }
    }

    var classification: CursorPlanClassification {
        guard isMerged else { return .legacy }
        return planInfo?.includedUsagePeriod == "INCLUDED_USAGE_PERIOD_WEEKLY" ? .sharedWeekly : .unsupported
    }

    func weeklyUsage(from response: CurrentPeriodUsageResponse) -> SharedWeeklyUsage? {
        guard classification == .sharedWeekly else { return nil }
        guard let cycle = response.cycle, let reset = planInfo?.includedUsageResetsAt,
              cycle.end == Date(timeIntervalSince1970: Double(reset) / 1000) else {
            return SharedWeeklyUsage(percentUsed: nil, period: nil)
        }
        return SharedWeeklyUsage(percentUsed: response.planUsage?.totalPercentUsed, period: cycle)
    }
}

struct CursorPlanInfo: Decodable, Sendable {
    let planName: String?
    let includedUsagePeriod: String
    let includedUsageResetsAt: Int64?

    enum CodingKeys: String, CodingKey { case planName, includedUsagePeriod, includedUsageResetsAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        planName = try c.decodeIfPresent(String.self, forKey: .planName)
        includedUsagePeriod = try c.decode(String.self, forKey: .includedUsagePeriod)
        includedUsageResetsAt = c.nonnegativeInt64(.includedUsageResetsAt)
    }
}

struct CursorPrepaidBillingResponse: Decodable, Sendable {
    let billingMode: String?
    let eligible: Bool
    let availableCents: Int64?
    let fundedCents: Int64?
    let spentCents: Int64?
    let spentThisMonthCents: Int64?
    let autoTopUp: CursorAutoTopUp?
    let topUps: [CursorPrepaidTopUp]?

    enum CodingKeys: String, CodingKey {
        case billingMode, eligible, availableCents, fundedCents, spentCents, spentThisMonthCents, autoTopUp, topUps
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        billingMode = try c.decodeIfPresent(String.self, forKey: .billingMode)
        eligible = try c.decodeIfPresent(Bool.self, forKey: .eligible) ?? false
        let acceptsProtoZeros = billingMode == "PREPAID_BILLING_MODE_PREPAID" && eligible
        availableCents = c.nonnegativeInt64(.availableCents, omittedZero: acceptsProtoZeros)
        fundedCents = c.nonnegativeInt64(.fundedCents, omittedZero: acceptsProtoZeros)
        spentCents = c.nonnegativeInt64(.spentCents, omittedZero: acceptsProtoZeros)
        spentThisMonthCents = c.nonnegativeInt64(.spentThisMonthCents)
        autoTopUp = try? c.decode(CursorAutoTopUp.self, forKey: .autoTopUp)
        // An invalid history must not hide independently valid balance or monthly usage.
        topUps = c.contains(.topUps) ? try? c.decode([CursorPrepaidTopUp].self, forKey: .topUps) : []
    }

    var monthlyUsedCents: Decimal? { spentThisMonthCents.map(Decimal.init) }

    var creditUsage: PrepaidCreditUsage {
        guard billingMode == "PREPAID_BILLING_MODE_PREPAID", eligible else {
            return PrepaidCreditUsage(remainingCents: nil, totalPurchasedCents: nil)
        }
        return PrepaidCreditUsage(remainingCents: availableCents.map(Decimal.init), totalPurchasedCents: reconciledPurchasedCents)
    }

    private var reconciledPurchasedCents: Decimal? {
        guard let availableCents, let fundedCents, let spentCents, let topUps,
              fundedCents >= availableCents, fundedCents >= spentCents,
              fundedCents - spentCents == availableCents else { return nil }
        var tickets: [Int64: CursorPrepaidTopUp] = [:]
        var purchased = Decimal.zero
        for topUp in topUps {
            guard let ticket = topUp.ticket, ticket > 0,
                  topUp.origin == "TOPUP_MANUAL", let amount = topUp.amountCents, amount > 0,
                  let created = topUp.createdAtMs, created > 0,
                  ["SUCCEEDED", "PENDING", "FAILED"].contains(topUp.status) else { return nil }
            if let previous = tickets[ticket] {
                guard previous == topUp else { return nil }
                continue
            }
            tickets[ticket] = topUp
            if topUp.status == "SUCCEEDED" { purchased += Decimal(amount) }
        }
        // History is coverage evidence only: the server's reconciled funded total is the denominator.
        return purchased == Decimal(fundedCents) ? Decimal(fundedCents) : nil
    }
}

struct CursorAutoTopUp: Decodable, Sendable {
    let enabled: Bool
    let thresholdCents: Int64?
    let topUpAmountCents: Int64?
    let monthlyCapCents: Int64?

    enum CodingKeys: String, CodingKey { case enabled, thresholdCents, topUpAmountCents, monthlyCapCents }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        thresholdCents = c.nonnegativeInt64(.thresholdCents, omittedZero: true)
        topUpAmountCents = c.nonnegativeInt64(.topUpAmountCents, omittedZero: true)
        monthlyCapCents = c.nonnegativeInt64(.monthlyCapCents)
    }
}

struct CursorPrepaidTopUp: Decodable, Equatable, Sendable {
    let ticket: Int64?
    let origin: String
    let amountCents: Int64?
    let status: String
    let createdAtMs: Int64?
    let succeededAtMs: Int64?

    enum CodingKeys: String, CodingKey { case ticket, origin, amountCents, status, createdAtMs, succeededAtMs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ticket = c.nonnegativeInt64(.ticket)
        origin = try c.decode(String.self, forKey: .origin)
        amountCents = c.nonnegativeInt64(.amountCents)
        status = try c.decode(String.self, forKey: .status)
        createdAtMs = c.nonnegativeInt64(.createdAtMs)
        succeededAtMs = c.nonnegativeInt64(.succeededAtMs)
        if c.contains(.succeededAtMs), succeededAtMs == nil {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid purchase timestamp"))
        }
    }
}

struct CursorPaidCapResponse: Decodable, Sendable {
    let hardLimit: Decimal?
    let noUsageBasedAllowed: Bool?

    enum CodingKeys: String, CodingKey { case hardLimit, noUsageBasedAllowed }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hardLimit = c.integerDecimal(.hardLimit, minimum: Decimal(Int32.min), maximum: Decimal(Int32.max))
        noUsageBasedAllowed = try? c.decode(Bool.self, forKey: .noUsageBasedAllowed)
    }

    var cap: SharedPaidCap {
        if noUsageBasedAllowed == true { return .limited(0) }
        guard let hardLimit, !hardLimit.isNaN else { return .unknown }
        if hardLimit <= 0 { return .limited(0) }
        if hardLimit >= 2_147_483_647 { return .uncapped }
        return .limited(hardLimit * 100)
    }
}

private extension KeyedDecodingContainer {
    func nonnegativeInt64(_ key: Key, omittedZero: Bool = false) -> Int64? {
        guard contains(key) else { return omittedZero ? 0 : nil }
        if let string = try? decode(String.self, forKey: key) {
            guard !string.isEmpty, string.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            return Int64(string)
        }
        return integerDecimal(key, minimum: 0, maximum: Decimal(Int64.max)).map { NSDecimalNumber(decimal: $0).int64Value }
    }

    func integerDecimal(_ key: Key, minimum: Decimal, maximum: Decimal) -> Decimal? {
        guard var value = try? decode(Decimal.self, forKey: key),
              !value.isNaN, value >= minimum, value <= maximum else { return nil }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 0, .plain)
        return rounded == value ? value : nil
    }
}
