import Foundation

struct GrokPrepaidLedger: Sendable, Equatable {
    let entries: [GrokPrepaidLedgerEntry]
    let totalCents: Int64?

    static func decodeGRPCWeb(_ data: Data) throws -> GrokPrepaidLedger {
        guard data.count <= 4 * 1024 * 1024 else { throw LedgerDecodingError.responseTooLarge }
        let bytes = Array(data)
        var offset = 0
        let payload = try readFrame(bytes, offset: &offset, expectedFlags: 0)
        let trailers = try readFrame(bytes, offset: &offset, expectedFlags: 0x80)
        guard offset == bytes.count else { throw LedgerDecodingError.invalidFrame }
        try validateTrailers(trailers)

        var reader = LedgerProtobufReader(payload)
        var entries: [GrokPrepaidLedgerEntry] = []
        var totalCents: Int64?
        while let field = try reader.readField() {
            switch field.number {
            case 1: entries.append(try decodeEntry(reader.readMessage(wire: field.wire)))
            case 2: totalCents = try decodeCent(reader.readMessage(wire: field.wire), merging: totalCents)
            default: try reader.skip(wire: field.wire)
            }
        }
        return GrokPrepaidLedger(entries: entries, totalCents: totalCents)
    }

    private static func readFrame(
        _ bytes: [UInt8], offset: inout Int, expectedFlags: UInt8
    ) throws -> ArraySlice<UInt8> {
        guard bytes.count - offset >= 5, bytes[offset] == expectedFlags else {
            throw LedgerDecodingError.invalidFrame
        }
        let length = bytes[(offset + 1)..<(offset + 5)].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        offset += 5
        guard UInt64(length) <= UInt64(bytes.count - offset) else { throw LedgerDecodingError.invalidFrame }
        let end = offset + Int(length)
        defer { offset = end }
        return bytes[offset..<end]
    }

    private static func validateTrailers(_ bytes: ArraySlice<UInt8>) throws {
        guard let text = String(bytes: bytes, encoding: .utf8), text.hasSuffix("\r\n") else {
            throw LedgerDecodingError.invalidTrailers
        }
        var hasStatus = false
        for line in text.components(separatedBy: "\r\n").dropLast() {
            guard let colon = line.firstIndex(of: ":") else { throw LedgerDecodingError.invalidTrailers }
            let name = line[..<colon].lowercased()
            let value = line[line.index(after: colon)...]
            guard !name.isEmpty, name.utf8.allSatisfy({
                (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46 || $0 == 95
            }), value.utf8.allSatisfy({ $0 == 9 || (32...126).contains($0) }) else {
                throw LedgerDecodingError.invalidTrailers
            }
            if name == "grpc-status" {
                guard !hasStatus, value.trimmingCharacters(in: .whitespaces) == "0" else {
                    throw LedgerDecodingError.invalidTrailers
                }
                hasStatus = true
            }
        }
        guard hasStatus else { throw LedgerDecodingError.invalidTrailers }
    }

    private static func decodeEntry(_ bytes: ArraySlice<UInt8>) throws -> GrokPrepaidLedgerEntry {
        var reader = LedgerProtobufReader(bytes)
        var amountCents: Int64?
        var invoiceID: String?
        var invoiceReference: String?
        var timestamp: (seconds: Int64, nanos: Int64)?
        var originRawValue = 0
        var topupStatusRawValue: Int?
        while let field = try reader.readField() {
            switch field.number {
            case 1: amountCents = try decodeCent(reader.readMessage(wire: field.wire), merging: amountCents)
            case 2: invoiceID = try reader.readString(wire: field.wire)
            case 3: invoiceReference = try reader.readString(wire: field.wire)
            case 4: timestamp = try decodeTimestamp(reader.readMessage(wire: field.wire), merging: timestamp)
            case 5: topupStatusRawValue = Int(try reader.readInt64(wire: field.wire))
            case 6: originRawValue = Int(try reader.readInt64(wire: field.wire))
            default: try reader.skip(wire: field.wire)
            }
        }
        return GrokPrepaidLedgerEntry(
            amountCents: amountCents, invoiceID: invoiceID, invoiceReference: invoiceReference,
            createdAt: try timestamp.map(timestampDate),
            originRawValue: originRawValue, topupStatusRawValue: topupStatusRawValue
        )
    }

    private static func decodeCent(_ bytes: ArraySlice<UInt8>, merging existingValue: Int64?) throws -> Int64 {
        var reader = LedgerProtobufReader(bytes)
        var value = existingValue ?? 0
        while let field = try reader.readField() {
            if field.number == 1 {
                value = try reader.readInt64(wire: field.wire)
            } else {
                try reader.skip(wire: field.wire)
            }
        }
        return value
    }

    private static func decodeTimestamp(
        _ bytes: ArraySlice<UInt8>, merging existingValue: (seconds: Int64, nanos: Int64)?
    ) throws -> (seconds: Int64, nanos: Int64) {
        var reader = LedgerProtobufReader(bytes)
        var seconds = existingValue?.seconds ?? 0
        var nanos = existingValue?.nanos ?? 0
        while let field = try reader.readField() {
            switch field.number {
            case 1: seconds = try reader.readInt64(wire: field.wire)
            case 2: nanos = try reader.readInt64(wire: field.wire)
            default: try reader.skip(wire: field.wire)
            }
        }
        return (seconds, nanos)
    }

    // Validate after merging every message instance; only absent timestamps become nil.
    private static func timestampDate(_ timestamp: (seconds: Int64, nanos: Int64)) throws -> Date {
        guard (-62_135_596_800...253_402_300_799).contains(timestamp.seconds),
              (0..<1_000_000_000).contains(timestamp.nanos) else {
            throw LedgerDecodingError.invalidTimestamp
        }
        let interval = Double(timestamp.seconds) + Double(timestamp.nanos) / 1_000_000_000
        guard interval.isFinite else { throw LedgerDecodingError.invalidTimestamp }
        return Date(timeIntervalSince1970: interval)
    }
}

struct GrokPrepaidLedgerEntry: Sendable, Equatable {
    let amountCents: Int64?
    let invoiceID: String?
    let invoiceReference: String?
    let createdAt: Date?
    let originRawValue: Int
    let topupStatusRawValue: Int?
}

private enum LedgerDecodingError: Error {
    case responseTooLarge
    case invalidFrame
    case invalidTrailers
    case invalidProtobuf
    case invalidUTF8
    case invalidTimestamp
}

private struct LedgerProtobufReader {
    private let bytes: ArraySlice<UInt8>
    private var offset: Int

