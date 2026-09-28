import XCTest
@testable import CursorMeter

@MainActor
final class UsagePreferenceRevisionTests: XCTestCase {
    private let preferenceKeys = [
        "popoverValueMode", "estimatedLimitsEnabled", "estimateExplanationSeen",
        "splitAlertThresholds", "warningThreshold", "criticalThreshold", "splitAlertTargets"
    ]

    private func withCleanPreferences(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.standard
        let saved = Dictionary(uniqueKeysWithValues: preferenceKeys.map { ($0, defaults.object(forKey: $0)) })
        for key in preferenceKeys { defaults.removeObject(forKey: key) }
        defer {
            for key in preferenceKeys {
                if let value = saved[key] ?? nil { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        try body()
    }

    func testDisplayDefaultsAndPersistenceAreIndependentOfAlertSettings() {
        withCleanPreferences {
            let vm = UsageViewModel()
            XCTAssertEqual(vm.popoverValueMode, .both)
            XCTAssertFalse(vm.estimatedLimitsEnabled)
            XCTAssertFalse(vm.estimateExplanationSeen)
            let original = vm.splitThresholds(for: .other)
            vm.setPopoverValueMode(.dollars)
            vm.setEstimatedLimitsEnabled(true)
            vm.markEstimateExplanationSeen()
            let restored = UsageViewModel()
            XCTAssertEqual(restored.popoverValueMode, .dollars)
            XCTAssertTrue(restored.estimatedLimitsEnabled)
            XCTAssertTrue(restored.estimateExplanationSeen)
            XCTAssertEqual(restored.splitThresholds(for: .other), original)
        }
    }

    func testExistingSharedThresholdsMigrateOnceToIndependentScopes() {
        withCleanPreferences {
            let defaults = UserDefaults.standard
            defaults.set(60, forKey: "warningThreshold")
            defaults.set(85, forKey: "criticalThreshold")
            defaults.set(["cursor"], forKey: "splitAlertTargets")
            let vm = UsageViewModel()
            for scope in [SplitAlertScope.cursor, .other, .onDemand] {
                XCTAssertEqual(vm.splitThresholds(for: scope), SplitAlertThresholds(warning: 60, critical: 85))
            }
            XCTAssertEqual(vm.splitAlertTargets, [.cursor])
            vm.setSplitCriticalThreshold(90, for: .cursor)
            vm.setSplitWarningThreshold(65, for: .cursor)
            vm.setWarningThreshold(70)
            let restored = UsageViewModel()
            XCTAssertEqual(restored.splitThresholds(for: .cursor), SplitAlertThresholds(warning: 65, critical: 90))
            XCTAssertEqual(restored.splitThresholds(for: .other), SplitAlertThresholds(warning: 60, critical: 85))
            XCTAssertEqual(restored.splitThresholds(for: .onDemand), SplitAlertThresholds(warning: 60, critical: 85))
            XCTAssertEqual(restored.warningThreshold, 70)
            XCTAssertEqual(restored.splitAlertTargets, [.cursor])
        }
    }

    func testEstimateToggleDoesNotResetDisplayOrAcknowledgement() {
        withCleanPreferences {
            let vm = UsageViewModel()
            vm.setPopoverValueMode(.percent)
            vm.markEstimateExplanationSeen()
            vm.setEstimatedLimitsEnabled(true)
            vm.setEstimatedLimitsEnabled(false)
            let restored = UsageViewModel()
            XCTAssertEqual(restored.popoverValueMode, .percent)
            XCTAssertFalse(restored.estimatedLimitsEnabled)
            XCTAssertTrue(restored.estimateExplanationSeen)
        }
    }

    func testMalformedScopeDoesNotDiscardAnotherSavedPair() {
        withCleanPreferences {
            let defaults = UserDefaults.standard
            defaults.set(60, forKey: "warningThreshold")
            defaults.set(85, forKey: "criticalThreshold")
            defaults.set(["cursor": ["warning": 30, "critical": 50], "other": "invalid"],
                         forKey: "splitAlertThresholds")
            let vm = UsageViewModel()
            XCTAssertEqual(vm.splitThresholds(for: .cursor), SplitAlertThresholds(warning: 30, critical: 50))
            XCTAssertEqual(vm.splitThresholds(for: .other), SplitAlertThresholds(warning: 60, critical: 85))
            vm.setSplitThresholds(SplitAlertThresholds(warning: 90, critical: 95), for: .included)
            XCTAssertNil(vm.splitAlertThresholds[.included])
        }
    }
}
