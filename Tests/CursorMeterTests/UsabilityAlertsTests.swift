import AppKit
import XCTest
@testable import CursorMeter

@MainActor
final class UsabilityAlertsTests: XCTestCase {
    nonisolated private static let preferenceKeys = [
        "splitAlertThresholds", "splitAlertTargets", "warningThreshold", "criticalThreshold"
    ]
    nonisolated(unsafe) private var savedPreferences: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in Self.preferenceKeys {
            savedPreferences[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in Self.preferenceKeys {
            if let value = savedPreferences[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        savedPreferences = [:]
        super.tearDown()
    }

    func testCardsKeepIndependentGaugesAndMasterDoesNotEraseChoices() throws {
        let vm = try makeViewModel()
        vm.splitAlertTargets = [.cursor, .onDemand]
        let vc = SettingsNotificationsTabViewController(viewModel: vm)
        _ = vc.view
        let cursor = try control("Cursor Models alerts", in: vc.view)
        let other = try control("Other Models alerts", in: vc.view)
        let appStatus = try control("App status notifications", in: vc.view)
        XCTAssertEqual(cursor.state, .on)
        XCTAssertEqual(other.state, .off)
        XCTAssertFalse(appStatus.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(visibleSliders(vc.view).count, 2)
        XCTAssertNotNil(slider("Cursor Models thresholds", in: vc.view))
        vm.notificationEnabled = false
        vc.updateUI()
        XCTAssertTrue(visibleSliders(vc.view).isEmpty)
        vm.notificationEnabled = true
        vc.updateUI()
        XCTAssertEqual(cursor.state, .on)
        XCTAssertEqual(other.state, .off)
        XCTAssertEqual(vm.splitAlertTargets, [.cursor, .onDemand])
    }

    func testScopeGaugeEditsOnlyItsPair() throws {
        let vm = try makeViewModel()
        let initialOther = vm.splitThresholds(for: .other)
        let initialPaid = vm.splitThresholds(for: .onDemand)
        let legacyWarning = vm.warningThreshold
        let legacyCritical = vm.criticalThreshold
        let vc = SettingsNotificationsTabViewController(viewModel: vm)
        _ = vc.view
        let cursor = try XCTUnwrap(slider("Cursor Models thresholds", in: vc.view))
        let thumbLabels = cursor.accessibilityChildren()?.compactMap {
            ($0 as? NSAccessibilityElement)?.accessibilityLabel()
        } ?? []
        XCTAssertEqual(thumbLabels, ["Cursor Models warning threshold", "Cursor Models critical threshold"])
        cursor.onChange?(55, 75)
        XCTAssertEqual(vm.splitThresholds(for: .cursor), .init(warning: 55, critical: 75))
        XCTAssertEqual(vm.splitThresholds(for: .other), initialOther)
        XCTAssertEqual(vm.splitThresholds(for: .onDemand), initialPaid)
        XCTAssertEqual(vm.warningThreshold, legacyWarning)
        XCTAssertEqual(vm.criticalThreshold, legacyCritical)
    }

    func testAllCardsAndDeniedPermissionFitShortScreenWithScrolling() async throws {
        _ = NSApplication.shared
        let manager = NotificationManager(requestAuthorization: { false }, deliver: { _ in },
                                          permissionStateProvider: { .denied })
        let vm = try makeViewModel(manager: manager)
        await vm.refreshNotificationPermissionStatus()
        let vc = SettingsNotificationsTabViewController(viewModel: vm, screenHeight: { 681 })
        let window = NSWindow(contentViewController: vc)
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "Synthetic Alerts")
        defer { window.contentViewController = nil; window.close() }
        vc.viewWillAppear()
        window.setContentSize(vc.preferredContentSize)
        vc.view.layoutSubtreeIfNeeded()
        let chrome = window.frame.height - window.contentLayoutRect.height
        XCTAssertLessThanOrEqual(vc.preferredContentSize.height + chrome, 661)
        let scroll = try XCTUnwrap(vc.view as? NSScrollView)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.frame.height, scroll.contentSize.height)
        let last = try control("App status notifications", in: vc.view)
        last.scrollToVisible(last.bounds)
        XCTAssertTrue(scroll.documentVisibleRect.contains(last.convert(last.bounds, to: document)))
    }

    func testScopeSwitchChangesOnlyItsTarget() throws {
        let vm = try makeViewModel()
        vm.splitAlertTargets = [.cursor, .other, .onDemand]
        let thresholds = vm.splitAlertThresholds
        let vc = SettingsNotificationsTabViewController(viewModel: vm)
        _ = vc.view
        let other = try control("Other Models alerts", in: vc.view)
        other.state = .off
        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(other.action), to: other.target, from: other))
        XCTAssertEqual(vm.splitAlertTargets, [.cursor, .onDemand])
        XCTAssertEqual(vm.splitAlertThresholds, thresholds)
        XCTAssertTrue(vm.notificationEnabled)
        XCTAssertEqual(visibleSliders(vc.view).count, 2)
    }

