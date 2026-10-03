import AppKit
import XCTest
@testable import CursorMeter

@MainActor
final class SplitMenuBarSettingsTests: XCTestCase {
    private var savedDefaults: [String: Any] = [:]

    override func setUp() async throws {
        XCTAssertNotEqual(Bundle.main.bundleIdentifier, "com.woojin.CursorMeter")
        for key in SplitMenuBarTestFixtures.preferenceKeys {
            savedDefaults[key] = UserDefaults.standard.object(forKey: key)
        }
        UserDefaults.standard.removeObject(forKey: "splitMenuBarPercentagesEnabled")
    }

    override func tearDown() async throws {
        SplitMenuBarTestFixtures.restoreDefaults(savedDefaults)
    }

    func testMissingPreferenceDefaultsOffAndBothValuesRoundTrip() {
        let vm = SplitMenuBarTestFixtures.makeViewModel()
        XCTAssertFalse(vm.splitMenuBarPercentagesEnabled)
        for enabled in [true, false] {
            vm.setSplitMenuBarPercentagesEnabled(enabled)
            XCTAssertEqual(UserDefaults.standard.object(forKey: "splitMenuBarPercentagesEnabled") as? Bool, enabled)
            XCTAssertEqual(SplitMenuBarTestFixtures.makeViewModel().splitMenuBarPercentagesEnabled, enabled)
        }
    }

    func testPreferenceIsIndependentAndRetainedThroughLegacyAndLogout() throws {
        let vm = SplitMenuBarTestFixtures.makeViewModel()
        vm.setMenuBarDisplayMode(2)
        vm.setPopoverValueMode(.dollars)
        vm.setSplitOuterPool(.cursor)
        vm.setSplitMenuBarPercentagesEnabled(true)
        XCTAssertEqual(vm.menuBarDisplayMode, 2)
        XCTAssertEqual(vm.popoverValueMode, .dollars)
        XCTAssertEqual(vm.splitOuterPool, .cursor)
        try SplitMenuBarTestFixtures.publishSplit(to: vm)
        try SplitMenuBarTestFixtures.publishLegacy(to: vm)
        XCTAssertTrue(vm.splitMenuBarPercentagesEnabled)
        XCTAssertNil(vm.splitMenuBarReadout)
        vm.logout()
        XCTAssertTrue(vm.splitMenuBarPercentagesEnabled)
        XCTAssertEqual(vm.menuBarDisplayMode, 2)
        XCTAssertEqual(vm.popoverValueMode, .dollars)
        XCTAssertEqual(vm.splitOuterPool, .cursor)
        XCTAssertTrue(SplitMenuBarTestFixtures.makeViewModel().splitMenuBarPercentagesEnabled)
    }

