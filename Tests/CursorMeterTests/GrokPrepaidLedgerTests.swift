import XCTest
@testable import CursorMeter

final class GrokPrepaidLedgerTests: XCTestCase {
    func testObservedEmptyResponseHasPresentZeroTotal() throws {
        let bytes: [UInt8] = [
            0, 0, 0, 0, 2, 0x12, 0,
            0x80, 0, 0, 0, 15,
            0x67, 0x72, 0x70, 0x63, 0x2d, 0x73, 0x74, 0x61,
            0x74, 0x75, 0x73, 0x3a, 0x30, 0x0d, 0x0a,
        ]
        let ledger = try GrokPrepaidLedger.decodeGRPCWeb(Data(bytes))
        XCTAssertEqual(ledger.entries, [])
        XCTAssertEqual(ledger.totalCents, 0)
    }

    func testSuccessfulPurchasePreservesSignedAmountAndMetadata() throws {
        let entry = message(1, cent(-500))
            + message(2, Array("invoice-123".utf8))
            + message(3, Array("참조-é".utf8))
            + message(4, scalar(1, 1_800_000_000) + scalar(2, 125_000_000))
            + scalar(5, 5) + scalar(6, 1)
        let ledger = try decode(message(1, entry) + message(2, cent(-420)))
        XCTAssertEqual(ledger.totalCents, -420)
        XCTAssertEqual(ledger.entries, [GrokPrepaidLedgerEntry(
            amountCents: -500,
            invoiceID: "invoice-123",
            invoiceReference: "참조-é",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000.125),
            originRawValue: 1,
            topupStatusRawValue: 5
        )])
    }

    func testAutomaticPurchasePreservesItsDistinctOrigin() throws {
        let ledger = try decode(message(1, message(1, cent(-700)) + scalar(5, 5) + scalar(6, 5)))
        let entry = try XCTUnwrap(ledger.entries.first)
        XCTAssertEqual(entry.amountCents, -700)
        XCTAssertEqual(entry.originRawValue, 5)
        XCTAssertEqual(entry.topupStatusRawValue, 5)
    }

    func testSpendPreservesPositiveAmountAndAbsentStatus() throws {
        let ledger = try decode(message(1, message(1, cent(80)) + scalar(6, 2)))
        let entry = try XCTUnwrap(ledger.entries.first)
        XCTAssertEqual(entry.amountCents, 80)
        XCTAssertEqual(entry.originRawValue, 2)
        XCTAssertNil(entry.topupStatusRawValue)
    }

    func testMissingFieldsRemainAbsentExceptImplicitOrigin() throws {
        let ledger = try decode(message(1, []))
        XCTAssertNil(ledger.totalCents)
        XCTAssertEqual(ledger.entries, [GrokPrepaidLedgerEntry(
            amountCents: nil, invoiceID: nil, invoiceReference: nil,
            createdAt: nil, originRawValue: 0, topupStatusRawValue: nil
        )])
    }

    func testPresentEmptyMessagesAndStringsPreservePresence() throws {
        let entry = message(1, []) + message(2, []) + message(3, [])
            + message(4, []) + scalar(5, 0)
        let ledger = try decode(message(1, entry) + message(2, []))
        XCTAssertEqual(ledger.totalCents, 0)
        XCTAssertEqual(ledger.entries, [GrokPrepaidLedgerEntry(
            amountCents: 0, invoiceID: "", invoiceReference: "",
            createdAt: Date(timeIntervalSince1970: 0), originRawValue: 0, topupStatusRawValue: 0
        )])
    }

    func testUnknownEnumsArePreservedWithoutSuccessDefault() throws {
        let ledger = try decode(message(1, scalar(5, 1234) + scalar(6, 5678))
            + message(1, scalar(5, -1) + scalar(6, -2)))
        XCTAssertEqual(ledger.entries.map(\.topupStatusRawValue), [1234, -1])
        XCTAssertEqual(ledger.entries.map(\.originRawValue), [5678, -2])
    }

    func testSignedCentsCoverInt64BoundariesWithoutNegationOrZigZag() throws {
        let values: [Int64] = [.min, .max, -1, 0, 1]
        for value in values {
            let ledger = try decode(message(1, message(1, cent(value))) + message(2, cent(value)))
            XCTAssertEqual(ledger.totalCents, value)
            XCTAssertEqual(ledger.entries.first?.amountCents, value)
        }
    }

    func testUnknownSupportedWireTypesAreSkippedAtEveryMessageLevel() throws {
        let unknown = scalar(100, 300)
            + tag(101, 1) + Array(repeating: UInt8(0xff), count: 8)
            + message(102, [0xff, 0x00, 0x80])
            + tag(103, 5) + Array(repeating: UInt8(0xff), count: 4)
        let entry = unknown + message(1, unknown + cent(-500))
            + message(4, unknown + scalar(1, 12)) + scalar(6, 1)
        let ledger = try decode(unknown + message(1, entry) + message(2, unknown + cent(-500)))
        XCTAssertEqual(ledger.totalCents, -500)
        XCTAssertEqual(ledger.entries.first?.amountCents, -500)
        XCTAssertEqual(ledger.entries.first?.createdAt, Date(timeIntervalSince1970: 12))
    }

    func testTimestampAcceptsProtobufBoundsAndPositiveNanosBeforeEpoch() throws {
        for seconds: Int64 in [-62_135_596_800, -1, 253_402_300_799] {
            let ledger = try decode(message(1, message(4, scalar(1, seconds) + scalar(2, 999_999_999))))
            let date = try XCTUnwrap(ledger.entries.first?.createdAt)
            XCTAssertTrue(date.timeIntervalSince1970.isFinite)
            XCTAssertEqual(date.timeIntervalSince1970, Double(seconds) + 0.999_999_999, accuracy: 0.000_1)
        }
    }

    func testTimestampRejectsOutOfRangeSeconds() {
        for seconds: Int64 in [-62_135_596_801, 253_402_300_800, .min, .max] {
            XCTAssertThrowsError(try decode(message(1, message(4, scalar(1, seconds)))))
        }
    }

    func testTimestampRejectsInvalidNanos() {
        for nanos: Int64 in [-1, 1_000_000_000, .max] {
            XCTAssertThrowsError(try decode(message(1, message(4, scalar(2, nanos)))))
        }
    }

    func testInvalidUTF8IdentifiersAreRejected() {
        for field in [2, 3] {
            XCTAssertThrowsError(try decode(message(1, message(field, [0xc3, 0x28]))))
        }
    }

    func testTruncatedAndOverflowingVarintsAreRejected() {
        let invalid: [[UInt8]] = [
            [0x80], Array(repeating: 0x80, count: 10),
            Array(repeating: 0xff, count: 9) + [2],
            Array(repeating: 0x80, count: 10) + [0],
        ]
        for bytes in invalid {
            XCTAssertThrowsError(try decode(bytes))
            XCTAssertThrowsError(try decode(message(2, [8] + bytes)))
        }
    }

    func testInvalidFieldTagsAndUnsupportedWireTypesAreRejected() {
        let invalid: [[UInt8]] = [[0], [1], tag(1, 3), tag(1, 4), tag(1, 6), tag(1, 7),
                                  varint(UInt64(1) << 32)]
        for bytes in invalid {
            XCTAssertThrowsError(try decode(bytes))
        }
    }

    func testKnownFieldsRejectWrongWireTypesAtEveryLevel() {
        for field in [1, 2] {
            XCTAssertThrowsError(try decode(scalar(field, 0)))
        }
        for field in [1, 2, 3, 4] {
            XCTAssertThrowsError(try decode(message(1, scalar(field, 0))))
        }
        for field in [5, 6] {
            XCTAssertThrowsError(try decode(message(1, message(field, []))))
        }
        XCTAssertThrowsError(try decode(message(2, message(1, []))))
        for field in [1, 2] {
            XCTAssertThrowsError(try decode(message(1, message(4, message(field, [])))))
        }
    }

    func testInvalidLengthsAndTruncatedUnknownFixedFieldsAreRejected() {
        let invalid: [[UInt8]] = [
            [0x0a, 2, 0], [0x0a, 0x80], [0x0a] + varint(.max),
            tag(100, 1) + [0], tag(100, 5) + [0],
            tag(100, 2) + [2, 0],
        ]
        for bytes in invalid {
            XCTAssertThrowsError(try decode(bytes))
        }
    }

    func testTruncatedGRPCFramesAreRejected() {
        let response = responseBytes(message(2, []))
        for length in 0..<response.count {
            XCTAssertThrowsError(try GrokPrepaidLedger.decodeGRPCWeb(Data(response.prefix(length))))
        }
        XCTAssertThrowsError(try GrokPrepaidLedger.decodeGRPCWeb(Data([0, 0xff, 0xff, 0xff, 0xff])))
    }

    func testCompressedAndUnsupportedGRPCFrameFlagsAreRejected() {
        for flag: UInt8 in [1, 2, 0x7f, 0x81, 0xff] {
            XCTAssertThrowsError(try GrokPrepaidLedger.decodeGRPCWeb(Data(frame(flag, []) + trailer())))
            XCTAssertThrowsError(try GrokPrepaidLedger.decodeGRPCWeb(Data(frame(0, []) + frame(flag, Array("grpc-status:0\r\n".utf8)))))
        }
    }

    func testGRPCRequiresExactlyOneDataFrameThenOneTrailer() {
        let data = frame(0, [])
        let trailers = trailer()
        for bytes in [data, trailers, data + data + trailers, data + trailers + trailers,
                      trailers + data, data + trailers + data, data + trailers + [0]] {
            XCTAssertThrowsError(try GrokPrepaidLedger.decodeGRPCWeb(Data(bytes)))
        }
    }

    func testGRPCRejectsMissingNonzeroMalformedAndDuplicateStatus() {
        for text in ["", "grpc-message:ok\r\n", "grpc-status:7\r\n", "grpc-status:garbage\r\n",
                     "grpc-status:0\r\ngrpc-status:7\r\n", "grpc-status:0\r\ngrpc-status:0\r\n",
                     "grpc-status:0\n", "grpc-status:0\r\ninvalid\r\n"] {
            XCTAssertThrowsError(try GrokPrepaidLedger.decodeGRPCWeb(Data(frame(0, []) + trailer(text))))
        }
        XCTAssertThrowsError(try GrokPrepaidLedger.decodeGRPCWeb(Data(frame(0, []) + frame(0x80, [0xff]))))
    }

    func testGRPCAllowsOtherTrailerMetadataAndWhitespaceAroundZeroStatus() throws {
        let bytes = frame(0, message(2, [])) + trailer("grpc-message:ok\r\ngrpc-status: 0\r\nx-extra:value\r\n")
        XCTAssertEqual(try GrokPrepaidLedger.decodeGRPCWeb(Data(bytes)).totalCents, 0)
    }

    func testInputLargerThanFourMiBIsRejected() {
        XCTAssertThrowsError(try GrokPrepaidLedger.decodeGRPCWeb(Data(repeating: 0, count: 4 * 1024 * 1024 + 1)))
    }

    func testDuplicateEmptyCentMessagesPreserveEarlierAmountAndTotal() throws {
        let entry = message(1, cent(-500)) + message(1, [])
        let ledger = try decode(message(1, entry) + message(2, cent(-420)) + message(2, []))
        XCTAssertEqual(ledger.entries.first?.amountCents, -500)
        XCTAssertEqual(ledger.totalCents, -420)
    }

    func testLaterExplicitZeroCentValuesOverwriteEarlierScalars() throws {
        let entry = message(1, cent(-500)) + message(1, cent(0))
        let ledger = try decode(message(1, entry) + message(2, cent(-420)) + message(2, cent(0)))
        XCTAssertEqual(ledger.entries.first?.amountCents, 0)
        XCTAssertEqual(ledger.totalCents, 0)
    }

    func testDuplicateTimestampMessagesMergeComponentsBeforeValidation() throws {
        let partials = message(4, scalar(1, 1_800_000_000))
            + message(4, scalar(2, 125_000_000)) + message(4, [])
        let replacedInvalid = message(4, scalar(1, .max) + scalar(2, -1))
            + message(4, scalar(1, 1_800_000_000)) + message(4, scalar(2, 125_000_000))
        let expected = Date(timeIntervalSince1970: 1_800_000_000.125)
        XCTAssertEqual(try decode(message(1, partials)).entries.first?.createdAt, expected)
        XCTAssertEqual(try decode(message(1, replacedInvalid)).entries.first?.createdAt, expected)
    }

    private func decode(_ payload: [UInt8]) throws -> GrokPrepaidLedger {
        try GrokPrepaidLedger.decodeGRPCWeb(Data(responseBytes(payload)))
    }

    private func responseBytes(_ payload: [UInt8]) -> [UInt8] {
        frame(0, payload) + trailer()
    }

    private func trailer(_ text: String = "grpc-status:0\r\n") -> [UInt8] {
        frame(0x80, Array(text.utf8))
    }

    private func frame(_ flags: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let length = UInt32(payload.count)
        return [flags, UInt8(truncatingIfNeeded: length >> 24), UInt8(truncatingIfNeeded: length >> 16),
                UInt8(truncatingIfNeeded: length >> 8), UInt8(truncatingIfNeeded: length)] + payload
    }

    private func cent(_ value: Int64) -> [UInt8] {
        scalar(1, value)
    }

    private func scalar(_ field: Int, _ value: Int64) -> [UInt8] {
        tag(field, 0) + varint(UInt64(bitPattern: value))
    }

    private func message(_ field: Int, _ bytes: [UInt8]) -> [UInt8] {
        tag(field, 2) + varint(UInt64(bytes.count)) + bytes
    }

    private func tag(_ field: Int, _ wire: UInt64) -> [UInt8] {
        varint(UInt64(field) << 3 | wire)
    }

    private func varint(_ value: UInt64) -> [UInt8] {
        var remaining = value
        var bytes: [UInt8] = []
        while remaining >= 0x80 {
            bytes.append(UInt8(remaining & 0x7f) | 0x80)
            remaining >>= 7
        }
        bytes.append(UInt8(remaining))
        return bytes
    }
}