    func testLegacyGaugeKeepsSharedThresholdPath() throws {
        let vm = try makeViewModel()
        let pair = vm.splitThresholds(for: .other)
        vm.splitUsage.reset()
        let vc = SettingsNotificationsTabViewController(viewModel: vm)
        _ = vc.view
        let gauge = try XCTUnwrap(slider("Included usage thresholds", in: vc.view))
        gauge.onChange?(55, 75)
        XCTAssertEqual(vm.warningThreshold, 55)
        XCTAssertEqual(vm.criticalThreshold, 75)
        XCTAssertEqual(vm.splitThresholds(for: .other), pair)
        XCTAssertEqual(visibleSliders(vc.view).count, 1)
    }

    func testIneligiblePaidCardIsHiddenWithoutLosingItsSelection() throws {
        let vm = try makeViewModel()
        vm.splitAlertTargets = [.cursor, .other, .onDemand]
        let vc = SettingsNotificationsTabViewController(viewModel: vm)
        _ = vc.view
        let paid = try control("Paid budget alerts", in: vc.view)
        XCTAssertFalse(paid.isHiddenOrHasHiddenAncestor)
        try publishSplit(to: vm, paid: false)
        vc.updateUI()
        XCTAssertTrue(paid.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(paid.state, .on)
        XCTAssertEqual(visibleSliders(vc.view).count, 2)
        try publishSplit(to: vm, cap: 0)
        vc.updateUI()
        XCTAssertTrue(paid.isHiddenOrHasHiddenAncestor)
    }

    func testPermissionOnlyAppearsWhenDeniedAndCreationDoesNotQueryIt() async throws {
        for state in [NotificationPermissionState.unknown, .notDetermined, .authorized, .provisional, .denied] {
            var queries = 0
            let manager = NotificationManager(requestAuthorization: { false }, deliver: { _ in },
                permissionStateProvider: { queries += 1; return state })
            let vm = try makeViewModel(manager: manager)
            let vc = SettingsNotificationsTabViewController(viewModel: vm)
            _ = vc.view
            XCTAssertEqual(queries, 0)
            await vm.refreshNotificationPermissionStatus()
            vc.updateUI()
            let button = try XCTUnwrap(views(vc.view).compactMap { $0 as? NSButton }.first { $0.title == "Open Settings" })
            XCTAssertEqual(button.isHiddenOrHasHiddenAncestor, state != .denied)
            XCTAssertNotNil(button.action)
            XCTAssertFalse(views(vc.view).compactMap { ($0 as? NSTextField)?.stringValue }
                .contains { $0.hasPrefix("Notification permission:") })
        }
    }

    private func makeViewModel(manager: NotificationManager? = nil) throws -> UsageViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let vm = UsageViewModel(apiClient: CursorAPIClient(configuration: config), notificationManager: manager)
        vm.keychainDeleteHandler = {}
        vm.sessionExpiredNotifier = {}
        vm.notificationEnabled = true
        vm.authState = .loggedIn
        try publishSplit(to: vm)
        return vm
    }

    private func publishSplit(to vm: UsageViewModel, paid: Bool = true, cap: Int = 1000) throws {
        let json = """
        {"billingCycleStart":"2026-09-01T00:00:00Z","billingCycleEnd":"2026-10-01T00:00:00Z","membershipType":"ultra","individualUsage":{"plan":{"enabled":true,"used":18200,"limit":40000,"autoPercentUsed":35,"apiPercentUsed":41},"onDemand":{"enabled":\(paid),"used":200,"limit":\(cap)}}}
        """
        let summary = try JSONDecoder().decode(UsageSummaryResponse.self, from: Data(json.utf8))
        let usage = UsageResponse(models: [:], startOfMonth: nil)
        let user = UserInfoResponse(email: "demo@example.com", name: "Demo User", sub: "synthetic-alerts")
        vm.usageData = UsageDisplayData.from(summary: summary, usage: usage, userInfo: user)
        vm.splitUsage.accept(summary: summary, usage: usage, userInfo: user, generation: 1, enterpriseScope: false)
    }

    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func control(_ label: String, in view: NSView) throws -> NSSwitch {
        try XCTUnwrap(views(view).compactMap { $0 as? NSSwitch }.first { $0.accessibilityLabel() == label })
    }
    private func slider(_ label: String, in view: NSView) -> ThresholdRangeSlider? {
        views(view).compactMap { $0 as? ThresholdRangeSlider }.first { $0.accessibilityLabel() == label }
    }
    private func visibleSliders(_ view: NSView) -> [ThresholdRangeSlider] {
        views(view).compactMap { $0 as? ThresholdRangeSlider }.filter { !$0.isHiddenOrHasHiddenAncestor }
    }
}
