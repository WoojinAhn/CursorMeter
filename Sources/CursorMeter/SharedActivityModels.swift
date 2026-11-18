import Foundation

/// Dashboard-v2 values never use the legacy request-history cache.
enum SharedActivityValue {
    static let maximumTokens = 9_007_199_254_740_991
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    static func date(_ value: String?) -> Date? {
        guard let value, value.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) != nil else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    static func cents(_ value: String?, signed: Bool = false) -> Decimal? {
        guard let value, value.count <= 40,
              value.range(of: #"^-?\d+(\.\d{1,10})?$"#, options: .regularExpression) != nil,
              let decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
              !decimal.isNaN, signed || decimal >= 0 else { return nil }
        var amount = decimal
        var hundred = Decimal(100)
        var result = Decimal()
        guard NSDecimalMultiply(&result, &amount, &hundred, .plain) == .noError,
              abs(NSDecimalNumber(decimal: result).doubleValue) <= 1e15 else { return nil }
        return result
    }

    static func tokenCount(_ value: String?) -> Int? {
        guard let value, !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let count = Int(value), count <= maximumTokens else { return nil }
        return count
    }

    static func text(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= 256,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return value
    }
}

struct SharedBillingItemsResponse: Decodable, Sendable {
    private let available: Bool
    private let identityUnlinked: Bool
    private let items: [Item]
    private enum CodingKeys: String, CodingKey { case availability, data, pagination }
    private struct Pagination: Decodable { let hasMore: Bool; let nextCursor: String? }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let availability = try c.decodeIfPresent(String.self, forKey: .availability)
        available = availability == nil || availability == "available"
        identityUnlinked = availability == "identity_unlinked"
        if available {
            items = try c.decode([Item].self, forKey: .data)
            _ = try c.decode(Pagination.self, forKey: .pagination)
        } else { items = [] }
    }

    func candidate(start: Date, end: Date) throws -> RecentUsageCandidate {
        if identityUnlinked { throw CursorSharedAPIError.identityUnlinked }
        guard available, start < end, items.count <= RecentUsageCandidate.limit else { throw CursorSharedAPIError.invalidResponse }
        var ids = Set<String>()
        let entries = try items.map { item -> RecentUsageEntry in
            guard let date = SharedActivityValue.date(item.eventTime), date >= start, date <= end,
                  item.id.map({ ids.insert($0).inserted }) ?? true else { throw CursorSharedAPIError.invalidResponse }
            let kind: RecentUsageKind
            switch item.chargeCategory {
            case "credit": kind = .creditGrant
            case "adjustment": kind = .adjustment
            case "usage":
                switch item.usageType {
                case "included": kind = .included
                case "on_demand": kind = .additionalUsage
                case "credits": kind = .creditGrant
                case "free": kind = .free
                default: kind = .other
                }
            default: kind = .other
            }
            let context = [item.product, item.model ?? item.displayLabel].compactMap { $0 }
            return RecentUsageEntry(date: date, model: context.isEmpty ? nil : context.joined(separator: " · "),
                kind: kind, tokens: item.hasTokenMeters == false ? nil : SharedActivityValue.tokenCount(item.tokens),
                chargedCents: nil, exactChargedCents: item.currency == "USD"
                    ? SharedActivityValue.cents(item.cost, signed: kind == .creditGrant || kind == .adjustment) : nil)
        }
        return RecentUsageCandidate(entries: entries.enumerated().sorted {
            $0.element.date == $1.element.date ? $0.offset < $1.offset : $0.element.date > $1.element.date
        }.map(\.element), cachedAt: end)
    }

    private struct Item: Decodable, Sendable {
        let eventTime: String
        let id: String?
        let product: String?
        let model: String?
        let displayLabel: String?
        let chargeCategory: String
        let usageType: String?
        let tokens: String?
        let hasTokenMeters: Bool?
        let currency: String?
        let cost: String?
        private enum CodingKeys: String, CodingKey { case eventTime, billingItemId, product, chargeCategory, usageType, totalTokens, hasTokenMeters, pricing, displayExtras }
        private enum PricingKeys: String, CodingKey { case currency, contracted }
        private enum ExtrasKeys: String, CodingKey { case model, displayLabel }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            eventTime = try c.decode(String.self, forKey: .eventTime)
            id = try c.decodeIfPresent(String.self, forKey: .billingItemId)
            product = SharedActivityValue.text(try? c.decode(String.self, forKey: .product))
            chargeCategory = try c.decode(String.self, forKey: .chargeCategory)
            usageType = try? c.decode(String.self, forKey: .usageType)
            tokens = try? c.decode(String.self, forKey: .totalTokens)
            hasTokenMeters = try? c.decode(Bool.self, forKey: .hasTokenMeters)
            let pricing = try? c.nestedContainer(keyedBy: PricingKeys.self, forKey: .pricing)
            currency = try? pricing?.decode(String.self, forKey: .currency)
            cost = try? pricing?.decode(String.self, forKey: .contracted)
            let extras = try? c.nestedContainer(keyedBy: ExtrasKeys.self, forKey: .displayExtras)
            model = SharedActivityValue.text(try? extras?.decode(String.self, forKey: .model))
            displayLabel = SharedActivityValue.text(try? extras?.decode(String.self, forKey: .displayLabel))
        }
    }
}

