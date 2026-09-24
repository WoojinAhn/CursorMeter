import AppKit
import XCTest
@testable import CursorMeter

@MainActor
final class RecentUsageUITests: XCTestCase {
    private func makeViewModel() -> UsageViewModel {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let vm = UsageViewModel(apiClient: CursorAPIClient(configuration: config))
        vm.updateCheckRunner = { .upToDate }
        vm.keychainDeleteHandler = {}
        vm.sessionExpiredNotifier = {}
        vm.refreshFailingNotifier = {}
        vm.notificationEnabled = false
        vm.authState = .loggedIn
        return vm
    }

    private func labels(in view: NSView) -> [String] {
        let own = (view as? NSTextField).map { [$0.stringValue] } ?? []
        return own + view.subviews.flatMap { labels(in: $0) }
    }

    private func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { self.table(in: $0) }.first
    }

    private func allViews(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { allViews(in: $0) }
    }

    private func publish(_ entries: [RecentUsageEntry], to vm: UsageViewModel, at cachedAt: Date) throws -> RecentUsageController.Context {
        vm.recentUsage.beginSession(generation: 1)
        let context = try XCTUnwrap(vm.recentUsage.selectCredential(
            cookieHeader: "WorkosCursorSessionToken=synthetic-ui", generation: 1, attemptID: 1))
        XCTAssertTrue(vm.recentUsage.validateIdentity(subject: "demo", scope: .personal, context: context))
        XCTAssertTrue(vm.recentUsage.publish(candidate: RecentUsageCandidate(entries: entries, cachedAt: cachedAt), context: context))
        return context
    }

    func testFeedbackButtonUsesConsumerOutcomeAndStableAccessibilityName() {
        _ = NSApplication.shared
        let meter = RefreshFeedbackButton(style: .iconOnly, consumer: .meter)
        let recent = RefreshFeedbackButton(style: .labeled, consumer: .recent)
        meter.render(phase: .result(meter: .success, recent: .failure), isReady: false,
                     attempt: nil, isAuthenticated: true, reduceMotion: true)
        recent.render(phase: .result(meter: .success, recent: .failure), isReady: false,
                      attempt: nil, isAuthenticated: true, reduceMotion: true)
        XCTAssertEqual(meter.accessibilityLabel(), "Refresh usage")
        XCTAssertEqual(recent.accessibilityLabel(), "Refresh recent usage")
        XCTAssertEqual(meter.accessibilityValue() as? String, "Updated")
        XCTAssertEqual(recent.accessibilityValue() as? String, "Retry later")
        XCTAssertFalse(meter.isEnabled)
        XCTAssertFalse(recent.isEnabled)
        recent.render(phase: .idle, isReady: true, attempt: nil, isAuthenticated: false, reduceMotion: true)
        XCTAssertFalse(recent.isEnabled)
        meter.frame = NSRect(x: 0, y: 0, width: 26, height: 24)
        meter.layoutSubtreeIfNeeded()
        XCTAssertTrue(meter.hitTest(NSPoint(x: 13, y: 12)) === meter)
    }

    func testFeedbackRotationIsIdempotentAndRespectsReduceMotion() throws {
        _ = NSApplication.shared
        let button = RefreshFeedbackButton(style: .iconOnly, consumer: .meter)
        let glyph = try XCTUnwrap(allViews(in: button).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "↻" })
        button.render(phase: .updating, isReady: false, attempt: nil,
                      isAuthenticated: true, reduceMotion: false)
        let first = try XCTUnwrap(glyph.layer?.animation(forKey: "refreshRotation"))
        button.render(phase: .updating, isReady: false, attempt: nil,
                      isAuthenticated: true, reduceMotion: false)
        let second = try XCTUnwrap(glyph.layer?.animation(forKey: "refreshRotation"))
        XCTAssertEqual(first.beginTime, second.beginTime)
        button.render(phase: .updating, isReady: false, attempt: nil,
                      isAuthenticated: true, reduceMotion: true)
        XCTAssertNil(glyph.layer?.animation(forKey: "refreshRotation"))
    }

    func testFeedbackSubviewColorsTrackReadinessWithoutPhaseChange() throws {
        _ = NSApplication.shared
        for style in [RefreshFeedbackButton.Style.iconOnly, .labeled] {
            let button = RefreshFeedbackButton(style: style, consumer: .recent)
            let glyph = try XCTUnwrap(button.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "↻" })
            let caption = try XCTUnwrap(button.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Refresh" })
            button.render(phase: .idle, isReady: true, attempt: nil, isAuthenticated: true, reduceMotion: true)
            XCTAssertEqual(glyph.textColor, .secondaryLabelColor)
            XCTAssertEqual(caption.textColor, .labelColor)
            button.render(phase: .idle, isReady: false, attempt: nil, isAuthenticated: true, reduceMotion: true)
            XCTAssertEqual(glyph.textColor, .disabledControlTextColor)
            XCTAssertEqual(caption.textColor, .disabledControlTextColor)
            button.render(phase: .idle, isReady: true, attempt: nil, isAuthenticated: false, reduceMotion: true)
            XCTAssertEqual(glyph.textColor, .disabledControlTextColor)
            XCTAssertEqual(caption.textColor, .disabledControlTextColor)
            button.render(phase: .idle, isReady: true, attempt: nil, isAuthenticated: true, reduceMotion: true)
            XCTAssertEqual(glyph.textColor, .secondaryLabelColor)
            XCTAssertEqual(caption.textColor, .labelColor)
        }
    }

    func testReduceMotionShowsDistinctStaticUpdatingGlyphInBothStyles() throws {
        _ = NSApplication.shared
        for style in [RefreshFeedbackButton.Style.iconOnly, .labeled] {
            let button = RefreshFeedbackButton(style: style, consumer: .recent)
            let glyph = try XCTUnwrap(button.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "↻" })
            button.render(phase: .idle, isReady: true, attempt: nil, isAuthenticated: true, reduceMotion: true)
            let idleGlyph = glyph.stringValue
            button.render(phase: .updating, isReady: false, attempt: nil, isAuthenticated: true, reduceMotion: true)
            XCTAssertEqual(glyph.stringValue, "…")
            XCTAssertNotEqual(glyph.stringValue, idleGlyph)
            XCTAssertEqual(button.accessibilityValue() as? String, "Updating")
            XCTAssertNil(glyph.layer?.animation(forKey: "refreshRotation"))
        }
    }

    func testLabeledFeedbackCaptionsFitInFixedNativeLayout() throws {
        _ = NSApplication.shared
        let button = RefreshFeedbackButton(style: .labeled, consumer: .recent)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(button)
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 10),
            button.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 10),
        ])
        defer { window.close() }
        let caption = try XCTUnwrap(button.subviews.compactMap { $0 as? NSTextField }.first { $0.stringValue == "Refresh" })
        let cases: [(RefreshPhase, String)] = [
            (.idle, "Refresh"), (.updating, "Updating"),
            (.result(meter: .success, recent: .success), "Updated"),
            (.result(meter: .success, recent: .failure), "Retry later"),
        ]
        for reduceMotion in [false, true] {
            for (phase, expected) in cases {
                button.render(phase: phase, isReady: true, attempt: nil,
                              isAuthenticated: true, reduceMotion: reduceMotion)
                window.contentView?.layoutSubtreeIfNeeded()
                button.layoutSubtreeIfNeeded()
                XCTAssertEqual(caption.stringValue, expected)
                // Auto Layout constrains alignment rects; native bezel padding varies by macOS.
                let buttonAlignmentRect = button.alignmentRect(forFrame: button.frame)
                XCTAssertEqual(buttonAlignmentRect.width, 100, accuracy: 0.5)
                XCTAssertEqual(buttonAlignmentRect.height, 26, accuracy: 0.5)
                XCTAssertGreaterThanOrEqual(caption.alignmentRect(forFrame: caption.frame).width + 0.01,
                                           caption.intrinsicContentSize.width,
                                            "\(expected) must fit its native text field")
            }
        }
    }

    func testAnimatedGlyphLayerRotatesAroundItsActualCenterInWindow() throws {
        _ = NSApplication.shared
        let button = RefreshFeedbackButton(style: .labeled, consumer: .recent)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(button)
        button.frame = NSRect(x: 20, y: 20, width: 90, height: 26)
        window.contentView?.layoutSubtreeIfNeeded()
        button.layoutSubtreeIfNeeded()
        defer { window.close() }
        let glyph = try XCTUnwrap(allViews(in: button).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "↻" })
        let layer = try XCTUnwrap(glyph.layer)
        let originalFrame = layer.frame
        button.render(phase: .updating, isReady: false, attempt: nil,
                      isAuthenticated: true, reduceMotion: false)
        XCTAssertNotNil(layer.animation(forKey: "refreshRotation"))
        XCTAssertEqual(layer.anchorPoint.x, 0.5, accuracy: 0.001)
        XCTAssertEqual(layer.anchorPoint.y, 0.5, accuracy: 0.001)
        XCTAssertEqual(layer.position.x, glyph.frame.midX, accuracy: 0.5)
        XCTAssertEqual(layer.position.y, glyph.frame.midY, accuracy: 0.5)
        XCTAssertEqual(layer.frame, originalFrame)
    }

    func testInitialAndEmptyStatesDistinguishUnknownFromZero() throws {
        _ = NSApplication.shared
        let vm = makeViewModel()
        let vc = SettingsUsageTabViewController(viewModel: vm)
        _ = vc.view
        vc.updateUI()
        XCTAssertTrue(labels(in: vc.view).contains("Loading recent usage…"))
        XCTAssertFalse(labels(in: vc.view).contains("0 requests"))
        XCTAssertFalse(labels(in: vc.view).contains { $0.hasPrefix("Cached ") })
        let cachedAt = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try publish([], to: vm, at: cachedAt)
        vc.updateUI()
        XCTAssertTrue(labels(in: vc.view).contains("No recent usage"))
        XCTAssertTrue(labels(in: vc.view).contains("0 requests"))
        XCTAssertTrue(labels(in: vc.view).contains { $0.hasPrefix("Cached ") })
    }

    func testFailureRetainsRowsAndOriginalCacheTime() throws {
        _ = NSApplication.shared
        let vm = makeViewModel()
        let entry = RecentUsageEntry(date: Date(timeIntervalSince1970: 1_700_000_000),
                                     model: "A long model name that must remain available in accessibility",
                                     kind: .included, tokens: 1_234_567, chargedCents: 12.34)
        let cachedAt = Date(timeIntervalSince1970: 1_700_000_100)
        _ = try publish([entry], to: vm, at: cachedAt)
        let vc = SettingsUsageTabViewController(viewModel: vm)
        _ = vc.view
        vc.updateUI()
        let originalCacheLabel = try XCTUnwrap(labels(in: vc.view).first { $0.hasPrefix("Cached ") })
        XCTAssertEqual(table(in: vc.view)?.numberOfRows, 1)
        let retry = try XCTUnwrap(vm.recentUsage.selectCredential(
            cookieHeader: "WorkosCursorSessionToken=synthetic-ui", generation: 1, attemptID: 2))
        vm.recentUsage.recordFailure(context: retry)
        vc.updateUI()
        XCTAssertEqual(table(in: vc.view)?.numberOfRows, 1)
        XCTAssertTrue(labels(in: vc.view).contains("Couldn’t update. Showing saved data."))
        XCTAssertTrue(labels(in: vc.view).contains(originalCacheLabel))
        _ = vm.refreshFeedback.begin(generation: 1)
        vc.updateUI()
        XCTAssertTrue(labels(in: vc.view).contains("Updating…"))
    }

    func testRowsKeepFixedViewportAndExposeFullModelAndTokens() throws {
        _ = NSApplication.shared
        let vm = makeViewModel()
        let model = String(repeating: "long-model-", count: 10)
        let entries = (0..<30).map { offset in
            RecentUsageEntry(date: Date(timeIntervalSince1970: Double(1_700_000_000 - offset)),
                             model: model, kind: .included, tokens: 1_234_567, chargedCents: 12.34)
        }
        _ = try publish(entries, to: vm, at: Date(timeIntervalSince1970: 1_700_000_100))
        let vc = SettingsUsageTabViewController(viewModel: vm)
        _ = vc.view
        vc.updateUI()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: vc.view.fittingSize),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = vc
        window.setContentSize(vc.view.fittingSize)
        vc.view.layoutSubtreeIfNeeded()
        defer { window.contentViewController = nil; window.close() }
        let table = try XCTUnwrap(table(in: vc.view))
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        XCTAssertEqual(table.numberOfRows, 30)
        XCTAssertEqual(table.rowHeight, 52)
        XCTAssertEqual(scroll.frame.height, 312, accuracy: 1)
        XCTAssertEqual(vc.view.fittingSize.width, 480, accuracy: 1)
        let modelCell = try XCTUnwrap(vc.tableView(table, viewFor: table.tableColumns[0], row: 0))
        let tokenCell = try XCTUnwrap(vc.tableView(table, viewFor: table.tableColumns[1], row: 0))
        let modelLabel = try XCTUnwrap(modelCell.subviews.first as? NSTextField)
        let tokenLabel = try XCTUnwrap(tokenCell.subviews.first as? NSTextField)
        XCTAssertEqual(modelLabel.accessibilityLabel(), model)
        XCTAssertEqual(modelLabel.toolTip, model)
        XCTAssertEqual(tokenLabel.accessibilityHelp(), "1234567 tokens")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 208))
        scroll.reflectScrolledClipView(scroll.contentView)
        let offset = scroll.contentView.bounds.origin.y
        XCTAssertGreaterThan(offset, 0)
        _ = vm.refreshFeedback.begin(generation: 1)
        vc.updateUI()
        XCTAssertEqual(scroll.contentView.bounds.origin.y, offset,
                       "Feedback phase changes must not reload the table")
    }

    func testFailedWithoutSnapshotDoesNotInventRowCountOrCacheTime() throws {
        _ = NSApplication.shared
        let vm = makeViewModel()
        vm.recentUsage.beginSession(generation: 1)
        let context = try XCTUnwrap(vm.recentUsage.selectCredential(
            cookieHeader: "WorkosCursorSessionToken=synthetic-ui", generation: 1, attemptID: 1))
        vm.recentUsage.recordFailure(context: context)
        let vc = SettingsUsageTabViewController(viewModel: vm)
        _ = vc.view
        vc.updateUI()
        let text = labels(in: vc.view)
        XCTAssertTrue(text.contains("Unable to load recent usage."))
        XCTAssertTrue(text.contains("Couldn’t update. Try again later."))
        XCTAssertFalse(text.contains("0 requests"))
        XCTAssertFalse(text.contains { $0.hasPrefix("Cached ") })
    }

    func testMissingModelUsesUnavailableMarker() throws {
        _ = NSApplication.shared
        let vm = makeViewModel()
        let entries = [nil, ""].map { model in
            RecentUsageEntry(date: Date(timeIntervalSince1970: 1_700_000_000), model: model,
                             kind: .included, tokens: nil, chargedCents: nil)
        }
        _ = try publish(entries, to: vm, at: Date(timeIntervalSince1970: 1_700_000_100))
        let vc = SettingsUsageTabViewController(viewModel: vm)
        _ = vc.view
        let table = try XCTUnwrap(table(in: vc.view))
        for row in 0..<2 {
            let cell = try XCTUnwrap(vc.tableView(table, viewFor: table.tableColumns[0], row: row))
            let model = try XCTUnwrap(cell.subviews.first as? NSTextField)
            XCTAssertEqual(model.stringValue, "—")
            XCTAssertEqual(model.accessibilityLabel(), "—")
        }
    }

    func testTimeZoneActionAndTabReopenUseCacheWithoutHTTP() async throws {
        _ = NSApplication.shared
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func hit() { lock.withLock { value += 1 } }
            var count: Int { lock.withLock { value } }
        }
        let requests = Counter()
        let unexpectedRequest = expectation(description: "Time-zone action and tab reopen make no HTTP request")
        unexpectedRequest.isInverted = true
        MockURLProtocol.requestHandler = { request in
            requests.hit()
            unexpectedRequest.fulfill()
            throw URLError(.badServerResponse)
        }
        defer { MockURLProtocol.requestHandler = nil }
        let key = "recentUsageTimeZone"
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        let vm = makeViewModel()
        vm.testHook_setCookieHeader("WorkosCursorSessionToken=synthetic-ui")
        let cachedAt = Date(timeIntervalSince1970: 1_700_000_100)
        _ = try publish([RecentUsageEntry(date: cachedAt, model: "model", kind: .included,
                                          tokens: 100, chargedCents: 1)], to: vm, at: cachedAt)
        let root = SettingsTabViewController(viewModel: vm)
        root.selectedTabViewItemIndex = 3
        let first = try XCTUnwrap(root.tabViewItems[3].viewController as? SettingsUsageTabViewController)
        first.updateUI()
        let control = try XCTUnwrap(allViews(in: first.view).compactMap { $0 as? NSSegmentedControl }
            .first { $0.accessibilityLabel() == "Time zone" })
        control.selectedSegment = 1
        XCTAssertTrue(control.sendAction(control.action!, to: control.target))
        XCTAssertEqual(vm.recentUsageTimeZone, .utc)
        XCTAssertEqual(vm.recentUsage.snapshot?.candidate.cachedAt, cachedAt)
        let utcHelp = try XCTUnwrap(allViews(in: first.view).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == "UTC" }?.accessibilityHelp())
        XCTAssertEqual(utcHelp, "UTC")
        XCTAssertEqual(control.accessibilityHelp(), "UTC")
        XCTAssertEqual(control.toolTip, "UTC")
        let reopened = SettingsTabViewController(viewModel: vm)
        reopened.selectedTabViewItemIndex = 3
        let second = try XCTUnwrap(reopened.tabViewItems[3].viewController as? SettingsUsageTabViewController)
        second.updateUI()
        XCTAssertEqual(table(in: second.view)?.numberOfRows, 1)
        XCTAssertEqual(vm.recentUsage.snapshot?.candidate.cachedAt, cachedAt)
        XCTAssertEqual(requests.count, 0)
        control.selectedSegment = 0
        XCTAssertTrue(control.sendAction(control.action!, to: control.target))
        let localID = RecentUsageFormatter.zoneIdentifier(mode: .local)
        XCTAssertEqual(control.accessibilityHelp(), localID)
        XCTAssertEqual(control.toolTip, localID)
        let localLabel = try XCTUnwrap(allViews(in: first.view).compactMap { $0 as? NSTextField }
            .first { $0.stringValue == RecentUsageFormatter.zoneLabel(mode: .local) && $0.toolTip == localID })
        XCTAssertEqual(localLabel.accessibilityHelp(), localID)
        vm.systemTimeZoneDidChange()
        first.updateUI()
        XCTAssertEqual(control.accessibilityHelp(), RecentUsageFormatter.zoneIdentifier(mode: .local))
        await fulfillment(of: [unexpectedRequest], timeout: 0.15)
        XCTAssertEqual(requests.count, 0)
        XCTAssertNil(vm.refreshFeedback.currentAttempt)
        XCTAssertEqual(vm.recentUsage.snapshot?.candidate.cachedAt, cachedAt)
    }
}
