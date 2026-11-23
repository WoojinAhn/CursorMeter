import AppKit
import XCTest
@testable import CursorMeter

@MainActor
final class SharedUsageUITests: XCTestCase {
    func testSharedActivityControlsRemainReachableWithNoActivityResponse() async throws {
        let vm = await makeSharedUsageUIViewModel(test: self)
        let appearance = SettingsAppearanceTabViewController(viewModel: vm)
        let recent = SettingsUsageTabViewController(viewModel: vm)
        _ = appearance.view
        _ = recent.view
        let controls = views(appearance.view).compactMap { $0 as? NSControl }
        for action in ["weeklyChartToggleChanged", "weeklyChartStyleChanged", "weeklyChartMetricChanged"] {
            XCTAssertTrue(try XCTUnwrap(controls.first { $0.action == NSSelectorFromString(action) }).isEnabled, action)
        }
        let zone = try XCTUnwrap(views(recent.view).compactMap { $0 as? NSSegmentedControl }.first)
        XCTAssertTrue(zone.isEnabled)
        XCTAssertFalse(zone.isHiddenOrHasHiddenAncestor)
    }
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

    func testCurrentZeroBalanceHidesPrepaidAcrossSurfacesRegardlessOfPurchaseHistory() async throws {
        for purchased in [Optional(0), Optional(2000), nil] {
            let vm = await makeSharedUsageUIViewModel(.init(balance: 0, purchased: purchased, monthly: 0), test: self)
            let vc = popover(vm)
            let presentation = SharedUsagePresentation(mode: .sharedWeekly, snapshot: vm.sharedUsage.snapshot)
            XCTAssertNil(presentation.readout.lower)
            XCTAssertEqual(presentation.statusItemAccessibilityLabel, "CursorMeter weekly included usage")
            XCTAssertEqual(presentation.detailLines, [])
            XCTAssertFalse(presentation.tooltip.contains("credit"))
            XCTAssertFalse(presentation.accessibilityValue.contains("Center:"))
            let strings = labels(vc.view).filter { !$0.isEmpty }
            XCTAssertTrue(strings.contains("Included usage"), strings.description)
            let visibleLabels = views(vc.view).filter { !$0.isHiddenOrHasHiddenAncestor }
                .compactMap { ($0 as? NSTextField)?.stringValue }
            for unwanted in ["Prepaid credit", "No top-ups", "Monthly paid", "Auto Top-up", "Paid reset", "credits"] {
                XCTAssertFalse(visibleLabels.contains { $0.contains(unwanted) }, "\(unwanted): \(visibleLabels)")
            }
            XCTAssertTrue(views(vc.view).compactMap { $0 as? NSButton }
                .contains { $0.title == "Manage Credits..." && !$0.isHiddenOrHasHiddenAncestor })
            let display = SettingsAppearanceTabViewController(viewModel: vm)
            _ = display.view
            let displayText = views(display.view).filter { !$0.isHiddenOrHasHiddenAncestor }.flatMap {
                [$0.accessibilityLabel(), $0.toolTip, ($0 as? NSTextField)?.stringValue].compactMap { $0 }
            }.joined(separator: "\n")
            XCTAssertFalse(displayText.lowercased().contains("prepaid"), displayText)
            XCTAssertFalse(displayText.contains("Center:"), displayText)
            let layout = SplitMenuBarRenderer.layout(readout: presentation.readout)
            XCTAssertEqual(layout.upperRowRect.midY, layout.size.height / 2)
        }
    }

