import XCTest
@testable import CursorMeter

@MainActor
final class UpdateCheckerTests: XCTestCase {
    private let checker = UpdateChecker.shared

    func testNewerMajor() {
        XCTAssertTrue(checker.isNewer(remote: "1.0.0", current: "0.1.0"))
    }

    func testNewerMinor() {
        XCTAssertTrue(checker.isNewer(remote: "0.2.0", current: "0.1.0"))
    }

    func testNewerPatch() {
        XCTAssertTrue(checker.isNewer(remote: "0.1.1", current: "0.1.0"))
    }

    func testSameVersion() {
        XCTAssertFalse(checker.isNewer(remote: "0.1.0", current: "0.1.0"))
    }

    func testOlderVersion() {
        XCTAssertFalse(checker.isNewer(remote: "0.1.0", current: "0.2.0"))
    }

    func testMismatchedLength() {
        XCTAssertTrue(checker.isNewer(remote: "1.0", current: "0.9.9"))
        XCTAssertFalse(checker.isNewer(remote: "0.9", current: "0.9.1"))
    }
}
