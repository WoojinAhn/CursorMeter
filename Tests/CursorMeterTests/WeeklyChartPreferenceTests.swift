import XCTest
@testable import CursorMeter

@MainActor
final class WeeklyChartPreferenceTests: XCTestCase {
    private func withSavedPreference(_ body: () -> Void) {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: "weeklyChartMetric")
        defer { defaults.set(previous, forKey: "weeklyChartMetric") }
        defaults.removeObject(forKey: "weeklyChartMetric")
        body()
    }

    func testDefaultAndInvalidPreferenceUseAmount() {
        withSavedPreference {
            XCTAssertEqual(UsageViewModel().weeklyChartMetric, .amount)
            UserDefaults.standard.set("unknown", forKey: "weeklyChartMetric")
            XCTAssertEqual(UsageViewModel().weeklyChartMetric, .amount)
        }
    }

    func testSelectionPersistsAcrossViewModels() {
        withSavedPreference {
            let vm = UsageViewModel()
            vm.setWeeklyChartMetric(.usageUnits)
            XCTAssertEqual(UsageViewModel().weeklyChartMetric, .usageUnits)
            vm.setWeeklyChartMetric(.amount)
            XCTAssertEqual(UsageViewModel().weeklyChartMetric, .amount)
        }
    }

    func testUnavailableAmountFallsBackWithoutOverwritingPreference() {
        withSavedPreference {
            let vm = UsageViewModel()
            let now = Date()
            let timestamp = String(Int(now.timeIntervalSince1970 * 1000))
            vm.weeklyData = [UsageEvent(timestamp: timestamp, requestsCosts: 1, chargedCents: nil)]
                .sevenDayRolling(today: now)
            XCTAssertEqual(vm.effectiveWeeklyChartMetric, .usageUnits)
            XCTAssertEqual(vm.weeklyChartMetric, .amount)
            vm.weeklyData = [UsageEvent(timestamp: timestamp, requestsCosts: 1, chargedCents: 0)]
                .sevenDayRolling(today: now)
            XCTAssertEqual(vm.effectiveWeeklyChartMetric, .amount)
            XCTAssertEqual(UsageViewModel().weeklyChartMetric, .amount)
        }
    }
}
