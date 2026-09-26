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

    func testPartialAmountsDoNotLeakCollectionDiagnosticsIntoPopover() async throws {
        let vm = try await makePausedViewModel(sleeping: false)
        let vc = MenuBarPopoverViewController(viewModel: vm, onLogin: {}, onSettings: {})
        _ = vc.view
        vc.updateUI()
        let text = labels(vc.view).joined(separator: "\n")
        for diagnostic in ["Coverage:", "Unknown:", "Reconciliation residual:", "Amount snapshot:", "Amounts: Ready"] {
            XCTAssertFalse(text.contains(diagnostic), diagnostic)
        }
        XCTAssertNotNil(vm.splitUsage.amounts)
        XCTAssertEqual(vm.splitUsage.amounts?.coverage.complete, false)
    }

    func testPopoverKeepsPeriodPercentageWithoutDiagnosticTimestamps() async throws {
        let vm = try await makePeriodViewModel()
        let vc = MenuBarPopoverViewController(viewModel: vm, onLogin: {}, onSettings: {})
        _ = vc.view
        vc.updateUI()
        let text = labels(vc.view).joined(separator: "\n")
        XCTAssertTrue(text.contains("41%"))
        XCTAssertFalse(text.contains("Primary summary refreshed:"))
        XCTAssertFalse(text.contains("Percent source:"))
    }

    func testRecentRemainsAvailableWhenCycleCollectionIsPaused() async throws {
        for sleeping in [false, true] {
            let vm = try await makePausedViewModel(sleeping: sleeping)
            let vc = SettingsUsageTabViewController(viewModel: vm)
            _ = vc.view
            vc.updateUI()
            XCTAssertNil(allViews(vc.view).first { $0.accessibilityLabel() == "Cycle usage summary" })
            XCTAssertNotNil(allViews(vc.view).first { $0.accessibilityLabel() == "Refresh recent usage" })
            XCTAssertEqual(vc.view.fittingSize.width, 440, accuracy: 1)
            XCTAssertFalse(labels(vc.view).contains { $0.contains("collection paused") })
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
        XCTAssertTrue(legacy.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(legacy.selectedItem?.tag, 1)
        XCTAssertFalse(labels(vc.view).contains("On hover"))
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
        XCTAssertFalse(labels(vc.view).contains { $0.contains("Costs pending") || $0.contains("Estimate not ready") })
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
        let buttons = allViews(vc.view).compactMap { $0 as? NSSwitch }
        let cursor = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "Cursor Models alerts" })
        let other = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "Other Models alerts" })
        let paid = try XCTUnwrap(buttons.first { $0.accessibilityLabel() == "Paid budget alerts" })
        XCTAssertTrue(cursor.isEnabled)
        XCTAssertEqual(cursor.state, .on)
        XCTAssertEqual(other.state, .off)
        XCTAssertTrue(paid.isEnabled)
        try publishSplit(to: vm, paidEnabled: false)
        vc.updateUI()
        XCTAssertTrue(paid.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(paid.state, .on)
        XCTAssertEqual(vm.splitAlertTargets, [.cursor, .onDemand])
    }

    func testUsageOpensRecentWithoutChangingPublishedCycleState() throws {
        let vm = makeViewModel()
        try publishSplit(to: vm)
        let snapshot = vm.splitUsage.snapshot
        let vc = SettingsUsageTabViewController(viewModel: vm)
        _ = vc.view
        vc.updateUI()
        XCTAssertNil(allViews(vc.view).first { $0.accessibilityLabel() == "Cycle usage summary" })
        let refresh = try XCTUnwrap(allViews(vc.view).first { $0.accessibilityLabel() == "Refresh recent usage" })
        XCTAssertFalse(refresh.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(vm.splitUsage.snapshot, snapshot)
        XCTAssertEqual(vm.splitUsage.amountState, .pending)
    }

    func testOffscreenSplitSurfacesFitAndRenderSyntheticFixtures() async throws {
        _ = NSApplication.shared
        let keys = ["popoverValueMode", "estimatedLimitsEnabled", "splitAlertThresholds"]
        let defaults = UserDefaults.standard
        let saved = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer { for key in keys { if let value = saved[key] ?? nil { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        let vm = try await makeRecordedViewModel(mode: .both, estimates: false)
        vm.notificationEnabled = true
        let estimatedVM = try await makeRecordedViewModel(mode: .both, estimates: true)
        let dollarsVM = try await makeRecordedViewModel(mode: .dollars, estimates: true)
        let percentVM = try await makeRecordedViewModel(mode: .percent, estimates: false)
        let noChartVM = try await makeRecordedViewModel(mode: .both, estimates: false)
        noChartVM.weeklyChartEnabled = false
        let periodVM = try await makePeriodViewModel()
        let pausedVM = try await makePausedViewModel(sleeping: false)
        let sleepingVM = try await makePausedViewModel(sleeping: true)
        let popover = MenuBarPopoverViewController(viewModel: vm, onLogin: {}, onSettings: {})
        let surfaces: [(String, NSViewController)] = [
            ("popover", popover),
            ("popover-estimated", MenuBarPopoverViewController(viewModel: estimatedVM, onLogin: {}, onSettings: {})),
            ("popover-dollars", MenuBarPopoverViewController(viewModel: dollarsVM, onLogin: {}, onSettings: {})),
            ("popover-percent", MenuBarPopoverViewController(viewModel: percentVM, onLogin: {}, onSettings: {})),
            ("popover-no-chart", MenuBarPopoverViewController(viewModel: noChartVM, onLogin: {}, onSettings: {})),
            ("popover-period", MenuBarPopoverViewController(viewModel: periodVM, onLogin: {}, onSettings: {})),
            ("display", SettingsAppearanceTabViewController(viewModel: vm)),
            ("display-short", SettingsAppearanceTabViewController(viewModel: vm, screenHeight: { 681 })),
            ("alerts", SettingsNotificationsTabViewController(viewModel: vm)),
            ("alerts-short", SettingsNotificationsTabViewController(viewModel: vm, screenHeight: { 600 })),
            ("estimate-help", EstimatedLimitsHelpController()),
            ("recent", SettingsUsageTabViewController(viewModel: vm)),
            ("recent-paused", SettingsUsageTabViewController(viewModel: pausedVM)),
            ("recent-sleeping", SettingsUsageTabViewController(viewModel: sleepingVM)),
        ]
        for (name, controller) in surfaces {
            _ = controller.view
            let popoverController = controller as? MenuBarPopoverViewController
            popoverController?.updateUI()
            let size = popoverController?.preferredContentSize ?? controller.view.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["CM_UI_DARK"] == "1" ? .darkAqua : .aqua)
            controller.view.appearance = window.appearance
            window.contentViewController = controller
            window.setContentSize(size)
            controller.view.layoutSubtreeIfNeeded()
            defer { window.contentViewController = nil; window.close() }
            XCTAssertEqual(size.width, popoverController != nil ? 300 : (name == "estimate-help" ? 320 : 440), accuracy: 1, name)
            XCTAssertLessThanOrEqual(size.height, (NSScreen.main?.visibleFrame.height ?? 800) - 20, name)
            let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
            window.appearance?.performAsCurrentDrawingAppearance {
                controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            }
            let contents = NSImage(size: controller.view.bounds.size)
            contents.addRepresentation(bitmap)
            let rendered = NSImage(size: controller.view.bounds.size, flipped: false) { rect in
                NSColor.windowBackgroundColor.setFill()
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

    func testCycleCollectionCooldownStillAllowsRetryAfterExpiry() async throws {
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
        XCTAssertFalse(vm.canRefreshAmounts)
        now = now.addingTimeInterval(61)
        XCTAssertTrue(vm.canRefreshAmounts)
    }

    func testLegacyDisplayKeepsMenuTextAndDisablesPoolPlacement() throws {
        let vm = makeViewModel()
        vm.menuBarDisplayMode = 1
        let vc = SettingsAppearanceTabViewController(viewModel: vm)
        _ = vc.view
        vc.updateUI()
        let placement = try XCTUnwrap(allViews(vc.view).compactMap { $0 as? NSPopUpButton }
            .first { $0.accessibilityLabel() == "Outer ring" })
        XCTAssertTrue(placement.isHiddenOrHasHiddenAncestor)
        let legacy = try XCTUnwrap(allViews(vc.view).compactMap { $0 as? NSPopUpButton }
            .first { $0.accessibilityLabel() == "Legacy usage text" })
        XCTAssertTrue(legacy.isEnabled)
        XCTAssertEqual(legacy.selectedItem?.tag, 1)
        XCTAssertEqual(vm.menuBarDisplayMode, 1)
        XCTAssertFalse(labels(vc.view).contains { $0.contains("Bold notifications are independent") })
    }

    func testLegacyAlertsHideSplitTargetsAndSuccessfulPermissionNoise() throws {
        let vm = makeViewModel()
        let vc = SettingsNotificationsTabViewController(viewModel: vm)
        _ = vc.view
        vc.updateUI()
        let targets = allViews(vc.view).compactMap { $0 as? NSSwitch }
            .filter { ["Cursor Models alerts", "Other Models alerts", "Paid budget alerts"].contains($0.accessibilityLabel() ?? "") }
        XCTAssertTrue(targets.allSatisfy { $0.isHiddenOrHasHiddenAncestor })
        XCTAssertFalse(labels(vc.view).contains { $0.contains("Notification permission:") })
        XCTAssertFalse(labels(vc.view).contains { $0.contains("Bold") && $0.contains("independent") })
    }

    func testUsageRetainsRecentTimezoneAndViewportWithoutSummarySelector() throws {
        let vc = SettingsUsageTabViewController(viewModel: makeViewModel())
        _ = vc.view
        vc.updateUI()
        let selectors = allViews(vc.view).compactMap { $0 as? NSSegmentedControl }
        XCTAssertNil(selectors.first { $0.accessibilityLabel() == "Usage view" })
        XCTAssertNotNil(selectors.first { $0.accessibilityLabel() == "Time zone" })
        XCTAssertNotNil(allViews(vc.view).compactMap { $0 as? NSTableView }.first)
        XCTAssertNil(allViews(vc.view).first { $0.accessibilityLabel() == "Cycle usage summary" })
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

    private func makeRecordedViewModel(mode: PopoverValueMode, estimates: Bool) async throws -> UsageViewModel {
        let controller = SplitUsageController(collect: { snapshot, _, _, _, _ in
            let amounts = CycleAmountSnapshot(identity: snapshot.identity, capturedAt: snapshot.capturedAt,
                cursorCents: 10000, otherCents: 8200, botCents: 340, paidCents: 200,
                unknownCents: 0, unknownCount: 0, residualCents: 0,
                coverage: CycleCoverage(complete: true, pageCount: 2, eventCount: 180),
                status: .estimatedAttribution, estimatedCursorLimitCents: 100000,
                estimatedOtherLimitCents: 20000, sourceCursorPercent: 10, sourceOtherPercent: 41)
            return CycleCollectionResult(status: .complete, snapshot: amounts, pageCount: 2, byteCount: 100)
        })
        let vm = makeViewModel(splitUsage: controller)
        let summary = try publishSplit(to: vm, cursorPercent: 10)
        controller.requestAmounts(summary: summary, cookieHeader: "synthetic")
        for _ in 0..<100 where controller.amountState == .refreshing {
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(controller.amountState, .ready)
        vm.setPopoverValueMode(mode)
        vm.setEstimatedLimitsEnabled(estimates)
        let now = Date()
        vm.weeklyChartEnabled = true
        vm.weeklyChartAvailable = true
        vm.weeklyData = [9, 6, 17, 2, 51, 4, 65].enumerated().map { offset, amount in
            DayUsage(date: now.addingTimeInterval(Double(offset - 6) * 86400), requests: amount,
                     isToday: offset == 6, isOnDemand: false, onDemandCents: 0,
                     totalChargedCents: amount * 10, amountCents: Double(amount * 10))
        }
        vm.recentUsage.beginSession(generation: 1)
        let context = try XCTUnwrap(vm.recentUsage.selectCredential(cookieHeader: "WorkosCursorSessionToken=synthetic", generation: 1, attemptID: 1))
        XCTAssertTrue(vm.recentUsage.validateIdentity(subject: "synthetic-ui", scope: .personal, context: context))
        let entries = ["claude-opus-5.5", "composer-2.5", "kimi-k3-high", "grok-4.7"].enumerated().map { offset, model in
            RecentUsageEntry(date: now.addingTimeInterval(Double(-offset * 60)), model: model,
                             kind: .included, tokens: 12000 + offset * 1000, chargedCents: Double(36 - offset * 5))
        }
        XCTAssertTrue(vm.recentUsage.publish(candidate: RecentUsageCandidate(entries: entries, cachedAt: now), context: context))
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
                              otherMissing: Bool = false, cursorPercent: Double = 135) throws -> UsageSummaryResponse {
        let json = #"{"billingCycleStart":"2026-09-01T00:00:00Z","billingCycleEnd":"2026-10-01T00:00:00Z","membershipType":"ultra","individualUsage":{"plan":{"enabled":true,"used":18200,"limit":40000,"autoPercentUsed":135,"apiPercentUsed":41},"onDemand":{"enabled":PAID,"used":200,"limit":1000}}}"#
            .replacingOccurrences(of: "PAID", with: paidEnabled ? "true" : "false")
            .replacingOccurrences(of: "\"autoPercentUsed\":135", with: "\"autoPercentUsed\":\(cursorPercent)")
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