    func testSwitchIsBetweenOuterRingAndPreviewAndOperatesWhileChecking() throws {
        _ = NSApplication.shared
        let vm = SplitMenuBarTestFixtures.makeViewModel()
        try SplitMenuBarTestFixtures.publishSplit(to: vm, checking: true)
        let vc = SettingsAppearanceTabViewController(viewModel: vm)
        _ = vc.view
        let toggle = try XCTUnwrap(SplitMenuBarTestFixtures.views(vc.view).compactMap { $0 as? NSSwitch }
            .first { $0.accessibilityLabel() == "Show percentages" })
        XCTAssertFalse(toggle.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(toggle.isEnabled)
        XCTAssertEqual(toggle.state, .off)
        toggle.state = .on
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(toggle.action), to: toggle.target, from: toggle))
        XCTAssertTrue(vm.splitMenuBarPercentagesEnabled)
        XCTAssertEqual(vm.splitMenuBarReadout, .init(upper: "—", lower: "—"))
        let labels = SplitMenuBarTestFixtures.views(vc.view).compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertLessThan(try XCTUnwrap(labels.firstIndex(of: "Outer ring")),
                          try XCTUnwrap(labels.firstIndex(of: "Show percentages")))
        XCTAssertLessThan(try XCTUnwrap(labels.firstIndex(of: "Show percentages")),
                          try XCTUnwrap(labels.firstIndex(of: "Outer: Other Models\nCenter: Cursor Models")))
        try SplitMenuBarTestFixtures.publishLegacy(to: vm)
        vc.updateUI()
        XCTAssertTrue(toggle.isHiddenOrHasHiddenAncestor)
        XCTAssertTrue(vm.splitMenuBarPercentagesEnabled)
    }

    func testPreviewKeepsRingDiameterAndContainerHeightWithExactLegend() throws {
        _ = NSApplication.shared
        let vm = SplitMenuBarTestFixtures.makeViewModel()
        try SplitMenuBarTestFixtures.publishSplit(to: vm)
        let vc = SettingsAppearanceTabViewController(viewModel: vm)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 600),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = vc
        defer { window.contentViewController = nil; window.close() }
        for enabled in [false, true, false] {
            vm.setSplitMenuBarPercentagesEnabled(enabled)
            vc.updateUI()
            vc.view.layoutSubtreeIfNeeded()
            let preview = try preview(in: vc.view)
            let image = try XCTUnwrap(preview.image)
            let requestedWidth = enabled ? image.size.width * 28 / 18 : 28
            let pixel = 1 / window.backingScaleFactor
            XCTAssertEqual(preview.frame.height, 35, accuracy: 0.01)
            XCTAssertEqual(try XCTUnwrap(preview.constraints.first { $0.firstAttribute == .width }).constant,
                           requestedWidth, accuracy: 0.001)
            XCTAssertEqual(preview.frame.width, requestedWidth, accuracy: pixel)
            XCTAssertEqual(image.size.height, enabled ? 22 : 18)
            XCTAssertEqual(preview.accessibilityLabel(), "Outer: Other Models\nCenter: Cursor Models")
            XCTAssertEqual(18 * preview.frame.width / image.size.width, 28,
                           accuracy: 18 * pixel / image.size.width)
        }
        vm.setSplitOuterPool(.cursor)
        vc.updateUI()
        XCTAssertEqual(try preview(in: vc.view).accessibilityLabel(), "Outer: Cursor Models\nCenter: Other Models")
    }

    func testPreviewHidesNumbersForRetainedLoggedOutData() throws {
        _ = NSApplication.shared
        let vm = SplitMenuBarTestFixtures.makeViewModel()
        try SplitMenuBarTestFixtures.publishSplit(to: vm)
        vm.setSplitMenuBarPercentagesEnabled(true)
        let vc = SettingsAppearanceTabViewController(viewModel: vm)
        _ = vc.view
        XCTAssertEqual(try preview(in: vc.view).image?.size.height, 22)
        vm.authState = .loginRequired
        vc.updateUI()
        XCTAssertNotNil(vm.splitUsage.snapshot)
        XCTAssertNotNil(vm.usageData)
        XCTAssertEqual(try preview(in: vc.view).image?.size, NSSize(width: 18, height: 18))
        XCTAssertEqual(try preview(in: vc.view).constraints.first { $0.firstAttribute == .height }?.constant, 35)
    }

    func testPreviewUsesNormalCircleEvenWhenLastJumpExists() throws {
        let vm = SplitMenuBarTestFixtures.makeViewModel()
        try SplitMenuBarTestFixtures.publishSplit(to: vm)
        vm.setSplitMenuBarPercentagesEnabled(true)
        let vc = SettingsAppearanceTabViewController(viewModel: vm)
        _ = vc.view
        let before = try SplitMenuBarTestFixtures.pixels(XCTUnwrap(preview(in: vc.view).image))
        vm.lastJump = SplitMenuBarTestFixtures.jump()
        vc.updateUI()
        XCTAssertEqual(try SplitMenuBarTestFixtures.pixels(XCTUnwrap(preview(in: vc.view).image)), before)
    }

    private func preview(in view: NSView) throws -> NSImageView {
        try XCTUnwrap(SplitMenuBarTestFixtures.views(view).compactMap { $0 as? NSImageView }
            .first { $0.accessibilityLabel()?.hasPrefix("Outer:") == true })
    }
}

