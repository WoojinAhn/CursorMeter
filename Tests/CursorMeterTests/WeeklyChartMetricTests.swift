import XCTest
@testable import CursorMeter

final class WeeklyChartMetricTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var today: Date { Date(timeIntervalSince1970: 1_783_296_000) }

    private func event(
        dayOffset: Int = 0,
        units: Double = 1,
        cents: Double?,
        onDemand: Bool = false
    ) -> UsageEvent {
        let date = calendar.date(byAdding: .day, value: dayOffset, to: today)!
        return UsageEvent(
            timestamp: String(Int(date.timeIntervalSince1970 * 1000)),
            requestsCosts: units,
            kind: onDemand ? "USAGE_EVENT_KIND_USAGE_BASED" : "USAGE_EVENT_KIND_INCLUDED_IN_BUSINESS",
            chargedCents: cents
        )
    }

    func testMetricDefaultsToAmountAndRestoresSavedSelection() {
        XCTAssertEqual(WeeklyChartMetric(storedValue: nil), .amount)
        XCTAssertEqual(WeeklyChartMetric(storedValue: "unknown"), .amount)
        for metric in WeeklyChartMetric.allCases {
            XCTAssertEqual(WeeklyChartMetric(storedValue: metric.rawValue), metric)
        }
    }

    func testSelectedMetricCanReverseDailyRanking() {
        let days = [
            event(dayOffset: -1, units: 100, cents: 400),
            event(units: 150, cents: 300),
        ].sevenDayRolling(today: today, calendar: calendar)
        XCTAssertGreaterThan(WeeklyChartMetric.amount.value(for: days[5])!,
                             WeeklyChartMetric.amount.value(for: days[6])!)
        XCTAssertLessThan(WeeklyChartMetric.usageUnits.value(for: days[5])!,
                          WeeklyChartMetric.usageUnits.value(for: days[6])!)
    }

    func testAmountIncludesPlanAndOnDemandWithFractionalPrecision() {
        let days = [
            event(units: 0.2, cents: 18.17),
            event(units: 0.1, cents: 95.69, onDemand: true),
        ].sevenDayRolling(today: today, calendar: calendar)
        XCTAssertEqual(WeeklyChartMetric.amount.value(for: days[6])!, 113.86, accuracy: 0.000_001)
        XCTAssertEqual(WeeklyChartMetric.usageUnits.value(for: days[6])!, 0.3, accuracy: 0.000_001)
        XCTAssertTrue(days.isAmountAvailable)
    }

    func testExplicitZeroAmountIsAvailable() {
        let days = [event(cents: 0)].sevenDayRolling(today: today, calendar: calendar)
        XCTAssertTrue(days.isAmountAvailable)
        XCTAssertEqual(WeeklyChartMetric.amount.value(for: days[6]), 0)
        XCTAssertEqual(days.effectiveMetric(preferred: .amount), .amount)
    }

    func testMissingOrInvalidAmountDoesNotBecomeZero() {
        for cents in [nil, Double.nan, Double.infinity] as [Double?] {
            let days = [event(cents: cents)].sevenDayRolling(today: today, calendar: calendar)
            XCTAssertNil(WeeklyChartMetric.amount.value(for: days[6]))
            XCTAssertFalse(days.isAmountAvailable)
            XCTAssertEqual(days.effectiveMetric(preferred: .amount), .usageUnits)
        }
    }

    func testPartiallyMissingAmountFallsBackForEntireWeek() {
        let days = [
            event(dayOffset: -1, cents: 100),
            event(cents: 30),
            event(cents: nil),
        ].sevenDayRolling(today: today, calendar: calendar)
        XCTAssertEqual(WeeklyChartMetric.amount.value(for: days[5]), 100)
        XCTAssertNil(WeeklyChartMetric.amount.value(for: days[6]))
        XCTAssertEqual(days.effectiveMetric(preferred: .amount), .usageUnits)
    }

    func testEmptySuccessfulWeekHasKnownZeroAmount() {
        let days = [UsageEvent]().sevenDayRolling(today: today, calendar: calendar)
        XCTAssertTrue(days.isAmountAvailable)
        XCTAssertTrue(days.allSatisfy { WeeklyChartMetric.amount.value(for: $0) == 0 })
        XCTAssertEqual(days.effectiveMetric(preferred: .amount), .amount)
        XCTAssertFalse([DayUsage]().isAmountAvailable)
    }

    func testExplicitUsageSelectionSurvivesAmountAvailability() {
        let days = [event(cents: 100)].sevenDayRolling(today: today, calendar: calendar)
        XCTAssertEqual(days.effectiveMetric(preferred: .usageUnits), .usageUnits)
    }

    func testMissingAmountOutsideWindowDoesNotDisableAmount() {
        let days = [event(dayOffset: -7, cents: nil), event(cents: 100)]
            .sevenDayRolling(today: today, calendar: calendar)
        XCTAssertTrue(days.isAmountAvailable)
    }
}