struct SharedPaidPeriod: Sendable, Equatable { let start: Date; let end: Date }

struct SharedUsageStatusResponse: Decodable, Sendable {
    private let availability: String
    private let monthlyUsage: Monthly?
    var identityUnlinked: Bool { availability == "identity_unlinked" }
    private struct Monthly: Decodable, Sendable { let periodStart: String; let resetsAt: String }
    private enum CodingKeys: String, CodingKey { case availability, monthlyUsage }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        availability = try c.decode(String.self, forKey: .availability)
        monthlyUsage = availability == "identity_unlinked" ? nil : try c.decodeIfPresent(Monthly.self, forKey: .monthlyUsage)
    }

    func paidPeriod(at now: Date) -> SharedPaidPeriod? {
        guard availability == "available", let monthlyUsage,
              let start = SharedActivityValue.date(monthlyUsage.periodStart),
              let end = SharedActivityValue.date(monthlyUsage.resetsAt), start <= now, now < end,
              end.timeIntervalSince(start) <= 62 * 86400 else { return nil }
        return .init(start: start, end: end)
    }
}

struct SharedDailyUsageResponse: Decodable, Sendable {
    private let available: Bool
    private let identityUnlinked: Bool
    private let startTime: String?
    private let endTime: String?
    private let series: [Series]
    private let other: Totals?
    private let summary: Summary?
    private enum CodingKeys: String, CodingKey { case availability, startTime, endTime, series, other, totalContractedCost, totalTokens, totalIncludedTokens }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let availability = try c.decodeIfPresent(String.self, forKey: .availability)
        available = availability == nil || availability == "available"
        identityUnlinked = availability == "identity_unlinked"
        guard available else { startTime = nil; endTime = nil; series = []; other = nil; summary = nil; return }
        startTime = try c.decode(String.self, forKey: .startTime)
        endTime = try c.decode(String.self, forKey: .endTime)
        series = try c.decode([Series].self, forKey: .series)
        other = try c.decode(Totals.self, forKey: .other)
        summary = try Summary(from: decoder)
    }

    func days(start: Date, end: Date, topN: Int = 20) throws -> [DayUsage] {
        if identityUnlinked { throw CursorSharedAPIError.identityUnlinked }
        let calendar = SharedActivityValue.utc
        let today = calendar.startOfDay(for: end)
        guard available, topN > 0, let responseStart = SharedActivityValue.date(startTime),
              let responseEnd = SharedActivityValue.date(endTime), abs(responseStart.timeIntervalSince(start)) < 0.001,
              abs(responseEnd.timeIntervalSince(end)) < 0.001, start < end,
              start == calendar.date(byAdding: .day, value: -6, to: today),
              series.count <= topN * 2, let other, let summary else { throw CursorSharedAPIError.invalidResponse }
        var amounts: [Date: Decimal] = [:]
        var tokens: [Date: Int] = [:]
        var unknownAmounts = Set<Date>()
        var unknownTokens = Set<Date>()
        var dimensions = Set<String>()
        var allAmountsKnown = summary.cost != nil
        var allTokensKnown = summary.tokens != nil
        func add(_ points: [Point], summary: Summary, costs: Bool, counts: Bool) throws {
            var costSum = Decimal.zero
            var tokenSum = 0

            guard points.count <= 7 else { throw CursorSharedAPIError.invalidResponse }
            var seen = Set<Date>()
            for point in points {
                guard let day = SharedActivityValue.date(point.dayStartTime), day == calendar.startOfDay(for: day),
                      day >= start, day <= today, seen.insert(day).inserted else { throw CursorSharedAPIError.invalidResponse }
                if costs {
                    if let cents = SharedActivityValue.cents(point.contractedCost) {
                        costSum += cents
                        let sum = (amounts[day] ?? 0) + cents
                        if sum.isNaN || NSDecimalNumber(decimal: sum).doubleValue > 1e15 { unknownAmounts.insert(day) }
                        else { amounts[day] = sum }
                    } else { unknownAmounts.insert(day) }
                }
                if counts {
                    if let count = point.tokens, count >= 0, count <= SharedActivityValue.maximumTokens,
                       let included = point.includedTokens, included >= 0, included <= count {
                        let aggregate = tokenSum.addingReportingOverflow(count)
                        if aggregate.overflow { allTokensKnown = false } else { tokenSum = aggregate.partialValue }
                        let sum = (tokens[day] ?? 0).addingReportingOverflow(count)
                        if sum.overflow || sum.partialValue > SharedActivityValue.maximumTokens { unknownTokens.insert(day) }
                        else { tokens[day] = sum.partialValue }
                    } else { unknownTokens.insert(day) }
                }
            }
            if costs, summary.cost != costSum { allAmountsKnown = false }
            if counts, summary.tokens != tokenSum { allTokensKnown = false }
        }
        for item in series {
            guard item.costRank > 0, item.tokenRank > 0,
                  dimensions.insert(item.dimensions.usageType ?? "").inserted else { throw CursorSharedAPIError.invalidResponse }
            try add(item.points, summary: item.summary, costs: item.costRank <= topN, counts: item.tokenRank <= topN)
        }
        try add(other.points, summary: other.summary, costs: true, counts: true)
        if summary.cost != amounts.values.reduce(Decimal.zero, +) { allAmountsKnown = false }
        if summary.tokens != tokens.values.reduce(0, +) { allTokensKnown = false }
        return (0..<7).map { offset in
            let day = calendar.date(byAdding: .day, value: offset, to: start)!
            return DayUsage(date: day, requests: 0, isToday: day == today, isOnDemand: false,
                onDemandCents: 0, totalChargedCents: 0, amountCents: !allAmountsKnown || unknownAmounts.contains(day) ? nil : NSDecimalNumber(decimal: amounts[day] ?? 0).doubleValue,
                tokens: !allTokensKnown || unknownTokens.contains(day) ? nil : (tokens[day] ?? 0), usesUTCDays: true)
        }
    }

    private struct Dimensions: Decodable, Sendable { let usageType: String? }
    private struct Summary: Decodable, Sendable {
        let cost: Decimal?
        let tokens: Int?
        private enum CodingKeys: String, CodingKey { case totalContractedCost, totalTokens, totalIncludedTokens }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            cost = SharedActivityValue.cents(try? c.decode(String.self, forKey: .totalContractedCost))
            let total = try? c.decode(Int.self, forKey: .totalTokens)
            let included = try? c.decode(Int.self, forKey: .totalIncludedTokens)
            if let total, let included, total >= 0, total <= SharedActivityValue.maximumTokens, included >= 0, included <= total {
                tokens = total
            } else { tokens = nil }
        }
    }
    private struct Series: Decodable, Sendable {
        let dimensions: Dimensions
        let costRank: Int
        let tokenRank: Int
        let points: [Point]
        let summary: Summary
        private enum CodingKeys: String, CodingKey { case dimensions, costRank, tokenRank, points }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            dimensions = try c.decode(Dimensions.self, forKey: .dimensions)
            costRank = try c.decode(Int.self, forKey: .costRank)
            tokenRank = try c.decode(Int.self, forKey: .tokenRank)
            points = try c.decode([Point].self, forKey: .points)
            summary = try Summary(from: decoder)
        }
    }
    private struct Totals: Decodable, Sendable {
        let points: [Point]
        let summary: Summary
        private enum CodingKeys: String, CodingKey { case points }
        init(from decoder: Decoder) throws {
            points = try decoder.container(keyedBy: CodingKeys.self).decode([Point].self, forKey: .points)
            summary = try Summary(from: decoder)
        }
    }
    private struct Point: Decodable, Sendable {
        let dayStartTime: String
        let contractedCost: String?
        let tokens: Int?
        let includedTokens: Int?
        private enum CodingKeys: String, CodingKey { case dayStartTime, contractedCost, tokens, includedTokens }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            dayStartTime = try c.decode(String.self, forKey: .dayStartTime)
            contractedCost = try? c.decode(String.self, forKey: .contractedCost)
            tokens = try? c.decode(Int.self, forKey: .tokens)
            includedTokens = try? c.decode(Int.self, forKey: .includedTokens)
        }
    }
}