@MainActor
enum SplitMenuBarTestFixtures {
    static let preferenceKeys = ["splitMenuBarPercentagesEnabled", "menuBarDisplayMode", "popoverValueMode",
                                 "splitOuterPool", "splitAlertThresholds", "ideAuthSuppressed"]

    static func restoreDefaults(_ saved: [String: Any]) {
        for key in preferenceKeys {
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
    }

    static func makeViewModel() -> UsageViewModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let vm = UsageViewModel(apiClient: CursorAPIClient(configuration: configuration))
        vm.updateCheckRunner = { .upToDate }
        vm.notificationEnabled = false
        vm.keychainDeleteHandler = {}
        vm.sessionExpiredNotifier = {}
        vm.authState = .loggedIn
        vm.splitOuterPool = .other
        vm.menuBarDisplayMode = 0
        vm.jumpEffectEnabled = true
        vm.jumpIntensity = .normal
        vm.jumpGlyphStyle = .classic
        return vm
    }

    @discardableResult
    static func publishSplit(to vm: UsageViewModel, cursor: Double? = 12, other: Double? = 42,
                             checking: Bool = false, withoutIdentity: Bool = false,
                             subject: String = "synthetic-menu-bar") throws -> UsageSummaryResponse {
        let json = #"{"billingCycleStart":"2026-10-01T00:00:00Z","billingCycleEnd":"2026-11-01T00:00:00Z","membershipType":"ultra","individualUsage":{"plan":{"enabled":true,"limit":40000,"autoPercentUsed":CURSOR,"apiPercentUsed":OTHER}}}"#
            .replacingOccurrences(of: "CURSOR", with: cursor.map(String.init(describing:)) ?? "null")
            .replacingOccurrences(of: "OTHER", with: other.map(String.init(describing:)) ?? "null")
        let summary = try JSONDecoder().decode(UsageSummaryResponse.self, from: Data(json.utf8))
        let usage = UsageResponse(models: [:], startOfMonth: nil)
        let user = withoutIdentity ? UserInfoResponse(email: nil, name: nil)
            : UserInfoResponse(email: "demo@example.com", name: "Demo User", sub: subject)
        vm.usageData = UsageDisplayData.from(summary: summary, usage: usage, userInfo: user,
                                            profile404Measurement: withoutIdentity ? .split : nil)
        vm.splitUsage.accept(summary: summary, usage: checking ? nil : usage,
                             userInfo: user, generation: 1, enterpriseScope: false)
        return summary
    }

    static func publishLegacy(to vm: UsageViewModel) throws {
        let summary = try JSONDecoder().decode(UsageSummaryResponse.self,
            from: Data(#"{"membershipType":"pro","individualUsage":{"plan":{"used":500,"limit":2000,"totalPercentUsed":25}}}"#.utf8))
        let usage = try JSONDecoder().decode(UsageResponse.self,
            from: Data(#"{"legacy":{"numRequests":120,"maxRequestUsage":500}}"#.utf8))
        let user = UserInfoResponse(email: "demo@example.com", name: "Demo User", sub: "synthetic-menu-bar")
        vm.usageData = UsageDisplayData.from(summary: summary, usage: usage, userInfo: user)
        vm.splitUsage.accept(summary: summary, usage: usage, userInfo: user, generation: 1, enterpriseScope: false)
    }

    static func jump(sequence: Int = 1) -> JumpEvent {
        JumpEvent(tier: .two, deltaCanonical: Double(sequence), deltaPct: 15,
                  mode: .percent, displayDelta: "+15.0%", timestamp: Date(timeIntervalSince1970: Double(sequence)))
    }

    static func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }

    static func pixels(_ image: NSImage) throws -> [UInt8] {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(image.size.width)), pixelsHigh: Int(ceil(image.size.height)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        image.draw(in: NSRect(origin: .zero, size: image.size))
        return Array(UnsafeBufferPointer(start: try XCTUnwrap(bitmap.bitmapData),
                                        count: bitmap.bytesPerRow * bitmap.pixelsHigh))
    }
}
