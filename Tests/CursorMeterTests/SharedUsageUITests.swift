import AppKit
import XCTest
@testable import CursorMeter

@MainActor
final class SharedUsageUITests: XCTestCase {
    func testSharedPopoverPreservesHeaderActionsAndFixedMeterPlacement() async throws {
        let vm = await makeSharedUsageUIViewModel(test: self)
        vm.setSplitOuterPool(.cursor)
        vm.setPopoverValueMode(.dollars)
        let vc = popover(vm)
        XCTAssertEqual(vc.preferredContentSize.width, 300)
        let strings = labels(vc.view)
        for expected in ["Demo User", "demo@example.com", "Weekly included", "Prepaid credit", "25%", "38%", "$12.40 left / $20.00", "Paid reset unknown"] {
            XCTAssertTrue(strings.contains { $0.contains(expected) }, "Missing \(expected): \(strings)")
        }
        let buttons = views(vc.view).compactMap { $0 as? NSButton }.filter { !$0.isHiddenOrHasHiddenAncestor }.map(\.title)
        for expected in ["Open Dashboard", "Manage Credits...", "Recent usage", "Settings...", "Log Out"] {
            XCTAssertTrue(buttons.contains(expected), expected)
        }
        XCTAssertEqual(vm.splitOuterPool, .cursor)
        XCTAssertEqual(vm.popoverValueMode, .dollars)
        let meter = try XCTUnwrap(views(vc.view).compactMap { $0 as? NSImageView }.first { $0.frame.width == 112 })
        XCTAssertTrue((meter.accessibilityValue() as? String)?.contains("Outer: Weekly included") == true)
        XCTAssertTrue((meter.accessibilityValue() as? String)?.contains("Center: Prepaid credit") == true)
        XCTAssertTrue((meter.accessibilityValue() as? String)?.contains("Remaining balance: $12.40") == true)
        XCTAssertTrue((meter.accessibilityValue() as? String)?.contains("Total purchased credit: $20.00") == true)
        XCTAssertTrue(meter.toolTip?.contains("Total purchased credit: $20.00") == true)
        XCTAssertTrue(views(vc.view).contains { $0.accessibilityLabel()?.contains("Total purchased credit: $20.00") == true })

        let display = SettingsAppearanceTabViewController(viewModel: vm)
        let alerts = SettingsNotificationsTabViewController(viewModel: vm)
        let recent = SettingsUsageTabViewController(viewModel: vm)
        for controller in [display as NSViewController, alerts, recent] { _ = controller.view }
        for (mode, badge) in [(SharedUsageMode.checking, "Checking"), (.unavailable, "Unavailable"), (.unsupported, "Unsupported")] {
            vm.sharedUsage.reset()
            if mode == .unavailable {
                vm.sharedUsage.acceptPlan(.failure(CursorSharedAPIError.transport), owner: nil, personalScope: nil)
            } else if mode == .unsupported {
                let plan = try JSONDecoder().decode(CursorPlanInfoResponse.self,
                    from: Data(#"{"isMerged":true,"planInfo":{"includedUsagePeriod":"UNKNOWN"}}"#.utf8))
                vm.sharedUsage.acceptPlan(.success(plan), owner: nil, personalScope: true)
            }
            XCTAssertEqual(vm.sharedUsage.mode, mode)
            let presentation = SharedUsagePresentation(mode: mode, snapshot: vm.sharedUsage.snapshot)
            XCTAssertEqual(presentation.statusItemAccessibilityLabel, "CursorMeter usage plan")
            XCTAssertNil(presentation.weekly.percent)
            XCTAssertNil(presentation.credit.percent)
            vc.updateUI()
            let modeLabels = labels(vc.view)
            XCTAssertTrue(modeLabels.contains(badge), modeLabels.description)
            XCTAssertTrue(modeLabels.contains("Included usage"), modeLabels.description)
            XCTAssertTrue(modeLabels.contains("Usage plan"), modeLabels.description)
            XCTAssertFalse(modeLabels.contains("Shared"))
            XCTAssertFalse(modeLabels.contains("Weekly included"))
            XCTAssertFalse(modeLabels.contains("Shared activity history unavailable"))
            XCTAssertFalse((meter.accessibilityValue() as? String)?.contains("Weekly included") == true)
            display.updateUI()
            alerts.updateUI()
            recent.updateUI()
            for surface in [display.view, alerts.view, recent.view] {
                let visible = views(surface).filter { !$0.isHiddenOrHasHiddenAncestor }
                let text = visible.flatMap { view in
                    [view.accessibilityLabel(), view.toolTip,
                     (view as? NSTextField)?.stringValue,
                     (view as? NSPopUpButton)?.selectedItem?.title].compactMap { $0 }
                }.joined(separator: "\n")
                for unsupportedClaim in ["Shared", "shared", "Weekly included", "Prepaid credit"] {
                    XCTAssertFalse(text.contains(unsupportedClaim), "\(mode): \(text)")
                }
            }
            let appearanceControls = views(display.view).compactMap { $0 as? NSControl }
            for name in ["Outer ring", "Popover values", "Show estimated limits", "Chart metric"] {
                XCTAssertFalse(try XCTUnwrap(appearanceControls.first { $0.accessibilityLabel() == name }).isEnabled)
            }
            let alertSwitches = views(alerts.view).compactMap { $0 as? NSSwitch }
            XCTAssertFalse(try XCTUnwrap(alertSwitches.first { $0.accessibilityLabel() == "Enable usage alerts" }).isEnabled)
            XCTAssertTrue(try XCTUnwrap(alertSwitches.first { $0.accessibilityLabel() == "App status notifications" }).isEnabled)
            let recentRefresh = try XCTUnwrap(views(recent.view).compactMap { $0 as? RefreshFeedbackButton }.first)
            XCTAssertEqual(recentRefresh.accessibilityLabel(), "Refresh usage")
            XCTAssertTrue(labels(recent.view).contains("Usage history unavailable."))
            XCTAssertEqual(vm.splitOuterPool, .cursor)
            XCTAssertEqual(vm.popoverValueMode, .dollars)
        }
    }

    func testTopUpChangesOnlyPrepaidConsumptionDenominator() async {
        let vm = await makeSharedUsageUIViewModel(.init(balance: 3240, purchased: 4000), test: self)
        let strings = labels(popover(vm).view)
        XCTAssertTrue(strings.contains("25%"))
        XCTAssertTrue(strings.contains("19%"))
        XCTAssertTrue(strings.contains("$32.40 left / $40.00"))
    }

    func testNoPurchasesExhaustedAndUnknownTotalsRemainDistinct() async {
        for (balance, purchased, readout, detail) in [(0, Optional(0), "—", "No top-ups"),
            (0, Optional(2000), "100%", "$0.00 left / $20.00"),
            (1240, nil, "—", "$12.40 left · Total unknown")] {
            let vm = await makeSharedUsageUIViewModel(.init(balance: balance, purchased: purchased), test: self)
            let strings = labels(popover(vm).view)
            XCTAssertTrue(strings.contains(readout), strings.description)
            XCTAssertTrue(strings.contains { $0.contains(detail) }, strings.description)
            let presentation = SharedUsagePresentation(mode: .sharedWeekly, snapshot: vm.sharedUsage.snapshot)
            XCTAssertTrue(presentation.tooltip.contains("Remaining balance:"))
            XCTAssertTrue(presentation.tooltip.contains(purchased == nil ? "Total purchased credit: unknown" : "Total purchased credit:"))
        }
    }

    func testNoPurchasesMeterIsDistinctFromUnknownAtBothSizes() async throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let empty = await makeSharedUsageUIViewModel(.init(balance: 0, purchased: 0, monthly: 0), test: self)
            let unknown = await makeSharedUsageUIViewModel(.init(balance: 0, purchased: nil), test: self)
            empty.setSplitMenuBarPercentagesEnabled(false)
            unknown.setSplitMenuBarPercentagesEnabled(false)
            let emptyPopover = popover(empty)
            let unknownPopover = popover(unknown)
            let emptyMeter = try XCTUnwrap(views(emptyPopover.view).compactMap { $0 as? NSImageView }
                .first { $0.frame.width == 112 }?.image)
            let unknownMeter = try XCTUnwrap(views(unknownPopover.view).compactMap { $0 as? NSImageView }
                .first { $0.frame.width == 112 }?.image)
            let pairs = [(emptyMeter, unknownMeter),
                         (AppDelegate(viewModel: empty).currentStatusImage(activeJump: nil),
                          AppDelegate(viewModel: unknown).currentStatusImage(activeJump: nil))]
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            var failure: Error?
            appearance.performAsCurrentDrawingAppearance {
                do {
                    for (emptyImage, unknownImage) in pairs {
                        XCTAssertFalse(try SplitMenuBarTestFixtures.pixels(emptyImage)
                                       == SplitMenuBarTestFixtures.pixels(unknownImage),
                                       "No purchases must be distinct at \(emptyImage.size) in \(appearanceName)")
                        let bitmap = try scaledBitmap(emptyImage)
                        let centerX = bitmap.pixelsWide / 2
                        let centerY = bitmap.pixelsHigh / 2
                        let center = try XCTUnwrap(bitmap.colorAt(x: centerX, y: centerY))
                        XCTAssertEqual(center.alphaComponent, 0, accuracy: 0.01, "No purchases must have no inner fill")
                        let radius = Double(min(bitmap.pixelsWide, bitmap.pixelsHigh)) * 0.27
                        for step in 0..<12 {
                            let angle = Double(step) * .pi / 6
                            let x = Int((Double(centerX) + cos(angle) * radius).rounded())
                            let y = Int((Double(centerY) + sin(angle) * radius).rounded())
                            let alphas = (-1...1).flatMap { dx in
                                (-1...1).compactMap { dy in bitmap.colorAt(x: x + dx, y: y + dy)?.alphaComponent }
                            }
                            XCTAssertGreaterThan(alphas.max() ?? 0, 0.1,
                                "Missing empty ring at angle \(step) for \(emptyImage.size) in \(appearanceName)")
                        }
                    }
                } catch { failure = error }
            }
            if let failure { throw failure }
            XCTAssertEqual(SharedUsagePresentation(mode: .sharedWeekly, snapshot: empty.sharedUsage.snapshot).credit.percentText, "—")
        }
    }

