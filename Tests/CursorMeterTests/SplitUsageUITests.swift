import AppKit
import XCTest
@testable import CursorMeter

@MainActor
final class SplitUsageUITests: XCTestCase {
    func testSplitPopoverUsesNamedPoolsAnd300PointsWithoutLegacyDenominator() throws {
        let vm = makeViewModel()
        try publishSplit(to: vm)
        let vc = MenuBarPopoverViewController(viewModel: vm, onLogin: {}, onSettings: {})
        _ = vc.view
        vc.updateUI()
        XCTAssertEqual(vc.preferredContentSize.width, 300)
        let text = labels(vc.view).joined(separator: "\n")
        XCTAssertTrue(text.contains("Cursor Models"))
        XCTAssertTrue(text.contains("Other Models"))
        XCTAssertTrue(text.contains("135%"))
        XCTAssertTrue(text.contains("Paid spending: $2.00"))
        XCTAssertFalse(text.contains("$400.00"))
        let buttons = allViews(vc.view).compactMap { $0 as? NSButton }.map(\.title)
        for title in ["Open Dashboard", "Settings...", "Log Out", "Quit"] {
            XCTAssertTrue(buttons.contains(title))
        }
        XCTAssertLessThanOrEqual(vc.testHook_contentFittingWidth(), 280)
        XCTAssertNotNil(allViews(vc.view).first { $0.accessibilityLabel() == "Usage details" })
    }

    func testSplitCycleWithoutFractionalSecondsKeepsResetCountdownAndTooltip() throws {
        let vm = makeViewModel()
        try publishSplit(to: vm)
        let vc = MenuBarPopoverViewController(viewModel: vm, onLogin: {}, onSettings: {})
        _ = vc.view
        vc.updateUI()
        let reset = try XCTUnwrap(allViews(vc.view).compactMap { $0 as? NSTextField }
            .first { $0.stringValue.hasPrefix("Resets ") })
        XCTAssertFalse(try XCTUnwrap(reset.toolTip).isEmpty)
    }

