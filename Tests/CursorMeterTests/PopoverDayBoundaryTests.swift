import XCTest
@testable import CursorMeter

final class PopoverDayBoundaryTests: XCTestCase {
    func testSharedPopoverRedrawsAtBothUTCAndKSTMidnights() throws {
        var clock = date("2026-11-19T14:59:59Z")
        for expected in ["2026-11-19T15:00:00Z", "2026-11-20T00:00:00Z", "2026-11-20T15:00:00Z"] {
            let next = try XCTUnwrap(PopoverDayBoundary.next(after: clock, sharedWeekly: true))
            XCTAssertEqual(next, date(expected))
            XCTAssertGreaterThan(next, clock)
            clock = next
        }
    }

    func testModeChangeAddsEarlierUTCRefreshAndSwitchingBackRemovesIt() {
        let clock = date("2026-11-19T23:59:59Z")
        XCTAssertEqual(PopoverDayBoundary.next(after: clock, sharedWeekly: false), date("2026-11-20T15:00:00Z"))
        XCTAssertEqual(PopoverDayBoundary.next(after: clock, sharedWeekly: true), date("2026-11-20T00:00:00Z"))
        XCTAssertEqual(PopoverDayBoundary.next(after: clock, sharedWeekly: false), date("2026-11-20T15:00:00Z"))
    }

    func testLegacyBoundaryStaysKSTAcrossUTCMidnight() {
        for clock in [date("2026-11-19T23:59:59Z"), date("2026-11-20T00:00:00Z")] {
            XCTAssertEqual(TodayUsageDay(containing: clock)?.start, date("2026-11-19T15:00:00Z"))
            XCTAssertEqual(PopoverDayBoundary.next(after: clock, sharedWeekly: false), date("2026-11-20T15:00:00Z"))
        }
        XCTAssertNil(PopoverDayBoundary.next(after: Date(timeIntervalSince1970: .nan), sharedWeekly: true))
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
}