    func testNoPurchasesSettingsPreviewMatchesStatusMeter() async throws {
        _ = NSApplication.shared
        let vm = await makeSharedUsageUIViewModel(.init(balance: 0, purchased: 0, monthly: 0), test: self)
        let display = SettingsAppearanceTabViewController(viewModel: vm)
        _ = display.view
        let preview = try XCTUnwrap(views(display.view).compactMap { $0 as? NSImageView }
            .first { $0.accessibilityLabel()?.hasPrefix("Outer: Weekly included") == true })
        let app = AppDelegate(viewModel: vm)
        for percentagesEnabled in [false, true] {
            vm.setSplitMenuBarPercentagesEnabled(percentagesEnabled)
            display.updateUI()
            let previewImage = try XCTUnwrap(preview.image)
            let statusImage = app.currentStatusImage(activeJump: nil)
            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                var failure: Error?
                appearance.performAsCurrentDrawingAppearance {
                    do {
                        XCTAssertTrue(try SplitMenuBarTestFixtures.pixels(previewImage)
                                      == SplitMenuBarTestFixtures.pixels(statusImage),
                                      "Empty-wallet preview must match status with percentages \(percentagesEnabled) in \(appearanceName)")
                    } catch { failure = error }
                }
                if let failure { throw failure }
            }
        }
    }

    func testIndependentPartialAndStaleReadingsAreVisible() async {
        let partial = await makeSharedUsageUIViewModel(.init(weeklyFails: true), test: self)
        let partialLabels = labels(popover(partial).view)
        XCTAssertTrue(partialLabels.contains("—"))
        XCTAssertTrue(partialLabels.contains("38%"))
        XCTAssertTrue(partialLabels.contains { $0.contains("Weekly usage unavailable") })
        let stale = await makeSharedUsageUIViewModel(.init(purchased: nil), test: self)
        stale.sharedUsage.recordFailure(CursorSharedAPIError.transport)
        let staleLabels = labels(popover(stale).view)
        XCTAssertTrue(staleLabels.contains { $0.contains("Stale") })
        XCTAssertTrue(staleLabels.contains { $0.contains("$12.40 left") })
    }

    func testExpiredWeeklyValueIsMarkedStaleAtRenderTime() async {
        let fixture = SharedUsageUIFixture(now: Date().addingTimeInterval(-172800))
        let vm = await makeSharedUsageUIViewModel(fixture, test: self)
        let strings = labels(popover(vm).view)
        XCTAssertTrue(strings.contains { $0.contains("Stale") })
        XCTAssertFalse(strings.contains { $0.contains("Included usage remains available") })
    }

    func testMonthlyZeroNoCapAndUnknownRemainDistinct() async {
        for (cap, expected) in [(Optional(0), "$0.00 cap"), (Optional(Int(Int32.max)), "No cap"), (nil, "Cap unknown")] {
            let vm = await makeSharedUsageUIViewModel(.init(cap: cap, autoTopUp: nil), test: self)
            let strings = labels(popover(vm).view)
            XCTAssertTrue(strings.contains { $0.contains(expected) }, strings.description)
            XCTAssertTrue(strings.contains { $0.contains("Auto Top-up: Unknown") })
            XCTAssertTrue(strings.contains { $0.contains("Paid reset unknown") })
        }
    }

    func testSharedStatusUsesDualMeterAndOptionalPercentagesWithoutUsageData() async throws {
        let vm = await makeSharedUsageUIViewModel(test: self)
        XCTAssertNil(vm.usageData)
        let app = AppDelegate(viewModel: vm)
        XCTAssertEqual(SharedUsagePresentation(mode: .sharedWeekly, snapshot: vm.sharedUsage.snapshot).statusItemAccessibilityLabel,
                       "CursorMeter weekly included and prepaid credit usage")
        vm.setSplitMenuBarPercentagesEnabled(false)
        let plain = app.currentStatusImage(activeJump: nil)
        XCTAssertEqual(plain.size, NSSize(width: 18, height: 18))
        vm.setSplitMenuBarPercentagesEnabled(true)
        let withText = app.currentStatusImage(activeJump: nil)
        XCTAssertGreaterThan(withText.size.width, plain.size.width)
        XCTAssertEqual(withText.size.height, 22)
    }

    func testSharedSettingsRestoreAlertsAndJumpWithoutChangingUnrelatedPreferences() async throws {
        let vm = await makeSharedUsageUIViewModel(test: self)
        vm.setSplitOuterPool(.cursor)
        vm.setPopoverValueMode(.dollars)
        vm.setEstimatedLimitsEnabled(true)
        vm.setJumpEffectEnabled(true)
        vm.setWeeklyChartEnabled(true)
        let appearance = SettingsAppearanceTabViewController(viewModel: vm)
        _ = appearance.view
        let controls = views(appearance.view).compactMap { $0 as? NSControl }
        for name in ["Outer ring", "Popover values", "Show estimated limits", "Chart metric"] {
            let control = try XCTUnwrap(controls.first { $0.accessibilityLabel() == name }, name)
            XCTAssertFalse(control.isEnabled, name)
        }
        XCTAssertTrue(labels(appearance.view).contains { $0.contains("Weekly included") && $0.contains("Prepaid credit") })
        for action in ["jumpEffectToggleChanged", "jumpIntensityChanged", "jumpGlyphStyleChanged"] {
            let control = try XCTUnwrap(controls.first { $0.action == NSSelectorFromString(action) }, action)
            XCTAssertTrue(control.isEnabled, action)
        }
        vm.setNotificationEnabled(true)
        let alerts = SettingsNotificationsTabViewController(viewModel: vm)
        _ = alerts.view
        let toggles = views(alerts.view).compactMap { $0 as? NSSwitch }
        XCTAssertTrue(try XCTUnwrap(toggles.first { $0.accessibilityLabel() == "Enable usage alerts" }).isEnabled)
        let threshold = try XCTUnwrap(views(alerts.view).compactMap { $0 as? ThresholdRangeSlider }.first)
        XCTAssertFalse(threshold.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(labels(alerts.view).contains { $0.contains("Weekly included usage") })
        XCTAssertTrue(try XCTUnwrap(toggles.first { $0.accessibilityLabel() == "App status notifications" }).isEnabled)
        XCTAssertEqual(vm.splitOuterPool, .cursor)
        XCTAssertEqual(vm.popoverValueMode, .dollars)
        XCTAssertTrue(vm.estimatedLimitsEnabled)
        XCTAssertTrue(vm.jumpEffectEnabled)
        XCTAssertTrue(vm.weeklyChartEnabled)
    }

    func testSharedRecentPanelHidesRetainedLegacyRowsAndExplainsMeterRefresh() async throws {
        let vm = await makeSharedUsageUIViewModel(test: self)
        vm.recentUsage.beginSession(generation: 1)
        let context = try XCTUnwrap(vm.recentUsage.selectCredential(cookieHeader: "WorkosCursorSessionToken=synthetic", generation: 1, attemptID: 1))
        XCTAssertTrue(vm.recentUsage.validateIdentity(subject: "synthetic", scope: .personal, context: context))
        let entry = RecentUsageEntry(date: Date(), model: "legacy-model", kind: .included, tokens: 1, chargedCents: 1)
        XCTAssertTrue(vm.recentUsage.publish(candidate: .init(entries: [entry], cachedAt: Date()), context: context))
        let vc = SettingsUsageTabViewController(viewModel: vm)
        _ = vc.view
        let table = try XCTUnwrap(views(vc.view).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(vc.numberOfRows(in: table), 0)
        XCTAssertTrue(table.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(labels(vc.view).contains("Shared usage history unavailable."))
        XCTAssertTrue(labels(vc.view).contains { $0.contains("Refresh updates the shared meter") })
        let refresh = try XCTUnwrap(views(vc.view).compactMap { $0 as? RefreshFeedbackButton }.first { !$0.isHiddenOrHasHiddenAncestor })
        XCTAssertEqual(refresh.accessibilityLabel(), "Refresh shared meter")
        XCTAssertNotEqual(refresh.accessibilityValue() as? String, "Retry later")
    }

    func testSharedPlacementSelectorExplainsFixedMeaningAndRestoresLegacyChoice() async throws {
        let vm = await makeSharedUsageUIViewModel(test: self)
        vm.setSplitOuterPool(.cursor)
        let display = SettingsAppearanceTabViewController(viewModel: vm)
        _ = display.view
        let selector = try XCTUnwrap(views(display.view).compactMap { $0 as? NSPopUpButton }
            .first { $0.accessibilityLabel() == "Outer ring" })
        XCTAssertEqual(selector.selectedItem?.title, "Weekly included")
        let vc = popover(vm)
        let legacyPlan = try JSONDecoder().decode(CursorPlanInfoResponse.self, from: Data(#"{"isMerged":false}"#.utf8))
        vm.sharedUsage.acceptPlan(.success(legacyPlan), owner: nil, personalScope: true)
        try SplitMenuBarTestFixtures.publishSplit(to: vm)
        display.updateUI()
        vc.updateUI()
        XCTAssertEqual(selector.selectedItem?.title, "Cursor Models")
        XCTAssertTrue(selector.isEnabled)
        XCTAssertEqual(vm.splitOuterPool, .cursor)
        XCTAssertFalse(views(vc.view).compactMap { $0 as? NSButton }
            .contains { $0.title == "Manage Credits..." && !$0.isHiddenOrHasHiddenAncestor })
        let meter = try XCTUnwrap(views(vc.view).compactMap { $0 as? NSImageView }.first { $0.frame.width == 112 })
        XCTAssertEqual(meter.accessibilityLabel(), "Split usage meter")
        XCTAssertEqual(SharedUsagePresentation.dashboardURL(mode: .legacy).absoluteString,
                       "https://www.cursor.com/dashboard?tab=usage")
    }

    func testSharedJumpRendersGlyphAndRestoresLatestFixedRingMeaning() async throws {
        let vm = await makeSharedUsageUIViewModel(test: self)
        vm.setSplitOuterPool(.cursor)
        vm.setSplitMenuBarPercentagesEnabled(true)
        let app = AppDelegate(viewModel: vm)
        let expected = SplitMenuBarRenderer.image(icon: CircularProgressIcon.makeDualPercentImage(
            outerPercent: 25, centerPercent: 38), readout: .init(upper: "25%", lower: "38%"))
        let jump = ActiveJump(emoji: "🚀", glow: true, fallbackSize: NSSize(width: 18, height: 18))
        let jumping = SplitMenuBarRenderer.image(icon: CircularProgressIcon.makeEmojiImage(
            emoji: jump.emoji, size: NSSize(width: 18, height: 18), glow: jump.glow),
            readout: .init(upper: "25%", lower: "38%"))
        XCTAssertEqual(try SplitMenuBarTestFixtures.pixels(app.currentStatusImage(activeJump: jump)),
                       try SplitMenuBarTestFixtures.pixels(jumping))
        XCTAssertEqual(try SplitMenuBarTestFixtures.pixels(app.currentStatusImage(activeJump: nil)),
                       try SplitMenuBarTestFixtures.pixels(expected))
        vm.sharedUsage.recordFailure(CursorSharedAPIError.transport)
        let latest = SharedUsagePresentation(mode: .sharedWeekly, snapshot: vm.sharedUsage.snapshot)
        let restored = SplitMenuBarRenderer.image(icon: CircularProgressIcon.makeDualPercentImage(
            outerPercent: latest.weekly.percent, centerPercent: latest.credit.percent), readout: latest.readout)
        XCTAssertEqual(try SplitMenuBarTestFixtures.pixels(app.currentStatusImage(activeJump: nil)),
                       try SplitMenuBarTestFixtures.pixels(restored))
        XCTAssertEqual(SharedUsagePresentation.dashboardURL(mode: .sharedWeekly).absoluteString,
                       "https://grok.com/dashboard/usage")
        XCTAssertEqual(SharedUsagePresentation.creditsURL.absoluteString, "https://grok.com/dashboard/billing")
    }

    func testStaleCapCannotProduceCurrentBlockingClaim() async {
        let vm = await makeSharedUsageUIViewModel(.init(weekly: 100, cap: 0), test: self)
        let fresh = SharedUsagePresentation(mode: .sharedWeekly, snapshot: vm.sharedUsage.snapshot)
        XCTAssertEqual(fresh.status, "Monthly paid cap reached.")
        vm.sharedUsage.recordFailure(CursorSharedAPIError.transport)
        let stale = SharedUsagePresentation(mode: .sharedWeekly, snapshot: vm.sharedUsage.snapshot)
        XCTAssertEqual(stale.status, "Stale readings — refresh to verify.")
        XCTAssertTrue(stale.detailLines.joined().contains("$0.00 cap (stale)"))
        XCTAssertTrue(stale.tooltip.contains("Outer: Weekly included 100%"))
        XCTAssertTrue(stale.tooltip.contains("Center: Prepaid credit consumed 38%"))
    }

    func testSharedRefreshSuccessDoesNotDisplayMissingHistoryAsMeterFailure() async throws {
        let now = ContinuousClock.now
        var sleeps = 0
        let feedback = RefreshFeedback(now: { now }, sleepUntil: { _ in
            sleeps += 1
            if sleeps > 1 { try await Task.sleep(for: .seconds(60)) }
        })
        defer { feedback.invalidate() }
        let vm = await makeSharedUsageUIViewModel(feedback: feedback, test: self)
        await vm.refreshFromUser()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while feedback.phase == .updating, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(feedback.phase, .result(meter: .success, recent: .failure))
        let vc = SettingsUsageTabViewController(viewModel: vm)
        _ = vc.view
        let refresh = try XCTUnwrap(views(vc.view).compactMap { $0 as? RefreshFeedbackButton }.first)
        XCTAssertEqual(refresh.accessibilityValue() as? String, "Updated")
    }

    func testSharedSurfacesRenderSyntheticArtifacts() async throws {
        let normal = await makeSharedUsageUIViewModel(test: self)
        normal.setSplitMenuBarPercentagesEnabled(true)
        let stale = await makeSharedUsageUIViewModel(.init(purchased: nil, autoTopUp: nil), test: self)
        stale.sharedUsage.recordFailure(CursorSharedAPIError.transport)
        let exhausted = await makeSharedUsageUIViewModel(.init(weekly: 100, balance: 0, purchased: 2000, cap: 0), test: self)
        let empty = await makeSharedUsageUIViewModel(.init(balance: 0, purchased: 0, monthly: 0), test: self)
        let surfaces: [(String, NSViewController)] = [
            ("shared-popover", popover(normal)),
            ("shared-popover-stale-unknown", popover(stale)),
            ("shared-popover-exhausted-cap", popover(exhausted)),
            ("shared-popover-no-purchases", popover(empty)),
            ("shared-display", SettingsAppearanceTabViewController(viewModel: normal)),
            ("shared-display-no-purchases", SettingsAppearanceTabViewController(viewModel: empty)),
            ("shared-alerts", SettingsNotificationsTabViewController(viewModel: normal)),
            ("shared-recent", SettingsUsageTabViewController(viewModel: normal)),
        ]
        for (name, controller) in surfaces {
            _ = controller.view
            let popover = controller as? MenuBarPopoverViewController
            let size = popover?.preferredContentSize ?? controller.view.fittingSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["CM_UI_DARK"] == "1" ? .darkAqua : .aqua)
            controller.view.appearance = window.appearance
            window.contentViewController = controller
            window.setContentSize(size)
            controller.view.layoutSubtreeIfNeeded()
            defer { window.contentViewController = nil; window.close() }
            XCTAssertEqual(size.width, popover == nil ? 440 : 300, accuracy: 1, name)
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

    private func scaledBitmap(_ image: NSImage) throws -> NSBitmapImageRep {
        let size = NSSize(width: image.size.width * 4, height: image.size.height * 4)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        image.draw(in: NSRect(origin: .zero, size: size))
        return bitmap
    }

    private func popover(_ vm: UsageViewModel) -> MenuBarPopoverViewController {
        _ = NSApplication.shared
        let vc = MenuBarPopoverViewController(viewModel: vm, onLogin: {}, onSettings: {})
        _ = vc.view
        vc.updateUI()
        return vc
    }
    private func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
    private func labels(_ view: NSView) -> [String] {
        views(view).compactMap { ($0 as? NSTextField)?.stringValue }
    }
}
