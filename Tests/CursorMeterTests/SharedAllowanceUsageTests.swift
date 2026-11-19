import XCTest
@testable import CursorMeter

final class SharedAllowanceUsageTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)
    private var now: Date { start.addingTimeInterval(100) }
    private var cycle: UsageCycle { UsageCycle(start: start, end: start.addingTimeInterval(604800))! }
    private func calibration(_ percent: Double = 12.5, tokens: Int = 50_000_000) -> SharedAllowanceCalibration? {
        .init(weekly: .init(percentUsed: percent, period: cycle), includedTokens: tokens, through: now, confirmedAt: now)
    }
    private func entry(_ tokens: Int?, kind: RecentUsageKind = .included, date: Date? = nil) -> RecentUsageEntry {
        .init(date: date ?? now, model: nil, kind: kind, tokens: tokens, chargedCents: nil)
    }

    func testWholePeriodIncludedTokensCalibrateWeeklyCapacityAndRequestPoints() throws {
        let value = try XCTUnwrap(calibration())
        XCTAssertEqual(value.estimatedCapacity, 400_000_000)
        XCTAssertEqual(try XCTUnwrap(value.percentagePoints(for: entry(200_000))), 0.05, accuracy: 0.000001)
        XCTAssertEqual(value.detail(for: entry(200_000)), "≈0.050 pp")
        XCTAssertEqual(value.detail(for: entry(1)), "≈<0.001 pp")
        XCTAssertEqual(value.detail(for: entry(0)), "≈0.000 pp")
    }

    func testInvalidCalibrationAndIneligibleRowsRemainUnknown() throws {
        for percent in [0, 0.0999, 100, -1, Double.nan, Double.infinity] {
            XCTAssertNil(calibration(percent))
        }
        for tokens in [0, -1, SharedActivityValue.maximumTokens + 1] { XCTAssertNil(calibration(tokens: tokens)) }
        let value = try XCTUnwrap(calibration())
        for item in [entry(nil), entry(-1), entry(50_000_001), entry(1, kind: .additionalUsage),
                     entry(1, kind: .free), entry(1, date: start.addingTimeInterval(-1)), entry(1, date: now.addingTimeInterval(1))] {
            XCTAssertNil(value.detail(for: item))
        }
        XCTAssertFalse(value.isCurrent(matching: .init(percentUsed: 13, period: cycle), at: now))
        XCTAssertFalse(value.isCurrent(matching: value.weekly, at: cycle.end))
        XCTAssertFalse(value.isCurrent(matching: nil, at: now))
    }

    func testObservedChangeIsPositiveAccountWideIntervalOnly() throws {
        let previous = SharedAllowanceObservation(weekly: .init(percentUsed: 12.5, period: cycle), at: now)
        let later = SharedAllowanceObservation(weekly: .init(percentUsed: 12.8, period: cycle), at: now.addingTimeInterval(60), previous: previous)
        XCTAssertEqual(try XCTUnwrap(later?.change?.percentagePoints), 0.3, accuracy: 0.000001)
        XCTAssertEqual(later?.change?.start, now)
        XCTAssertEqual(later?.change?.end, now.addingTimeInterval(60))
        for percent in [12.5, 12.4] {
            XCTAssertNil(SharedAllowanceObservation(weekly: .init(percentUsed: percent, period: cycle), at: now.addingTimeInterval(60), previous: previous)?.change)
        }
        let other = UsageCycle(start: start.addingTimeInterval(1), end: cycle.end)!
        XCTAssertNil(SharedAllowanceObservation(weekly: .init(percentUsed: 13, period: other), at: now.addingTimeInterval(60), previous: previous)?.change)
        XCTAssertNil(SharedAllowanceObservation(weekly: .init(percentUsed: nil, period: cycle), at: now))
        XCTAssertNil(SharedAllowanceObservation(weekly: .init(percentUsed: 13, period: cycle), at: cycle.end))
    }
}