    func testPartialSummaryKeepsCoverageAndIndependentTimesInScrollableViewport() async throws {
        let controller = SplitUsageController(collect: { snapshot, _, _, _, _ in
            let amounts = CycleAmountSnapshot(
                identity: snapshot.identity, capturedAt: snapshot.capturedAt.addingTimeInterval(-600),
                cursorCents: 1000, otherCents: 2000, botCents: 300, paidCents: 400,
                unknownCents: 50, unknownCount: 1, residualCents: 5,
                coverage: CycleCoverage(complete: false, pageCount: 100, eventCount: 10000),
                status: .unavailable, isCached: true)
            return CycleCollectionResult(status: .partial, snapshot: amounts, pageCount: 100, byteCount: 1000)
        })
        let vm = makeViewModel(splitUsage: controller)
        let summary = try publishSplit(to: vm)
        vm.usageSummarySelected = true
        controller.requestAmounts(summary: summary, cookieHeader: "synthetic")
        for _ in 0..<50 where controller.amountState == .refreshing {
            try await Task.sleep(for: .milliseconds(2))
        }
        let vc = SettingsUsageTabViewController(viewModel: vm)
        _ = vc.view
        vc.updateUI()
        let window = NSWindow(contentViewController: vc)
        window.isReleasedWhenClosed = false
        window.setContentSize(vc.view.fittingSize)
        vc.view.layoutSubtreeIfNeeded()
        defer { window.contentViewController = nil; window.close() }
        let scroll = try XCTUnwrap(allViews(vc.view).compactMap { $0 as? NSScrollView }
            .first { $0.accessibilityLabel() == "Cycle usage summary" })
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertLessThanOrEqual(scroll.frame.height, 340)
        XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height)
        let text = labels(vc.view).joined(separator: "\n")
        for expected in ["Cached", "Partial", "Unknown: $0.50", "Percent refreshed:", "Amount snapshot:", "Reconciliation residual: 5 cents"] {
            XCTAssertTrue(text.contains(expected), expected)
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 100))
        scroll.reflectScrolledClipView(scroll.contentView)
        XCTAssertGreaterThan(scroll.contentView.bounds.origin.y, 0)
    }

    func testPopoverDisplaysPeriodSourceWithItsOwnTimestamp() async throws {
        let vm = try await makePeriodViewModel()
        let vc = MenuBarPopoverViewController(viewModel: vm, onLogin: {}, onSettings: {})
        _ = vc.view
        vc.updateUI()
        XCTAssertTrue(labels(vc.view).contains { $0.contains("Percent source: Current period") })
        XCTAssertTrue(labels(vc.view).contains { $0.contains("Primary summary refreshed:") })
    }

    func testSummaryPausedCaptionsFitAndKeepManualRetryStateVisible() async throws {
        _ = NSApplication.shared
        for sleeping in [false, true] {
            let vm = try await makePausedViewModel(sleeping: sleeping)
            let vc = SettingsUsageTabViewController(viewModel: vm)
            _ = vc.view
            vc.updateUI()
            let window = NSWindow(contentViewController: vc)
            window.isReleasedWhenClosed = false
            window.setContentSize(vc.view.fittingSize)
            vc.view.layoutSubtreeIfNeeded()
            defer { window.contentViewController = nil; window.close() }
            let expected = sleeping ? "Paused while Mac sleeps" : "Auto collection paused · Retry manually"
            let caption = try XCTUnwrap(allViews(vc.view).compactMap { $0 as? NSTextField }
                .first { $0.stringValue == expected })
            XCTAssertFalse(caption.isHiddenOrHasHiddenAncestor)
            XCTAssertTrue(vc.view.bounds.contains(caption.convert(caption.bounds, to: vc.view)))
            let textSize = try XCTUnwrap(caption.cell).cellSize(forBounds: caption.bounds)
            XCTAssertLessThanOrEqual(textSize.height, caption.bounds.height + 1)
            XCTAssertGreaterThan(caption.bounds.width, 0)
            let refresh = try XCTUnwrap(allViews(vc.view).compactMap { $0 as? NSButton }
                .first { $0.accessibilityLabel() == "Refresh cycle amounts" })
            XCTAssertEqual(refresh.isEnabled, !sleeping)
            XCTAssertEqual(vc.view.fittingSize.width, 440, accuracy: 1)
        }
    }

    func testSplitDisplayHonorsPlacementAndKeepsSavedLegacyMode() throws {
        let vm = makeViewModel()
        try publishSplit(to: vm)
        vm.menuBarDisplayMode = 1
        vm.splitOuterPool = .cursor
        let vc = SettingsAppearanceTabViewController(viewModel: vm)
        _ = vc.view
        vc.updateUI()
        let popups = allViews(vc.view).compactMap { $0 as? NSPopUpButton }
        let placement = try XCTUnwrap(popups.first { $0.accessibilityLabel() == "Outer ring" })
        XCTAssertTrue(placement.isEnabled)
        XCTAssertEqual(placement.titleOfSelectedItem, "Cursor Models")
        let legacy = try XCTUnwrap(popups.first { $0.accessibilityLabel() == "Legacy usage text" })
        XCTAssertFalse(legacy.isEnabled)
        XCTAssertEqual(legacy.selectedItem?.tag, 1)
        XCTAssertTrue(labels(vc.view).contains("On hover"))
        XCTAssertTrue(labels(vc.view).contains("Outer: Cursor Models\nCenter: Other Models"))
        XCTAssertEqual(vm.menuBarDisplayMode, 1)
    }

    func testCheckingPoolsAreUnavailableAndLegacyTransitionRestoresWidth() throws {
        let vm = makeViewModel()
        try publishSplit(to: vm, checking: true)
        let vc = MenuBarPopoverViewController(viewModel: vm, onLogin: {}, onSettings: {})
        _ = vc.view
        vc.updateUI()
        XCTAssertEqual(vc.preferredContentSize.width, 300)
        XCTAssertEqual(labels(vc.view).filter { $0 == "Unavailable" }.count, 2)
        vm.splitUsage.reset()
        vc.updateUI()
        XCTAssertEqual(vc.preferredContentSize.width, 260)
        XCTAssertTrue(labels(vc.view).contains { $0.contains("$400.00") })
    }

    func testSplitTargetsPreserveSelectionWhilePaidEligibilityChanges() throws {
        let vm = makeViewModel()
        try publishSplit(to: vm)
        vm.notificationEnabled = true
        vm.splitAlertTargets = [.cursor, .onDemand]
        let vc = SettingsNotificationsTabViewController(viewModel: vm)
        _ = vc.view
        vc.updateUI()
        let buttons = allViews(vc.view).compactMap { $0 as? NSButton }
        let cursor = try XCTUnwrap(buttons.first { $0.title == "Cursor Models" })
        let other = try XCTUnwrap(buttons.first { $0.title == "Other Models" })
        let paid = try XCTUnwrap(buttons.first { $0.title == "Paid budget" })
        XCTAssertTrue(cursor.isEnabled)
        XCTAssertEqual(cursor.state, .on)
        XCTAssertEqual(other.state, .off)
        XCTAssertTrue(paid.isEnabled)
        try publishSplit(to: vm, paidEnabled: false)
        vc.updateUI()
        XCTAssertFalse(paid.isEnabled)
        XCTAssertEqual(paid.state, .on)
        XCTAssertEqual(vm.splitAlertTargets, [.cursor, .onDemand])
    }

    func testSummaryAndRecentSwitchUsesPublishedStateWithoutRequests() throws {
        let vm = makeViewModel()
        try publishSplit(to: vm)
        vm.usageSummarySelected = true
        let vc = SettingsUsageTabViewController(viewModel: vm)
        _ = vc.view
        vc.updateUI()
        let snapshot = vm.splitUsage.snapshot
        let summary = try XCTUnwrap(allViews(vc.view).first { $0.accessibilityLabel() == "Cycle usage summary" })
        let table = try XCTUnwrap(allViews(vc.view).compactMap { $0 as? NSTableView }.first)
        let recentRefresh = try XCTUnwrap(allViews(vc.view).first { $0.accessibilityLabel() == "Refresh recent usage" })
        XCTAssertFalse(summary.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(table.isHiddenOrHasHiddenAncestor)
        vm.usageSummarySelected = false
        vc.updateUI()
        XCTAssertTrue(summary.isHiddenOrHasHiddenAncestor)
        XCTAssertFalse(recentRefresh.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(vm.splitUsage.snapshot, snapshot)
        XCTAssertEqual(vm.splitUsage.amountState, .pending)
    }

    func testOffscreenSplitSurfacesFitAndRenderSyntheticFixtures() async throws {
        _ = NSApplication.shared
        let vm = makeViewModel()
        try publishSplit(to: vm)
        vm.notificationEnabled = true
        vm.usageSummarySelected = true
        let periodVM = try await makePeriodViewModel()
        let pausedVM = try await makePausedViewModel(sleeping: false)
        let sleepingVM = try await makePausedViewModel(sleeping: true)
        let popover = MenuBarPopoverViewController(viewModel: vm, onLogin: {}, onSettings: {})
        let surfaces: [(String, NSViewController)] = [
            ("popover", popover),
            ("popover-period", MenuBarPopoverViewController(viewModel: periodVM, onLogin: {}, onSettings: {})),
            ("display", SettingsAppearanceTabViewController(viewModel: vm)),
            ("display-short", SettingsAppearanceTabViewController(viewModel: vm, screenHeight: { 681 })),
            ("alerts", SettingsNotificationsTabViewController(viewModel: vm)),
            ("summary", SettingsUsageTabViewController(viewModel: vm)),
            ("summary-paused", SettingsUsageTabViewController(viewModel: pausedVM)),
            ("summary-sleeping", SettingsUsageTabViewController(viewModel: sleepingVM)),
        ]
        for (name, controller) in surfaces {
            _ = controller.view
            let popoverController = controller as? MenuBarPopoverViewController
            popoverController?.updateUI()
            let size = popoverController?.preferredContentSize ?? controller.view.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            controller.view.appearance = window.appearance
            window.contentViewController = controller
            window.setContentSize(size)
            controller.view.layoutSubtreeIfNeeded()
            defer { window.contentViewController = nil; window.close() }
            XCTAssertEqual(size.width, popoverController != nil ? 300 : 440, accuracy: 1, name)
            XCTAssertLessThanOrEqual(size.height, (NSScreen.main?.visibleFrame.height ?? 800) - 20, name)
            let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
            window.appearance?.performAsCurrentDrawingAppearance {
                controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            }
            let contents = NSImage(size: controller.view.bounds.size)
            contents.addRepresentation(bitmap)
            let rendered = NSImage(size: controller.view.bounds.size, flipped: false) { rect in
                NSColor.white.setFill()
                rect.fill()
                contents.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                return true
            }
            var png: Data?
            window.appearance?.performAsCurrentDrawingAppearance {
                png = rendered.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
                    .representation(using: .png, properties: [:])
            }
            let data = try XCTUnwrap(png)
            XCTAssertGreaterThan(data.count, 1_000, name)
            if let directory = ProcessInfo.processInfo.environment["CM_UI_ARTIFACT_DIR"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try data.write(to: url.appendingPathComponent("\(name).png"))
            }
        }
    }

    func testDisplayFitsShortScreenAndScrollsToLastControlAfterVisibilityChanges() throws {
        _ = NSApplication.shared
        let vm = makeViewModel()
        try publishSplit(to: vm)
        vm.jumpEffectEnabled = true
        let vc = SettingsAppearanceTabViewController(viewModel: vm, screenHeight: { 681 })
        _ = vc.view
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.toolbar = NSToolbar(identifier: "Synthetic Display")
        window.contentViewController = vc
        defer { window.contentViewController = nil; window.close() }
        vc.viewWillAppear()
        vc.view.layoutSubtreeIfNeeded()
        let chrome = window.frame.height - window.contentLayoutRect.height
        XCTAssertEqual(vc.preferredContentSize.width, 440)
        XCTAssertLessThanOrEqual(vc.preferredContentSize.height + chrome, 661)
        let scroll = try XCTUnwrap(allViews(vc.view).compactMap { $0 as? NSScrollView }.first)
        let document = try XCTUnwrap(scroll.documentView)
        window.setContentSize(vc.preferredContentSize)
        vc.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(document.frame.height, scroll.contentSize.height)
        XCTAssertEqual(scroll.contentView.bounds.minY, 0, accuracy: 1)
        let today = try XCTUnwrap(allViews(document).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "Today" })
        today.scrollToVisible(today.bounds)
        XCTAssertGreaterThan(scroll.contentView.bounds.minY, 0)
        XCTAssertTrue(scroll.documentVisibleRect.contains(today.convert(today.bounds, to: document)))

        vm.jumpEffectEnabled = false
        vm.authState = .loggedOut
        vc.updateUI()
        vc.view.layoutSubtreeIfNeeded()
        XCTAssertLessThan(vc.preferredContentSize.height + chrome, 661)
        vm.jumpEffectEnabled = true
        vm.authState = .loggedIn
        vc.updateUI()
        vc.view.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(vc.preferredContentSize.height + chrome, 661)
        XCTAssertFalse(today.isHiddenOrHasHiddenAncestor)
    }

    func testVisibleSummaryReenablesAmountRefreshWhenCooldownExpires() async throws {
        var now = Date()
        let controller = SplitUsageController(now: { now }, collect: { _, _, _, _, _ in
            CycleCollectionResult(status: .rateLimited(retryAfter: 60), snapshot: nil, pageCount: 1, byteCount: 0)
        })
        let vm = makeViewModel(splitUsage: controller)
        let summary = try publishSplit(to: vm)
        controller.requestAmounts(summary: summary, cookieHeader: "synthetic")
        for _ in 0..<50 where controller.amountState == .refreshing {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(controller.amountState, .failed)
        let vc = SettingsUsageTabViewController(viewModel: vm)
        _ = vc.view
        vc.updateUI()
        vc.viewWillAppear()
        defer { vc.viewDidDisappear() }
        let refresh = try XCTUnwrap(allViews(vc.view).compactMap { $0 as? NSButton }
            .first { $0.accessibilityLabel() == "Refresh cycle amounts" })
        XCTAssertFalse(refresh.isEnabled)
        now = now.addingTimeInterval(61)
        try await Task.sleep(for: .milliseconds(1_200))
        XCTAssertTrue(refresh.isEnabled)
    }

    func testLegacyDisplayKeepsMenuTextAndDisablesPoolPlacement() throws {
        let vm = makeViewModel()
        vm.menuBarDisplayMode = 1
        let vc = SettingsAppearanceTabViewController(viewModel: vm)
        _ = vc.view
        vc.updateUI()
        let placement = try XCTUnwrap(allViews(vc.view).compactMap { $0 as? NSPopUpButton }
            .first { $0.accessibilityLabel() == "Outer ring" })
        XCTAssertFalse(placement.isEnabled)
        let legacy = try XCTUnwrap(allViews(vc.view).compactMap { $0 as? NSPopUpButton }
            .first { $0.accessibilityLabel() == "Legacy usage text" })
        XCTAssertTrue(legacy.isEnabled)
        XCTAssertEqual(legacy.selectedItem?.tag, 1)
        XCTAssertEqual(vm.menuBarDisplayMode, 1)
        XCTAssertTrue(labels(vc.view).contains { $0.contains("Bold notifications are independent") })
    }

    func testAlertsExposeIndependentTargetsAndPermissionWithoutRequestingIt() throws {
        let vm = makeViewModel()
        let vc = SettingsNotificationsTabViewController(viewModel: vm)
        _ = vc.view
        vc.updateUI()
        let targets = allViews(vc.view).compactMap { $0 as? NSButton }
            .filter { ["Cursor Models", "Other Models", "Paid budget"].contains($0.title) }
        XCTAssertEqual(targets.count, 3)
        XCTAssertTrue(targets.allSatisfy { !$0.isEnabled })
        XCTAssertTrue(labels(vc.view).contains { $0.contains("Notification permission:") })
        XCTAssertTrue(labels(vc.view).contains { $0.contains("Bold") && $0.contains("independent") })
    }

    func testUsageHasSummaryRecentSelectionAndRetainsRecentTimezoneAndViewport() throws {
        let vc = SettingsUsageTabViewController(viewModel: makeViewModel())
        _ = vc.view
        vc.updateUI()
        let selectors = allViews(vc.view).compactMap { $0 as? NSSegmentedControl }
        let selector = try XCTUnwrap(selectors.first { $0.accessibilityLabel() == "Usage view" })
        XCTAssertEqual(selector.label(forSegment: 0), "Summary")
        XCTAssertEqual(selector.label(forSegment: 1), "Recent")
        XCTAssertNotNil(selectors.first { $0.accessibilityLabel() == "Time zone" })
        XCTAssertNotNil(allViews(vc.view).compactMap { $0 as? NSTableView }.first)
        XCTAssertNotNil(allViews(vc.view).first { $0.accessibilityLabel() == "Cycle usage summary" })
        XCTAssertEqual(vc.view.fittingSize.width, 440, accuracy: 1)
    }

    private func makeViewModel(splitUsage: SplitUsageController? = nil) -> UsageViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let vm = UsageViewModel(apiClient: CursorAPIClient(configuration: config), splitUsage: splitUsage)
        vm.updateCheckRunner = { .upToDate }
        vm.notificationEnabled = false
        vm.keychainDeleteHandler = {}
        vm.sessionExpiredNotifier = {}
        vm.authState = .loggedIn
        return vm
    }

    private func makePeriodViewModel() async throws -> UsageViewModel {
        let controller = SplitUsageController(collect: { snapshot, _, _, _, publishSupplement in
            var supplemented = snapshot
            supplemented.otherPercent = 41
            supplemented.otherSource = .period
            supplemented.periodCapturedAt = snapshot.capturedAt.addingTimeInterval(-60)
            await publishSupplement(supplemented)
            return CycleCollectionResult(status: .complete, snapshot: nil, pageCount: 1, byteCount: 0,
                                         supplementarySnapshot: supplemented)
        })
        let vm = makeViewModel(splitUsage: controller)
        let summary = try publishSplit(to: vm, otherMissing: true)
        controller.requestAmounts(summary: summary, cookieHeader: "synthetic")
        for _ in 0..<50 where controller.amountState == .refreshing {
            try await Task.sleep(for: .milliseconds(2))
        }
        return vm
    }

    private func makePausedViewModel(sleeping: Bool) async throws -> UsageViewModel {
        var now = Date()
        let controller = SplitUsageController(now: { now }, collect: { snapshot, _, _, _, _ in
            let amounts = CycleAmountSnapshot(
                identity: snapshot.identity, capturedAt: snapshot.capturedAt,
                cursorCents: 1000, otherCents: 2000, botCents: 0, paidCents: 0,
                unknownCents: 0, unknownCount: 0, residualCents: nil,
                coverage: CycleCoverage(complete: false, pageCount: 100, eventCount: 10000),
                status: .unavailable)
            return CycleCollectionResult(status: .partial, snapshot: amounts, pageCount: 100, byteCount: 1000)
        })
        let vm = makeViewModel(splitUsage: controller)
        vm.usageSummarySelected = true
        let summary = try publishSplit(to: vm)
        controller.requestAmounts(summary: summary, cookieHeader: "synthetic")
        for _ in 0..<50 where controller.amountState == .refreshing {
            try await Task.sleep(for: .milliseconds(2))
        }
        now = now.addingTimeInterval(61)
        if sleeping { controller.prepareForSleep() }
        return vm
    }

    @discardableResult
    private func publishSplit(to vm: UsageViewModel, checking: Bool = false, paidEnabled: Bool = true,
                              otherMissing: Bool = false) throws -> UsageSummaryResponse {
        let json = #"{"billingCycleStart":"2026-09-01T00:00:00Z","billingCycleEnd":"2026-10-01T00:00:00Z","membershipType":"ultra","individualUsage":{"plan":{"enabled":true,"used":18200,"limit":40000,"autoPercentUsed":135,"apiPercentUsed":41},"onDemand":{"enabled":PAID,"used":200,"limit":1000}}}"#
            .replacingOccurrences(of: "PAID", with: paidEnabled ? "true" : "false")
            .replacingOccurrences(of: #""apiPercentUsed":41"#, with: otherMissing ? #""apiPercentUsed":null"# : #""apiPercentUsed":41"#)
        let summary = try JSONDecoder().decode(UsageSummaryResponse.self, from: Data(json.utf8))
        let usage = UsageResponse(models: [:], startOfMonth: nil)
        let user = UserInfoResponse(email: "demo@example.com", name: "Demo User", sub: "synthetic-ui")
        vm.usageData = UsageDisplayData.from(summary: summary, usage: usage, userInfo: user)
        vm.splitUsage.accept(summary: summary, usage: checking ? nil : usage,
                             userInfo: user, generation: 1, enterpriseScope: false)
        return summary
    }

    private func allViews(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(allViews)
    }

    private func labels(_ view: NSView) -> [String] {
        allViews(view).compactMap { ($0 as? NSTextField)?.stringValue }
    }
}