    func testPositiveAndStaleZeroBalancesKeepPrepaidPresentation() async {
        for (balance, purchased, stale) in [(1240, Optional(2000), false), (1240, nil, false),
                                           (0, Optional(0), true), (0, nil, true)] {
            let vm = await makeSharedUsageUIViewModel(.init(balance: balance, purchased: purchased), test: self)
            if stale { vm.sharedUsage.recordFailure(CursorSharedAPIError.transport) }
            let presentation = SharedUsagePresentation(mode: .sharedWeekly, snapshot: vm.sharedUsage.snapshot)
            XCTAssertNotNil(presentation.readout.lower)
            XCTAssertTrue(presentation.tooltip.contains("Remaining balance:"))
            XCTAssertTrue(presentation.accessibilityValue.contains("Center:"))
            let visibleLabels = views(popover(vm).view).filter { !$0.isHiddenOrHasHiddenAncestor }
                .compactMap { ($0 as? NSTextField)?.stringValue }
            XCTAssertTrue(visibleLabels.contains("Prepaid credit"), visibleLabels.description)
        }
    }

    func testZeroBalanceOmitsAllCenterPixelsAtBothSizesAcrossAppearances() async throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            for purchased in [Optional(0), Optional(2000), nil] {
                let empty = await makeSharedUsageUIViewModel(.init(balance: 0, purchased: purchased, monthly: 0), test: self)
                empty.setSplitMenuBarPercentagesEnabled(false)
                let emptyPopover = popover(empty)
                let emptyMeter = try XCTUnwrap(views(emptyPopover.view).compactMap { $0 as? NSImageView }
                    .first { $0.frame.width == 112 }?.image)
                let images = [emptyMeter, AppDelegate(viewModel: empty).currentStatusImage(activeJump: nil)]
                let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                var failure: Error?
                appearance.performAsCurrentDrawingAppearance {
                    do {
                        for image in images {
                            let bitmap = try scaledBitmap(image)
                            let centerX = Double(bitmap.pixelsWide) / 2
                            let centerY = Double(bitmap.pixelsHigh) / 2
                            let radius = Double(min(bitmap.pixelsWide, bitmap.pixelsHigh)) * 0.32
                            var maximumAlpha: CGFloat = 0
                            for x in 0..<bitmap.pixelsWide {
                                for y in 0..<bitmap.pixelsHigh where hypot(Double(x) - centerX, Double(y) - centerY) < radius {
                                    maximumAlpha = max(maximumAlpha, bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0)
                                }
                            }
                            XCTAssertEqual(maximumAlpha, 0, accuracy: 0.01,
                                "Center must be absent at \(image.size) in \(appearanceName), purchased \(String(describing: purchased))")
                            let reference = try scaledBitmap(CircularProgressIcon.makeDualPercentImage(
                                outerPercent: 25, centerPercent: 38, size: image.size))
                            var maximumOuterDifference: CGFloat = 0
                            for x in 0..<bitmap.pixelsWide {
                                for y in 0..<bitmap.pixelsHigh where hypot(Double(x) - centerX, Double(y) - centerY) > radius {
                                    let actual = try XCTUnwrap(bitmap.colorAt(x: x, y: y))
                                    let expected = try XCTUnwrap(reference.colorAt(x: x, y: y))
                                    maximumOuterDifference = max(maximumOuterDifference,
                                        abs(actual.alphaComponent - expected.alphaComponent),
                                        abs(actual.redComponent - expected.redComponent),
                                        abs(actual.greenComponent - expected.greenComponent),
                                        abs(actual.blueComponent - expected.blueComponent))
                                }
                            }
                            XCTAssertEqual(maximumOuterDifference, 0, accuracy: 0.01, "Outer ring geometry and color must stay unchanged")
                        }
                    } catch { failure = error }
                }
                if let failure { throw failure }
            }
        }
    }

    func testUnavailableCreditDoesNotBecomeConfirmedZero() async {
        let vm = await makeSharedUsageUIViewModel(.init(prepaidFails: true), test: self)
        let presentation = SharedUsagePresentation(mode: .sharedWeekly, snapshot: vm.sharedUsage.snapshot)
        XCTAssertNotNil(presentation.readout.lower)
        XCTAssertTrue(presentation.tooltip.contains("Remaining balance: unknown"))
        XCTAssertTrue(labels(popover(vm).view).contains("Prepaid credit"))
    }

    func testZeroBalanceKeepsOnlyMeaningfulIndependentPaidDetails() async {
        for (monthly, cap, auto, expected) in [
            (760, Optional(50), false, ["Monthly paid: $7.60 / $50.00 cap"]),
            (0, Optional(0), false, ["Monthly paid: $0.00 / $0.00 cap"]),
            (0, nil, true, ["Auto Top-up: On"]),
            (0, nil, false, []),
        ] {
            let vm = await makeSharedUsageUIViewModel(.init(balance: 0, monthly: monthly, cap: cap, autoTopUp: auto), test: self)
            let presentation = SharedUsagePresentation(mode: .sharedWeekly, snapshot: vm.sharedUsage.snapshot)
            XCTAssertEqual(presentation.detailLines, expected)
            if cap == 0 { XCTAssertEqual(presentation.status, "Monthly paid cap reached.") }
        }
    }

    func testUnhiddenPoolAndDetailRowsKeepTheirContainerWidths() async throws {
        let initial = SharedUsageUIFixture(balance: 0, purchased: 0, monthly: 0)
        let provider = SharedUsageUISequenceFixture(initial)
        let vm = await makeSharedUsageUIViewModel(initial, provider: provider, test: self)
        vm.setPopoverValueMode(.dollars)
        let vc = popover(vm)
        let window = NSWindow(contentViewController: vc)
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }
        for legacy in [false, true] {
            if legacy {
                await provider.setFixture(initial)
                await vm.refresh()
                vc.updateUI()
                let plan = try JSONDecoder().decode(CursorPlanInfoResponse.self, from: Data(#"{"isMerged":false}"#.utf8))
                vm.sharedUsage.acceptPlan(.success(plan), owner: nil, personalScope: true)
                try SplitMenuBarTestFixtures.publishSplit(to: vm)
            } else {
                await provider.setFixture(.init(now: initial.now, balance: 1240, monthly: 760))
                await vm.refresh()
            }
            vc.updateUI()
            window.setContentSize(vc.preferredContentSize)
            vc.view.layoutSubtreeIfNeeded()
            let meter = try XCTUnwrap(views(vc.view).compactMap { $0 as? NSImageView }.first { $0.frame.width == 112 })
            let meterRow = try XCTUnwrap(meter.superview as? NSStackView)
            let readings = try XCTUnwrap(meterRow.arrangedSubviews.compactMap { $0 as? NSStackView }.first)
            let rows = readings.arrangedSubviews.filter { !$0.isHidden }
            XCTAssertEqual(rows.count, 2)
            for row in rows { XCTAssertEqual(row.frame.width, readings.frame.width, accuracy: 0.1, "legacy: \(legacy)") }
            let splitRows = try XCTUnwrap(meterRow.superview as? NSStackView)
            let detail = try XCTUnwrap(splitRows.arrangedSubviews.compactMap { $0 as? NSTextField }.first)
            XCTAssertFalse(detail.isHidden)
            XCTAssertEqual(detail.alignmentRect(forFrame: detail.frame).width, splitRows.frame.width,
                           accuracy: 0.1, "legacy: \(legacy)")
        }
    }

    func testZeroBalancePaidResetBelongsOnlyToVisibleMonthlyUsage() async throws {
        let now = Date()
        let reset = SharedUsageReading<SharedPaidPeriod>.empty.received(
            .init(start: now.addingTimeInterval(-3600), end: now.addingTimeInterval(3600)), at: now)
        for monthly in [0, 760] {
            let vm = await makeSharedUsageUIViewModel(.init(now: now, balance: 0, monthly: monthly, autoTopUp: true), test: self)
            let presentation = SharedUsagePresentation(mode: .sharedWeekly, snapshot: vm.sharedUsage.snapshot, paidReset: reset, at: now)
            if monthly == 0 { XCTAssertEqual(presentation.detailLines, ["Auto Top-up: On"]) }
            else {
                XCTAssertEqual(presentation.detailLines.count, 3)
                XCTAssertTrue(presentation.detailLines[0].hasPrefix("Monthly paid:"))
                XCTAssertTrue(presentation.detailLines[1].hasPrefix("Paid resets "))
                XCTAssertEqual(presentation.detailLines[2], "Auto Top-up: On")
            }
        }
    }

    func testZeroBalanceStaleStatusOnlyDescribesVisibleReadings() async throws {
        for (monthly, cap, auto, staleExpected) in [
            (0, 50, false, false), (760, 50, false, true), (0, 0, false, true), (0, 50, true, true),
        ] {
            let vm = await makeSharedUsageUIViewModel(.init(balance: 0, monthly: monthly, cap: cap, autoTopUp: auto), test: self)
            let current = try XCTUnwrap(vm.sharedUsage.snapshot)
            let snapshot = SharedUsageSnapshot(weekly: current.weekly, credit: current.credit,
                monthlyUsed: current.monthlyUsed.failed(.transport), paidCap: current.paidCap.failed(.transport),
                autoTopUp: current.autoTopUp.failed(.transport))
            let presentation = SharedUsagePresentation(mode: .sharedWeekly, snapshot: snapshot)
            XCTAssertEqual(presentation.status, staleExpected ? "Stale readings — refresh to verify." : nil)
            if !staleExpected { XCTAssertEqual(presentation.detailLines, []) }
        }
    }

    func testZeroPositiveZeroTransitionsUpdateSameViewsAndJumpReadout() async throws {
        let initial = SharedUsageUIFixture(balance: 0, purchased: 0, monthly: 0)
        let provider = SharedUsageUISequenceFixture(initial)
        let vm = await makeSharedUsageUIViewModel(initial, provider: provider, test: self)
        vm.setSplitOuterPool(.cursor)
        vm.setPopoverValueMode(.dollars)
        vm.setEstimatedLimitsEnabled(true)
        let vc = popover(vm)
        let display = SettingsAppearanceTabViewController(viewModel: vm)
        _ = display.view
        let app = AppDelegate(viewModel: vm)
        let jump = ActiveJump(emoji: "🚀", glow: true, fallbackSize: NSSize(width: 18, height: 18))
        var firstHeight: CGFloat?
        for balance in [0, 1240, 0] {
            await provider.setFixture(.init(now: initial.now, balance: balance, purchased: 2000, monthly: 0))
            await vm.refresh()
            vc.updateUI()
            display.updateUI()
            vc.view.layoutSubtreeIfNeeded()
            let visible = views(vc.view).filter { !$0.isHiddenOrHasHiddenAncestor }
            let creditVisible = visible.compactMap { ($0 as? NSTextField)?.stringValue }.contains("Prepaid credit")
            XCTAssertEqual(creditVisible, balance > 0)
            XCTAssertTrue(visible.compactMap { $0 as? NSButton }.contains { $0.title == "Manage Credits..." })
            let presentation = SharedUsagePresentation(mode: .sharedWeekly, snapshot: vm.sharedUsage.snapshot)
            XCTAssertEqual(presentation.readout.lower == nil, balance == 0)
            let preview = try XCTUnwrap(views(display.view).compactMap { $0 as? NSImageView }
                .first { $0.accessibilityLabel()?.hasPrefix("Outer: Weekly included") == true })
            for percentagesEnabled in [false, true] {
                vm.setSplitMenuBarPercentagesEnabled(percentagesEnabled)
                display.updateUI()
                XCTAssertEqual(try SplitMenuBarTestFixtures.pixels(XCTUnwrap(preview.image)),
                               try SplitMenuBarTestFixtures.pixels(app.currentStatusImage(activeJump: nil)))
                let glyph = CircularProgressIcon.makeEmojiImage(emoji: jump.emoji, size: jump.fallbackSize, glow: jump.glow)
                let expectedJump = percentagesEnabled ? SplitMenuBarRenderer.image(icon: glyph, readout: presentation.readout) : glyph
                XCTAssertEqual(try SplitMenuBarTestFixtures.pixels(app.currentStatusImage(activeJump: jump)),
                               try SplitMenuBarTestFixtures.pixels(expectedJump))
                XCTAssertEqual(try SplitMenuBarTestFixtures.pixels(XCTUnwrap(preview.image)),
                               try SplitMenuBarTestFixtures.pixels(app.currentStatusImage(activeJump: nil)))
            }
            if balance == 0 {
                if let firstHeight { XCTAssertEqual(vc.preferredContentSize.height, firstHeight, accuracy: 0.1) }
                else { firstHeight = vc.preferredContentSize.height }
                let weekly = try XCTUnwrap(visible.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Weekly included" })
                let row = try XCTUnwrap(weekly.superview?.superview)
                let readings = try XCTUnwrap(row.superview as? NSStackView)
                XCTAssertEqual(readings.fittingSize.height, row.fittingSize.height, accuracy: 0.1)
            } else {
                XCTAssertGreaterThan(vc.preferredContentSize.height, try XCTUnwrap(firstHeight))
            }
            XCTAssertEqual(vm.splitOuterPool, .cursor)
            XCTAssertEqual(vm.popoverValueMode, .dollars)
            XCTAssertTrue(vm.estimatedLimitsEnabled)
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
            XCTAssertTrue(strings.contains { $0.contains("Auto Top-up: Off") })
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
        for name in ["Outer ring", "Popover values", "Show estimated limits"] {
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

    func testSharedRecentPanelHidesRetainedLegacyRowsAndAllowsActivityRefresh() async throws {
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
        XCTAssertTrue(labels(vc.view).contains("Loading recent usage…"))
        XCTAssertTrue(views(vc.view).contains { $0.toolTip?.contains("Latest 30 activity entries") == true })
        let refresh = try XCTUnwrap(views(vc.view).compactMap { $0 as? RefreshFeedbackButton }.first { !$0.isHiddenOrHasHiddenAncestor })
        XCTAssertEqual(refresh.accessibilityLabel(), "Refresh recent usage")
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

    func testLegacySplitRowsReturnAfterZeroCreditSharedView() async throws {
        let vm = await makeSharedUsageUIViewModel(.init(balance: 0, purchased: 0, monthly: 0), test: self)
        let vc = popover(vm)
        let legacyPlan = try JSONDecoder().decode(CursorPlanInfoResponse.self, from: Data(#"{"isMerged":false}"#.utf8))
        vm.sharedUsage.acceptPlan(.success(legacyPlan), owner: nil, personalScope: true)
        try SplitMenuBarTestFixtures.publishSplit(to: vm)
        vc.updateUI()
        let visibleLabels = views(vc.view).filter { !$0.isHiddenOrHasHiddenAncestor }
            .compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(visibleLabels.contains("Cursor Models"), visibleLabels.description)
        XCTAssertTrue(visibleLabels.contains("Other Models"), visibleLabels.description)
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

    func testSharedRecentFailureDoesNotBorrowSuccessfulMeterFeedback() async throws {
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
        XCTAssertEqual(refresh.accessibilityValue() as? String, "Retry later")
    }

    func testSharedCurrentRowsChartAndPaidResetUseCurrentActivityAndPreserveTodayPreference() async throws {
        let vm = await makeSharedUsageUIViewModel(activity: SharedActivityUIFixture(), test: self)
        vm.setWeeklyChartStyle(.both)
        vm.setWeeklyChartMetric(.usageUnits)
        let vc = SettingsUsageTabViewController(viewModel: vm)
        _ = vc.view
        let table = try XCTUnwrap(views(vc.view).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(vc.numberOfRows(in: table), 4)
        XCTAssertFalse(table.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(vm.sharedActivity.recent.value?.entries[2].kind, .creditGrant)
        XCTAssertEqual(vm.sharedActivity.recent.value?.entries[3].kind, .adjustment)
        XCTAssertEqual(vm.effectiveWeeklyChartMetric, .tokens)
        XCTAssertEqual(vm.weeklyChartMetric, .usageUnits)
        XCTAssertEqual(vm.weeklyChartStyle, .both)
        XCTAssertEqual(vm.displayedWeeklyData?.last?.tokens, 84000)
        let strings = labels(popover(vm).view)
        XCTAssertTrue(strings.contains("Daily activity · UTC"), strings.description)
        XCTAssertTrue(strings.contains { $0.contains("Paid resets") && !$0.contains("unknown") })
        let display = SettingsAppearanceTabViewController(viewModel: vm)
        _ = display.view
        let metric = try XCTUnwrap(views(display.view).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Chart metric" })
        XCTAssertEqual(metric.selectedItem?.title, "Tokens")
        XCTAssertTrue(metric.isEnabled)
    }

    func testStaleSharedChartRetainsUTCDaySemantics() async {
        let vm = await makeSharedUsageUIViewModel(activity: SharedActivityUIFixture(), test: self)
        vm.sharedActivity.recordFailure()
        let vc = popover(vm)
        let status = views(vc.view).compactMap { $0 as? NSTextField }.first { $0.accessibilityIdentifier() == "weeklyChartStatus" }
        XCTAssertEqual(vm.displayedWeeklyChartStatus, .stale)
        XCTAssertTrue(status?.stringValue.contains("UTC") == true)
        XCTAssertTrue(status?.toolTip?.contains("UTC") == true)
        XCTAssertFalse(status?.isHiddenOrHasHiddenAncestor ?? true)
    }

    func testUnavailableSharedChartRetainsDailyUTCCaption() async throws {
        let vm = await makeSharedUsageUIViewModel(test: self)
        vm.sharedActivity.recordFailure()
        let vc = popover(vm)
        let status = try XCTUnwrap(views(vc.view).compactMap { $0 as? NSTextField }
            .first { $0.accessibilityIdentifier() == "weeklyChartStatus" })
        XCTAssertEqual(vm.displayedWeeklyChartStatus, .unavailable)
        XCTAssertEqual(status.stringValue, "Daily activity unavailable · UTC")
        XCTAssertTrue(status.toolTip?.contains("UTC calendar days") == true)
        XCTAssertFalse(status.isHiddenOrHasHiddenAncestor)
    }

    func testSharedAllowanceDetailUsesWeeklyUnitsWithoutChangingRowOrMoneyLayout() async throws {
        let vm = await makeSharedUsageUIViewModel(activity: SharedActivityUIFixture(), test: self)
        let vc = SettingsUsageTabViewController(viewModel: vm)
        _ = vc.view
        let table = try XCTUnwrap(views(vc.view).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(table.rowHeight, 44)
        let tokenColumn = try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == "tokens" })
        XCTAssertEqual(tokenColumn.width, 70)
        let included = try XCTUnwrap(vc.tableView(table, viewFor: tokenColumn, row: 1))
        let detail = views(included).compactMap { $0 as? NSTextField }.first { $0.stringValue.hasPrefix("≈") }
        XCTAssertEqual(detail?.stringValue, "≈0.677 pp")
        XCTAssertEqual(detail?.font?.pointSize, 10)
        XCTAssertEqual(detail?.textColor, .secondaryLabelColor)
        for points in [99.9999, 0.0000001] {
            detail?.stringValue = "≈\(SharedAllowanceFormatter.points(points)) pp"
            XCTAssertLessThanOrEqual(try XCTUnwrap(detail).intrinsicContentSize.width, tokenColumn.width - 8)
        }
        XCTAssertTrue(detail?.toolTip?.contains("weekly allowance") == true)
        XCTAssertTrue(detail?.toolTip?.contains("input/output/cache") == true)
        XCTAssertEqual(detail?.toolTip, detail?.accessibilityHelp())
        let paid = try XCTUnwrap(vc.tableView(table, viewFor: tokenColumn, row: 0))
        XCTAssertFalse(labels(paid).contains { $0.contains("pp") })
        XCTAssertTrue(labels(vc.view).contains { $0.contains("Reported week: 25%") && $0.contains("current mix") })
        vm.sharedUsage.recordFailure(CursorSharedAPIError.transport)
        vc.updateUI()
        let stale = try XCTUnwrap(vc.tableView(table, viewFor: tokenColumn, row: 1))
        XCTAssertFalse(labels(stale).contains { $0.contains("pp") })
        XCTAssertFalse(labels(vc.view).contains { $0.contains("Reported week:") })
    }

    func testReportedWeeklyFactSurvivesIneligibleOrUnavailableCalibration() async throws {
        for percent in [0.05, 100] {
            let vm = await makeSharedUsageUIViewModel(.init(weekly: percent), activity: SharedActivityUIFixture(), test: self)
            let vc = SettingsUsageTabViewController(viewModel: vm)
            _ = vc.view
            XCTAssertTrue(labels(vc.view).contains { $0.contains("Reported week:") })
            XCTAssertFalse(labels(vc.view).contains { $0.contains("Est. capacity") })
        }
        let vm = await makeSharedUsageUIViewModel(activity: SharedActivityFixture(), test: self)
        let vc = SettingsUsageTabViewController(viewModel: vm)
        _ = vc.view
        XCTAssertTrue(labels(vc.view).contains { $0.contains("Reported week: 25%") })
        XCTAssertFalse(labels(vc.view).contains { $0.contains("Est. capacity") })
    }

    func testRenderedAllowanceCellsDisappearWhenWeeklyBecomesStaleWithoutRowChanges() async throws {
        let vm = await makeSharedUsageUIViewModel(activity: SharedActivityUIFixture(), test: self)
        let vc = SettingsUsageTabViewController(viewModel: vm)
        let window = NSWindow(contentViewController: vc)
        window.isReleasedWhenClosed = false
        window.setContentSize(vc.view.fittingSize)
        defer { window.contentViewController = nil; window.close() }
        vc.view.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(views(vc.view).compactMap { $0 as? NSTableView }.first)
        let included = try XCTUnwrap(table.view(atColumn: 1, row: 1, makeIfNecessary: true))
        XCTAssertTrue(labels(included).contains("≈0.677 pp"))
        let candidate = vm.sharedActivity.recent.value
        vm.sharedUsage.recordFailure(CursorSharedAPIError.transport)
        vc.updateUI()
        vc.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(vm.sharedActivity.recent.value, candidate)
        let stale = try XCTUnwrap(table.view(atColumn: 1, row: 1, makeIfNecessary: true))
        XCTAssertFalse(labels(stale).contains { $0.contains("pp") })
    }

    func testSharedAmountCellsKeepCompactWidthAndExposeReportedUSD() async throws {
        let vm = await makeSharedUsageUIViewModel(activity: SharedActivityUIFixture(), test: self)
        let vc = SettingsUsageTabViewController(viewModel: vm)
        _ = vc.view
        let table = try XCTUnwrap(views(vc.view).compactMap { $0 as? NSTableView }.first)
        let column = try XCTUnwrap(table.tableColumns.first { $0.identifier.rawValue == "amount" })
        XCTAssertEqual(column.width, 79)
        for (index, expected, reported) in [
            (0, "$0.42", "$0.421"), (1, "Included", "$0.00"),
            (2, "−$5.00", "−$5.00"), (3, "−$0.12", "−$0.12"),
        ] {
            let cell = try XCTUnwrap(vc.tableView(table, viewFor: column, row: index))
            let amount = try XCTUnwrap(views(cell).compactMap { $0 as? NSTextField }.first)
            XCTAssertEqual(amount.stringValue, expected)
            XCTAssertEqual(amount.toolTip, "Reported amount: \(reported) USD")
            XCTAssertEqual(amount.accessibilityHelp(), "Reported amount: \(reported) USD")
        }
    }

    func testSharedSurfacesRenderSyntheticArtifacts() async throws {
        let normal = await makeSharedUsageUIViewModel(activity: SharedActivityUIFixture(), test: self)
        normal.notificationEnabled = true
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
