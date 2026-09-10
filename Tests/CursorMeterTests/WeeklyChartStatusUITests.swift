import AppKit
import XCTest
@testable import CursorMeter

@MainActor
final class WeeklyChartStatusUITests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeViewModel() -> UsageViewModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let vm = UsageViewModel(apiClient: CursorAPIClient(configuration: configuration))
        vm.updateCheckRunner = { .upToDate }
        vm.keychainDeleteHandler = {}
        vm.sessionExpiredNotifier = {}
        vm.refreshFailingNotifier = {}
        vm.ideAppPresenceCheck = { false }
        vm.notificationEnabled = false
        vm.weeklyChartEnabled = true
        vm.weeklyChartMetric = .amount
        vm.testHook_setCookieHeader("WorkosCursorSessionToken=synthetic-ui-fixture")
        vm.authState = .loggedIn
        return vm
    }

    private nonisolated static func handler(weeklyStatus: Int) -> (URLRequest) throws -> (HTTPURLResponse, Data) {
        { request in
            let url = request.url!
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            switch url.path {
            case "/api/usage-summary":
                let json = """
                {"membershipType":"ultra","limitType":"user","isUnlimited":false,
                 "individualUsage":{"plan":{"enabled":true,"used":3250,"limit":40000,"remaining":36750,"totalPercentUsed":8.125}}}
                """
                return (ok, Data(json.utf8))
            case "/api/auth/me":
                return (ok, Data("{\"email\":\"demo@example.com\",\"name\":\"Demo User\"}".utf8))
            case "/api/usage":
                return (ok, Data("{}".utf8))
            case "/api/dashboard/get-filtered-usage-events":
                guard weeklyStatus == 200 else {
                    return (HTTPURLResponse(url: url, statusCode: weeklyStatus, httpVersion: nil, headerFields: nil)!, Data())
                }
                let events = (0..<7).map { offset -> String in
                    let day = Calendar.current.date(byAdding: .day, value: -offset, to: Date())!
                    let timestamp = Int(day.timeIntervalSince1970 * 1000)
                    let cents = [300, 400, 180, 650, 210, 350, 120][offset]
                    let units = [150, 100, 90, 210, 80, 160, 70][offset]
                    return "{\"timestamp\":\"\(timestamp)\",\"requestsCosts\":\(units),\"chargedCents\":\(cents),\"kind\":\"USAGE_EVENT_KIND_CUSTOM_SUBSCRIPTION\"}"
                }.joined(separator: ",")
                return (ok, Data("{\"totalUsageEventsCount\":7,\"usageEventsDisplay\":[\(events)]}".utf8))
            default:
                return (HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!, Data())
            }
        }
    }

    private func visibleLabels(in view: NSView) -> [NSTextField] {
        guard !view.isHidden else { return [] }
        return (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { visibleLabels(in: $0) }
    }

    private func assertStatusLayout(
        _ vm: UsageViewModel,
        status: WeeklyChartStatus,
        captureName: String
    ) throws {
        _ = NSApplication.shared
        let vc = MenuBarPopoverViewController(viewModel: vm, onLogin: {}, onSettings: {})
        _ = vc.view
        vc.view.wantsLayer = true
        vc.view.layer?.backgroundColor = NSColor.white.cgColor
        vc.updateUI()
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: vc.preferredContentSize),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = vc
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(vc.preferredContentSize)
        vc.view.layoutSubtreeIfNeeded()
        defer {
            window.contentViewController = nil
            window.close()
        }

        let prefix = status == .stale ? "Weekly data:" : "Weekly activity unavailable"
        let labels = visibleLabels(in: vc.view)
        let statusLabel = try XCTUnwrap(labels.first { $0.stringValue.hasPrefix(prefix) })
        XCTAssertLessThanOrEqual(vc.testHook_contentFittingWidth(), 240)
        XCTAssertLessThanOrEqual(statusLabel.alignmentRect(forFrame: statusLabel.frame).width, 240)
        try capture(vc.view, name: captureName)

        vm.weeklyChartEnabled = false
        vc.updateUI()
        XCTAssertFalse(visibleLabels(in: vc.view).contains { $0.stringValue.hasPrefix(prefix) })

        vm.weeklyChartEnabled = true
        vm.authState = .loginRequired
        vm.usageData = nil
        vc.updateUI()
        XCTAssertFalse(visibleLabels(in: vc.view).contains { $0.stringValue.hasPrefix(prefix) })
    }

    private func captureReadyViews(_ vm: UsageViewModel) throws {
        guard ProcessInfo.processInfo.environment["CM_WEEKLY_CAPTURE_DIR"] != nil else { return }
        _ = NSApplication.shared
        for metric in WeeklyChartMetric.allCases {
            vm.weeklyChartMetric = metric
            let vc = MenuBarPopoverViewController(viewModel: vm, onLogin: {}, onSettings: {})
            _ = vc.view
            vc.updateUI()
            try captureController(vc, size: vc.preferredContentSize, name: "weekly-\(metric.rawValue)-native")
        }
        vm.weeklyChartMetric = .amount
        let settings = SettingsAppearanceTabViewController(viewModel: vm)
        _ = settings.view
        settings.updateUI()
        settings.view.layoutSubtreeIfNeeded()
        try captureController(settings, size: settings.view.fittingSize, name: "weekly-settings-native")
    }

    private func captureController(_ vc: NSViewController, size: NSSize, name: String) throws {
        vc.view.wantsLayer = true
        vc.view.layer?.backgroundColor = NSColor.white.cgColor
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = vc
        window.appearance = NSAppearance(named: .aqua)
        window.setContentSize(size)
        vc.view.layoutSubtreeIfNeeded()
        defer {
            window.contentViewController = nil
            window.close()
        }
        try capture(vc.view, name: name)
    }

    private func capture(_ view: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["CM_WEEKLY_CAPTURE_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let destination = directory.appendingPathComponent(name).appendingPathExtension("png")
        try png.write(to: destination)
        print("Native weekly chart capture: \(destination.path)")
    }

    func testStaleStatusFitsAndHidesWhenDisabledOrSignedOut() async throws {
        let vm = makeViewModel()
        MockURLProtocol.requestHandler = Self.handler(weeklyStatus: 200)
        await vm.refresh()
        try captureReadyViews(vm)
        MockURLProtocol.requestHandler = Self.handler(weeklyStatus: 500)
        await vm.refresh()
        await vm.refresh()
        XCTAssertEqual(vm.weeklyChartStatus, .stale)
        try assertStatusLayout(vm, status: .stale, captureName: "weekly-stale-native")
    }

    func testUnavailableStatusFitsAndHidesWhenDisabledOrSignedOut() async throws {
        let vm = makeViewModel()
        MockURLProtocol.requestHandler = Self.handler(weeklyStatus: 500)
        await vm.refresh()
        XCTAssertEqual(vm.weeklyChartStatus, .unavailable)
        try assertStatusLayout(vm, status: .unavailable, captureName: "weekly-unavailable-native")
    }
}
