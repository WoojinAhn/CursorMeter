import Foundation

struct CycleUsageEvent: Codable, Sendable, Equatable {
    let timestamp: String
    let model: String?
    let kind: String?
    let chargedCents: Decimal?
    var isChargeable: Bool? = nil
    var date: Date? {
        guard let ms = Double(timestamp), ms.isFinite, ms >= 0 else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
    private var canonicalTimestamp: String {
        // Decimal(string:) accepts numeric prefixes, so validate the complete token first.
        let pattern = #"\A[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z"#
        guard timestamp.range(of: pattern, options: .regularExpression) != nil,
              let milliseconds = Decimal(string: timestamp, locale: Locale(identifier: "en_US_POSIX")),
              !milliseconds.isNaN else { return timestamp }
        return NSDecimalNumber(decimal: milliseconds).stringValue
    }
    var fingerprint: String {
        let fields = [canonicalTimestamp, model ?? "", kind ?? "",
                      chargedCents.map { NSDecimalNumber(decimal: $0).stringValue } ?? "nil", isChargeable.map(String.init) ?? "nil"]
        return UsageRevisionIdentity.digest(fields.map { "\($0.utf8.count):\($0)" }.joined())
    }
}

struct CycleUsagePage: Decodable, Sendable {
    let events: [CycleUsageEvent]
    let total: Int?
    let hasEvents: Bool
    init(events: [CycleUsageEvent], total: Int?, hasEvents: Bool) { self.events = events; self.total = total; self.hasEvents = hasEvents }
    enum CodingKeys: String, CodingKey { case usageEventsDisplay, totalUsageEventsCount }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total = try c.decodeIfPresent(Int.self, forKey: .totalUsageEventsCount)
        hasEvents = c.contains(.usageEventsDisplay)
        guard hasEvents || total != nil else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Missing history data"))
        }
        events = hasEvents ? try c.decode([CycleUsageEvent].self, forKey: .usageEventsDisplay) : []
    }
    var fingerprint: String { UsageRevisionIdentity.digest(events.map(\.fingerprint).joined(separator: ":")) }
}

struct CycleHistoryPage: Sendable { let page: CycleUsagePage; let byteCount: Int }

enum CycleModelFamily: String, Codable, Sendable { case cursor, other, bot, unknown }
enum CycleAttributionProvenance: String, Codable, Sendable { case serverMembership, boundedCorrection, providerFamily, explicitBot, unknown }
struct CycleModelAttribution: Equatable, Sendable { let family: CycleModelFamily; let provenance: CycleAttributionProvenance }
enum CycleModelClassifier {
    static let version = 1
    static func normalize(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars.map { scalar in
            (65...90).contains(scalar.value) ? Character(UnicodeScalar(scalar.value + 32)!) : Character(scalar)
        })
    }
    static func classify(_ model: String?, serverModels: [String]?) -> CycleModelAttribution {
        guard let model else { return .init(family: .unknown, provenance: .unknown) }
        let name = normalize(model)
        if name.hasPrefix("grok-bot-") { return .init(family: .bot, provenance: .explicitBot) }
        if serverModels?.contains(where: { normalize($0) == name }) == true { return .init(family: .cursor, provenance: .serverMembership) }
        let pattern = #"^(?:(?:cursor-)?grok-4\.(?:5|6|7)|composer-2\.5)(?:-[a-z0-9]+)*$"#
        if name.range(of: pattern, options: .regularExpression) != nil { return .init(family: .cursor, provenance: .boundedCorrection) }
        if ["claude-", "gpt-", "gemini-"].contains(where: { name.hasPrefix($0) && name.count > $0.count }) { return .init(family: .other, provenance: .providerFamily) }
        return .init(family: .unknown, provenance: .unknown)
    }
}

struct CycleCoverage: Codable, Equatable, Sendable {
    var complete: Bool = false
    var pageCount: Int = 0
    var eventCount: Int = 0
    var byteCount: Int = 0
    var oldest: Date? = nil
    var newest: Date? = nil
    var reason: String = "Collecting"
}
enum CycleAmountStatus: String, Codable, Sendable { case estimatedAttribution, unavailable }
struct CycleAmountSnapshot: Codable, Equatable, Sendable {
    let identity: UsageRevisionIdentity
    let capturedAt: Date
    var cursorCents: Decimal = 0
    var otherCents: Decimal = 0
    var botCents: Decimal = 0
    var paidCents: Decimal = 0
    var unknownCents: Decimal = 0
    var unknownCount: Int = 0
    var residualCents: Decimal? = nil
    var coverage: CycleCoverage = .init()
    var status: CycleAmountStatus = .unavailable
    var estimatedCursorLimitCents: Decimal? = nil
    var estimatedOtherLimitCents: Decimal? = nil
    var isCached: Bool = false
    var classifierVersion: Int = CycleModelClassifier.version
    var cursorObservedPlaces: Int = 0
    var otherObservedPlaces: Int = 0
    var provenance: [CycleAttributionProvenance] = []
    var sourceCursorPercent: Double? = nil
    var sourceOtherPercent: Double? = nil
    func amountCents(for pool: UsagePoolID) -> Decimal { pool == .cursor ? cursorCents : otherCents }
    func estimatedLimitCents(for pool: UsagePoolID) -> Decimal? { pool == .cursor ? estimatedCursorLimitCents : estimatedOtherLimitCents }
    static func formattedUSD(cents: Decimal) -> String {
        var dollars = cents / 100, rounded = Decimal()
        NSDecimalRound(&rounded, &dollars, 2, .plain)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .currency; formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2; formatter.maximumFractionDigits = 2
        formatter.positiveFormat = "$#,##0.00"; formatter.negativeFormat = "-$#,##0.00"
        return formatter.string(from: NSDecimalNumber(decimal: rounded)) ?? "$—"
    }
}

enum CycleCollectionStatus: Equatable, Sendable {
    case complete, partial, unstable, transportFailure, endpointFailure, cancelled
    case rateLimited(retryAfter: TimeInterval)
}
struct CycleCollectionResult: Sendable {
    let status: CycleCollectionStatus
    let snapshot: CycleAmountSnapshot?
    let pageCount: Int
    let byteCount: Int
    var supplementarySnapshot: SplitUsageSnapshot? = nil
}

enum CycleEnrichmentError: Error, Sendable {
    case http(status: Int, retryAfter: TimeInterval?)
    case transport
    case invalidResponse
    case payloadBudget
    case oversizedPayload(byteCount: Int)
}