    init(_ bytes: ArraySlice<UInt8>) {
        self.bytes = bytes
        self.offset = bytes.startIndex
    }

    mutating func readField() throws -> (number: UInt64, wire: UInt64)? {
        guard offset < bytes.endIndex else { return nil }
        let tag = try readVarint()
        let number = tag >> 3
        let wire = tag & 7
        guard (1...0x1fff_ffff).contains(number), [0, 1, 2, 5].contains(wire) else {
            throw LedgerDecodingError.invalidProtobuf
        }
        return (number, wire)
    }

    mutating func readInt64(wire: UInt64) throws -> Int64 {
        guard wire == 0 else { throw LedgerDecodingError.invalidProtobuf }
        // Cent.val is int64, not ZigZag-encoded sint64.
        return Int64(bitPattern: try readVarint())
    }

    mutating func readMessage(wire: UInt64) throws -> ArraySlice<UInt8> {
        guard wire == 2 else { throw LedgerDecodingError.invalidProtobuf }
        return try consume(count: readVarint())
    }

    mutating func readString(wire: UInt64) throws -> String {
        guard let string = String(bytes: try readMessage(wire: wire), encoding: .utf8) else {
            throw LedgerDecodingError.invalidUTF8
        }
        return string
    }

    mutating func skip(wire: UInt64) throws {
        switch wire {
        case 0: _ = try readVarint()
        case 1: _ = try consume(count: 8)
        case 2: _ = try readMessage(wire: wire)
        case 5: _ = try consume(count: 4)
        default: throw LedgerDecodingError.invalidProtobuf
        }
    }

    private mutating func readVarint() throws -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<10 {
            guard offset < bytes.endIndex else { throw LedgerDecodingError.invalidProtobuf }
            let byte = bytes[offset]
            offset += 1
            guard index < 9 || byte <= 1 else { throw LedgerDecodingError.invalidProtobuf }
            value |= UInt64(byte & 0x7f) << (index * 7)
            if byte & 0x80 == 0 { return value }
        }
        throw LedgerDecodingError.invalidProtobuf
    }

    private mutating func consume(count: UInt64) throws -> ArraySlice<UInt8> {
        guard count <= UInt64(bytes.endIndex - offset) else { throw LedgerDecodingError.invalidProtobuf }
        let end = offset + Int(count)
        defer { offset = end }
        return bytes[offset..<end]
    }
}
