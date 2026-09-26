import AppKit
import XCTest
@testable import CursorMeter

@MainActor
final class UsabilityPopoverTests: XCTestCase {
    func testEnlargedMeterFitsBesideNamedReadingsAndKeepsActions() throws {
        try withPreferences {
            let vm = try makeViewModel(split: true)
            var recentOpened = false
            let controller = MenuBarPopoverViewController(viewModel: vm, onLogin: {}, onSettings: {}, onRecentUsage: { recentOpened = true })
            _ = controller.view
            controller.updateUI()
            let window = NSWindow(contentViewController: controller)
            window.isReleasedWhenClosed = false
            window.setContentSize(controller.preferredContentSize)
            defer { window.contentViewController = nil; window.close() }
            controller.view.layoutSubtreeIfNeeded()
            let meter = try XCTUnwrap(views(controller.view).compactMap { $0 as? NSImageView }.first { $0.accessibilityLabel() == "Split usage meter" })
            XCTAssertEqual(meter.frame.width, 112, accuracy: 1)
            XCTAssertEqual(meter.frame.height, 112, accuracy: 1)
            XCTAssertEqual(controller.preferredContentSize.width, 300)
            XCTAssertLessThanOrEqual(controller.testHook_contentFittingWidth(), 280)
            XCTAssertTrue((meter.accessibilityValue() as? String)?.contains("Other Models (outer ring): 41%") == true)
            let labels = visibleLabels(controller.view)
            for label in ["Cursor Models", "Other Models", "135.25%", "41%"] { XCTAssertTrue(labels.contains(label), label) }
            for label in views(controller.view).compactMap({ $0 as? NSTextField })
                .filter({ ["Cursor Models", "Other Models"].contains($0.stringValue) }) {
                var parent: NSView? = label
                var geometry: [String] = []
                while let current = parent {
                    geometry.append("\(type(of: current)): \(current.frame)")
                    parent = current.superview
                }
                XCTAssertGreaterThanOrEqual(label.bounds.width, label.intrinsicContentSize.width,
                                            label.stringValue + " " + geometry.joined(separator: " > "))
            }
            XCTAssertFalse(labels.contains { $0.contains("snapshot") || $0.contains("Coverage") || $0.contains("Ready") })
            XCTAssertFalse(views(controller.view).contains { $0 is NSSegmentedControl })
            let buttons = views(controller.view).compactMap { $0 as? NSButton }
            for title in ["Open Dashboard", "Settings...", "Recent usage", "Log Out", "Quit"] { XCTAssertTrue(buttons.contains { $0.title == title }, title) }
            try XCTUnwrap(buttons.first { $0.title == "Recent usage" }).performClick(nil)
            XCTAssertTrue(recentOpened)
            for label in views(controller.view).compactMap({ $0 as? NSTextField }).filter({ !$0.isHiddenOrHasHiddenAncestor }) {
                XCTAssertLessThanOrEqual(label.cell?.cellSize(forBounds: label.bounds).height ?? 0, label.bounds.height + 1, label.stringValue)
            }
        }
    }

    func testEstimateAndTextModesNeverChangeAuthoritativeMeterGeometry() throws {
        try withPreferences {
            let vm = try makeViewModel(split: true)
            let controller = MenuBarPopoverViewController(viewModel: vm, onLogin: {}, onSettings: {})
            _ = controller.view
            controller.updateUI()
            let meter = try XCTUnwrap(views(controller.view).compactMap { $0 as? NSImageView }.first { $0.accessibilityLabel() == "Split usage meter" })
            let original = try XCTUnwrap(meter.image?.tiffRepresentation)
            for mode in PopoverValueMode.allCases {
                vm.setPopoverValueMode(mode)
                vm.setEstimatedLimitsEnabled(true)
                controller.updateUI()
                XCTAssertEqual(meter.image?.tiffRepresentation, original)
                XCTAssertFalse(visibleLabels(controller.view).joined().contains("$400"))
            }
            vm.splitOuterPool = .cursor
            controller.updateUI()
            XCTAssertNotEqual(meter.image?.tiffRepresentation, original)
        }
    }

    func testLegacyCreditUsesRealLimitAndRequestUnitsIgnoreDollarPreference() throws {
        try withPreferences {
            let vm = try makeViewModel(split: false)
            let controller = MenuBarPopoverViewController(viewModel: vm, onLogin: {}, onSettings: {})
            _ = controller.view
            for mode in PopoverValueMode.allCases {
                vm.setPopoverValueMode(mode)
                vm.setEstimatedLimitsEnabled(false)
                controller.updateUI()
                XCTAssertEqual(controller.preferredContentSize.width, 260)
                let labels = visibleLabels(controller.view)
                XCTAssertEqual(labels.contains("$182.00 / $400.00"), mode != .percent)
                XCTAssertEqual(labels.contains("46%"), mode != .dollars)
            }
            vm.usageData = UsageDisplayData(email: "demo@example.com", name: "Demo User", membershipType: "pro", planUsedCents: nil, planLimitCents: nil, serverPercentUsed: nil, requestsUsed: 50, requestsLimit: 500, onDemandUsedCents: nil, onDemandLimitCents: nil, onDemandEnabled: nil, isOnDemandActive: false, cycleStartDate: nil, resetDate: nil)
            vm.setPopoverValueMode(.dollars)
            controller.updateUI()
            XCTAssertTrue(visibleLabels(controller.view).contains("50 / 500"))
            XCTAssertTrue(visibleLabels(controller.view).contains("10%"))
        }
    }

    private func makeViewModel(split: Bool) throws -> UsageViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let vm = UsageViewModel(apiClient: CursorAPIClient(configuration: config))
        vm.authState = .loggedIn
        vm.updateCheckRunner = { .upToDate }
        let json = #"{"billingCycleStart":"2026-09-01T00:00:00Z","billingCycleEnd":"2026-10-01T00:00:00Z","membershipType":"ultra","individualUsage":{"plan":{"enabled":true,"used":18200,"limit":40000,"autoPercentUsed":135.25,"apiPercentUsed":41},"onDemand":{"enabled":false,"used":200,"limit":1000}}}"#
        let summary = try JSONDecoder().decode(UsageSummaryResponse.self, from: Data(json.utf8))
        let usage = UsageResponse(models: [:], startOfMonth: nil)
        let user = UserInfoResponse(email: "demo@example.com", name: "Demo User", sub: "synthetic-usability")
        vm.usageData = UsageDisplayData.from(summary: summary, usage: usage, userInfo: user)
        if split { vm.splitUsage.accept(summary: summary, usage: usage, userInfo: user, generation: 1, enterpriseScope: false) }
        return vm
    }

    private func withPreferences(_ body: () throws -> Void) rethrows {
        _ = NSApplication.shared
        let keys = ["popoverValueMode", "estimatedLimitsEnabled", "splitOuterPool", "splitAlertThresholds"]
        let defaults = UserDefaults.standard
        let saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        keys.forEach { defaults.removeObject(forKey: $0) }
        defer { for key in keys { if let value = saved[key] ?? nil { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        try body()
    }

    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func visibleLabels(_ view: NSView) -> [String] {
        views(view).compactMap { $0 as? NSTextField }.filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.stringValue)
    }
}
