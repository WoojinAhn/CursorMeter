import XCTest
@testable import CursorMeter

final class CycleUsageFingerprintTests: XCTestCase {
    func testEquivalentNumericTimestampSpellingsHaveSameFingerprint() {
        let reference = event("2000").fingerprint
        for timestamp in ["2000.0", "2000.000", "2e3", "2.000E+3"] {
            XCTAssertEqual(event(timestamp).fingerprint, reference, timestamp)
        }
    }

    func testExactTimestampsBeyondDoublePrecisionHaveDifferentFingerprints() {
        let first = "9007199254740992"
        let second = "9007199254740993"
        XCTAssertEqual(Double(first), Double(second), "The fixture must expose Double precision loss")
        XCTAssertNotEqual(event(first).fingerprint, event(second).fingerprint)
        XCTAssertEqual(event(first).fingerprint, event(first + ".0").fingerprint)
    }

    func testExactFractionalTimestampsHaveDifferentFingerprints() {
        let first = "2000.123456789123456789"
        let second = "2000.123456789123456788"
        XCTAssertEqual(Double(first), Double(second))
        XCTAssertNotEqual(event(first).fingerprint, event(second).fingerprint)
    }

    func testMalformedTimestampRemainsRawInsteadOfAcceptingNumericPrefix() {
        XCTAssertNotEqual(event("2000suffix").fingerprint, event("2000").fingerprint)
        XCTAssertNotEqual(event("2000suffix").fingerprint, event("2000other").fingerprint)
        XCTAssertEqual(event("malformed").fingerprint, event("malformed").fingerprint)
        XCTAssertNotEqual(event("NaN").fingerprint, event("nan").fingerprint)
    }

    private func event(_ timestamp: String) -> CycleUsageEvent {
        .init(timestamp: timestamp, model: "composer-2.5", kind: "USAGE_EVENT_KIND_INCLUDED_IN_ULTRA", chargedCents: 1)
    }
}
