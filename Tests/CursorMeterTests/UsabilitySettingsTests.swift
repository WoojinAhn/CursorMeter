import AppKit
import XCTest
@testable import CursorMeter

@MainActor
final class UsabilitySettingsTests: XCTestCase {
    private var savedDefaults: [String: Any] = [:]
    private let preferenceKeys = ["popoverValueMode", "estimatedLimitsEnabled", "estimateExplanationSeen", "usageSummarySelected"]

    override func setUp() async throws {
        _ = NSApplication.shared
        for key in preferenceKeys { savedDefaults[key] = UserDefaults.standard.object(forKey: key) }
    }

    override func tearDown() async throws {
        for key in preferenceKeys {
            if let saved = savedDefaults[key] { UserDefaults.standard.set(saved, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    func testUsageOpensRecentWithoutRetiredSummaryAndRetainsTimezone() throws {
        UserDefaults.standard.set(true, forKey: "usageSummarySelected")
        let vc = SettingsUsageTabViewController(viewModel: makeViewModel())
        _ = vc.view
        vc.updateUI()
        let controls = views(vc.view).compactMap { $0 as? NSSegmentedControl }
        XCTAssertNil(controls.first { $0.accessibilityLabel() == "Usage view" })
        let zone = try XCTUnwrap(controls.first { $0.accessibilityLabel() == "Time zone" })
        XCTAssertEqual(zone.label(forSegment: 0), "Local")
        XCTAssertEqual(zone.label(forSegment: 1), "UTC")
        XCTAssertNotNil(views(vc.view).first { $0 is NSTableView })
        XCTAssertNil(views(vc.view).first { $0.accessibilityLabel() == "Cycle usage summary" })
        XCTAssertEqual(vc.view.fittingSize.width, 440, accuracy: 1)
    }

    func testSplitDisplayHidesLegacyRowsAndPreservesSegmentedControls() throws {
        let vm = makeViewModel()
        try publishSplit(to: vm)
        let vc = SettingsAppearanceTabViewController(viewModel: vm)
        _ = vc.view
        let legacy = try XCTUnwrap(views(vc.view).first { $0.accessibilityLabel() == "Legacy usage text" })
        XCTAssertTrue(legacy.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(visibleLabels(vc.view).contains("On hover"))
        let controls = views(vc.view).compactMap { $0 as? NSSegmentedControl }
        let values = try XCTUnwrap(controls.first { $0.accessibilityLabel() == "Popover values" })
        XCTAssertEqual((0..<values.segmentCount).map { values.label(forSegment: $0) ?? "" }, ["%", "$", "Both"])
        XCTAssertTrue(controls.contains { $0.label(forSegment: 0) == "Quiet" && $0.label(forSegment: 2) == "Bold" })
        XCTAssertTrue(controls.contains { $0.label(forSegment: 0) == "⚡ 🚀" && $0.label(forSegment: 1) == "💲 💸" })
        XCTAssertNotNil(views(vc.view).first { $0.accessibilityLabel() == "About estimated limits" })
    }

    func testValuePreferencesDefaultToBothAndEstimatesOff() throws {
        UserDefaults.standard.removeObject(forKey: "popoverValueMode")
        UserDefaults.standard.removeObject(forKey: "estimatedLimitsEnabled")
        let vm = makeViewModel()
        try publishSplit(to: vm)
        let vc = SettingsAppearanceTabViewController(viewModel: vm)
        _ = vc.view
        let values = try XCTUnwrap(views(vc.view).compactMap { $0 as? NSSegmentedControl }
            .first { $0.accessibilityLabel() == "Popover values" })
        let estimates = try XCTUnwrap(views(vc.view).compactMap { $0 as? NSSwitch }
            .first { $0.accessibilityLabel() == "Show estimated limits" })
        XCTAssertEqual(values.selectedSegment, PopoverValueMode.both.rawValue)
        XCTAssertEqual(estimates.state, .off)
        values.selectedSegment = PopoverValueMode.dollars.rawValue
        NSApp.sendAction(try XCTUnwrap(values.action), to: values.target, from: values)
        XCTAssertEqual(vm.popoverValueMode, .dollars)
    }

    func testUnsupportedAccountsHideDollarControlsButCreditPlansKeepThem() throws {
        for (limit, percent, expectedDollarControl) in [(0, 24, false), (0, 0, false), (10000, 24, true)] {
            let vm = makeViewModel()
            let json = "{\"individualUsage\":{\"plan\":{\"used\":2400,\"limit\":\(limit),\"totalPercentUsed\":\(percent)}}}"
            let summary = try JSONDecoder().decode(UsageSummaryResponse.self, from: Data(json.utf8))
            vm.usageData = UsageDisplayData.from(summary: summary,
                usage: UsageResponse(models: [:], startOfMonth: nil),
                userInfo: UserInfoResponse(email: "demo@example.com", name: "Demo User", sub: "synthetic-settings"))
            let vc = SettingsAppearanceTabViewController(viewModel: vm)
            _ = vc.view
            let values = try XCTUnwrap(views(vc.view).first { $0.accessibilityLabel() == "Popover values" })
            XCTAssertEqual(!values.isHiddenOrHasHiddenAncestor, expectedDollarControl)
            let estimates = try XCTUnwrap(views(vc.view).first { $0.accessibilityLabel() == "Show estimated limits" })
            XCTAssertTrue(estimates.isHiddenOrHasHiddenAncestor)
            let placement = try XCTUnwrap(views(vc.view).first { $0.accessibilityLabel() == "Outer ring" })
            XCTAssertTrue(placement.isHiddenOrHasHiddenAncestor)
        }
    }

    func testBoldExplanationOnlyAppearsForEnabledBold() {
        let vm = makeViewModel()
        let vc = SettingsAppearanceTabViewController(viewModel: vm)
        _ = vc.view
        for intensity in [JumpIntensity.quiet, .normal, .bold] {
            vm.jumpEffectEnabled = true
            vm.jumpIntensity = intensity
            vc.updateUI()
            XCTAssertEqual(visibleLabels(vc.view).contains("Large jumps also send a notification."), intensity == .bold)
        }
        vm.jumpEffectEnabled = false
        vc.updateUI()
        XCTAssertFalse(visibleLabels(vc.view).contains("Large jumps also send a notification."))
    }

    func testRequestPlanWithActivePaidUsageCanChangeItsDollarMode() throws {
        let vm = makeViewModel()
        vm.usageData = UsageDisplayData(email: "demo@example.com", name: "Demo User", membershipType: "pro",
            planUsedCents: nil, planLimitCents: nil, serverPercentUsed: nil, requestsUsed: 501, requestsLimit: 500,
            onDemandUsedCents: 200, onDemandLimitCents: 1000, onDemandEnabled: true, isOnDemandActive: true,
            cycleStartDate: nil, resetDate: nil)
        vm.setPopoverValueMode(.percent)
        let vc = SettingsAppearanceTabViewController(viewModel: vm)
        _ = vc.view
        let values = try XCTUnwrap(views(vc.view).compactMap { $0 as? NSSegmentedControl }
            .first { $0.accessibilityLabel() == "Popover values" })
        XCTAssertFalse(values.isHiddenOrHasHiddenAncestor)
        values.selectedSegment = PopoverValueMode.dollars.rawValue
        NSApp.sendAction(try XCTUnwrap(values.action), to: values.target, from: values)
        XCTAssertEqual(vm.popoverValueMode, .dollars)
        XCTAssertTrue(visibleLabels(vc.view).contains("$2.00 / $10.00"))
    }

    func testFailedHelpPresentationDoesNotConsumeFirstEnable() throws {
        UserDefaults.standard.set(false, forKey: "estimatedLimitsEnabled")
        UserDefaults.standard.set(false, forKey: "estimateExplanationSeen")
        let vm = makeViewModel()
        try publishSplit(to: vm)
        let vc = SettingsAppearanceTabViewController(viewModel: vm)
        _ = vc.view
        let estimates = try XCTUnwrap(views(vc.view).compactMap { $0 as? NSSwitch }
            .first { $0.accessibilityLabel() == "Show estimated limits" })
        estimates.state = .on
        NSApp.sendAction(try XCTUnwrap(estimates.action), to: estimates.target, from: estimates)
        XCTAssertTrue(vm.estimatedLimitsEnabled)
        XCTAssertFalse(vm.estimateExplanationSeen)
        let help = EstimatedLimitsHelpController()
        var showCount = 0
        help.onShow = { showCount += 1 }
        XCTAssertFalse(help.show(relativeTo: KeyboardAccessibleInfoButton()))
        XCTAssertEqual(showCount, 0)
        XCTAssertFalse(help.isShown)
    }

    func testFirstEnableShowsHelpOnceAndManualHelpRestoresKeyboardFocus() throws {
        UserDefaults.standard.set(false, forKey: "estimatedLimitsEnabled")
        UserDefaults.standard.set(false, forKey: "estimateExplanationSeen")
        let vm = makeViewModel()
        try publishSplit(to: vm)
        let vc = SettingsAppearanceTabViewController(viewModel: vm)
        let window = NSWindow(contentViewController: vc)
        window.isReleasedWhenClosed = false
        window.setContentSize(vc.preferredContentSize)
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFront(nil)
        vc.view.layoutSubtreeIfNeeded()
        let help = vc.testHook_estimateHelp()
        defer {
            if help.isShown { help.cancelOperation(nil) }
            window.contentViewController = nil
            window.close()
        }
        let estimates = try XCTUnwrap(views(vc.view).compactMap { $0 as? NSSwitch }
            .first { $0.accessibilityLabel() == "Show estimated limits" })
        let info = try XCTUnwrap(views(vc.view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "About estimated limits" })
        var showCount = 0
        let originalOnShow = help.onShow
        help.onShow = { showCount += 1; originalOnShow?() }
        estimates.state = .on
        NSApp.sendAction(try XCTUnwrap(estimates.action), to: estimates.target, from: estimates)
        XCTAssertTrue(help.isShown)
        XCTAssertTrue(vm.estimateExplanationSeen)
        XCTAssertEqual(showCount, 1)
        help.cancelOperation(nil)
        XCTAssertFalse(help.isShown)
        XCTAssertTrue(window.firstResponder === info)
        for state in [NSControl.StateValue.off, .on] {
            estimates.state = state
            NSApp.sendAction(try XCTUnwrap(estimates.action), to: estimates.target, from: estimates)
        }
        XCTAssertFalse(help.isShown)
        XCTAssertEqual(showCount, 1)
        XCTAssertTrue(info.acceptsFirstResponder)
        NSApp.sendAction(try XCTUnwrap(info.action), to: info.target, from: info)
        XCTAssertTrue(help.isShown)
        XCTAssertEqual(showCount, 2)
        let close = try XCTUnwrap(views(help.view).compactMap { $0 as? NSButton }.first { $0.title == "Close" })
        NSApp.sendAction(try XCTUnwrap(close.action), to: close.target, from: close)
        XCTAssertFalse(help.isShown)
        XCTAssertTrue(window.firstResponder === info)
        let destination = KeyboardAccessibleInfoButton()
        vc.view.addSubview(destination)
        window.makeFirstResponder(destination)
        help.popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        XCTAssertTrue(window.firstResponder === destination)
    }

    func testDisplayFittingRemainsWithinSmallScreenAndHelpFits() throws {
        let vm = makeViewModel()
        try publishSplit(to: vm)
        vm.jumpEffectEnabled = true
        vm.jumpIntensity = .bold
        let vc = SettingsAppearanceTabViewController(viewModel: vm, screenHeight: { 640 })
        _ = vc.view
        vc.viewWillAppear()
        XCTAssertEqual(vc.preferredContentSize.width, 440)
        XCTAssertLessThanOrEqual(vc.preferredContentSize.height, 620)
        let help = EstimatedLimitsHelpController()
        _ = help.view
        let window = NSWindow(contentViewController: help)
        window.isReleasedWhenClosed = false
        window.setContentSize(help.preferredContentSize)
        help.view.layoutSubtreeIfNeeded()
        defer { window.contentViewController = nil; window.close() }
        XCTAssertEqual(help.view.fittingSize.width, 320, accuracy: 1)
        for label in views(help.view).compactMap({ $0 as? NSTextField }) {
            XCTAssertTrue(help.view.bounds.contains(label.convert(label.bounds, to: help.view)))
            XCTAssertLessThanOrEqual(try XCTUnwrap(label.cell).cellSize(forBounds: label.bounds).height,
                                    label.bounds.height + 1)
        }
    }

    private func makeViewModel() -> UsageViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let vm = UsageViewModel(apiClient: CursorAPIClient(configuration: config))
        vm.updateCheckRunner = { .upToDate }
        vm.notificationEnabled = false
        vm.keychainDeleteHandler = {}
        vm.sessionExpiredNotifier = {}
        vm.authState = .loggedIn
        return vm
    }

    private func publishSplit(to vm: UsageViewModel) throws {
        let json = #"{"billingCycleStart":"2026-09-01T00:00:00Z","billingCycleEnd":"2026-10-01T00:00:00Z","membershipType":"ultra","individualUsage":{"plan":{"enabled":true,"used":18200,"limit":40000,"autoPercentUsed":35,"apiPercentUsed":41}}}"#
        let summary = try JSONDecoder().decode(UsageSummaryResponse.self, from: Data(json.utf8))
        let usage = UsageResponse(models: [:], startOfMonth: nil)
        let user = UserInfoResponse(email: "demo@example.com", name: "Demo User", sub: "synthetic-settings")
        vm.usageData = UsageDisplayData.from(summary: summary, usage: usage, userInfo: user)
        vm.splitUsage.accept(summary: summary, usage: usage, userInfo: user, generation: 1, enterpriseScope: false)
    }

    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func visibleLabels(_ view: NSView) -> [String] {
        views(view).filter { !$0.isHiddenOrHasHiddenAncestor }.compactMap { ($0 as? NSTextField)?.stringValue }
    }
}
