import AppKit
import XCTest
@testable import CursorMeter

@MainActor
final class IDEEncryptedLoginFlowTests: XCTestCase {
    private final class Provider: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private var calls: [Bool] = []
        var holdManual = false
        var manualResult: IDECredentialReadResult = .authorizationRequired
        var backgroundResult: IDECredentialReadResult = .authorizationRequired
        func read(_ interactive: Bool) -> IDECredentialReadResult {
            let snapshot = lock.withLock { () -> (Bool, IDECredentialReadResult) in
                calls.append(interactive)
                return (interactive && holdManual, interactive ? manualResult : backgroundResult)
            }
            if snapshot.0 { gate.wait() }
            return snapshot.1
        }
        func release() { gate.signal() }
        var snapshot: [Bool] { lock.withLock { calls } }
    }

    private func model(_ provider: Provider) -> UsageViewModel {
        let defaults = UserDefaults(suiteName: "IDEEncryptedLoginFlowTests.\(UUID().uuidString)")!
        let vm = makeTestUsageViewModel(refreshFeedback: RefreshFeedback(timing: .immediate), defaults: defaults)
        vm.ideCredentialResultProvider = { provider.read($0) }
        vm.keychainLoadHandler = { nil }
        vm.watchTickInterval = .milliseconds(10)
        vm.watchTimeout = .milliseconds(60)
        return vm
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition did not complete")
    }

    func testAvailabilityShowsConnectForEncryptedCredentialWithoutPrompt() async {
        let provider = Provider()
        let vm = model(provider)
        vm.refreshIDEAvailability()
        await waitUntil { vm.ideAuthorizationRequired }
        XCTAssertEqual(vm.ideCredentialAvailable, true)
        XCTAssertEqual(provider.snapshot, [false])
        let vc = MenuBarPopoverViewController(viewModel: vm, onLogin: {}, onSettings: {})
        _ = vc.view
        vc.updateUI()
        func children(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(children) }
        XCTAssertTrue(children(vc.view).compactMap { $0 as? NSButton }.contains { $0.title == "Connect Cursor IDE" })
        XCTAssertTrue(children(vc.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Cursor Safe Storage") })
        XCTAssertFalse(children(vc.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("is not signed in") })
    }

    func testUnreadableEncryptedCredentialKeepsOpenIDERecoveryAndSpecificReason() async {
        let provider = Provider()
        provider.backgroundResult = .encryptedUnavailable
        let vm = model(provider)
        vm.refreshIDEAvailability()
        await waitUntil { vm.ideEncryptedCredentialUnavailable }
        let vc = MenuBarPopoverViewController(viewModel: vm, onLogin: {}, onSettings: {})
        _ = vc.view
        vc.updateUI()
        func children(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(children) }
        XCTAssertTrue(children(vc.view).compactMap { $0 as? NSButton }.contains { $0.title == "Open Cursor IDE" })
        XCTAssertTrue(children(vc.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("encrypted sign-in could not be read") })
        XCTAssertFalse(children(vc.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("is not signed in") })
    }

    func testStartupRefreshAndSignInWatchStayNoninteractive() async {
        let provider = Provider()
        let vm = model(provider)
        await vm.checkExistingSession()?.value
        vm.beginIDESignInWatch()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(provider.snapshot.count > 1)
        XCTAssertFalse(provider.snapshot.contains(true))
        XCTAssertEqual(vm.authState, .loggedOut)
        XCTAssertTrue(vm.ideAuthorizationRequired)
        vm.stopAutoRefreshForTests()
    }

    func testManualConnectIsSingleFlightAndCancellationDoesNotLoop() async {
        let provider = Provider()
        provider.holdManual = true
        let vm = model(provider)
        vm.connectViaIDE()
        await waitUntil { provider.snapshot.contains(true) }
        vm.connectViaIDE()
        vm.refreshIDEAvailability()
        XCTAssertTrue(vm.isAuthorizingIDE)
        let vc = MenuBarPopoverViewController(viewModel: vm, onLogin: {}, onSettings: {})
        _ = vc.view
        vc.updateUI()
        func children(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(children) }
        let pending = children(vc.view).compactMap { $0 as? NSButton }.first { $0.title == "Connect Cursor IDE" }
        XCTAssertEqual(pending?.isEnabled, false)
        provider.release()
        await waitUntil { !vm.isAuthorizingIDE }
        XCTAssertEqual(provider.snapshot.filter { $0 }.count, 1)
        XCTAssertEqual(vm.authState, .loggedOut)
        XCTAssertTrue(vm.ideAuthorizationRequired)
        vc.updateUI()
        let retry = children(vc.view).compactMap { $0 as? NSButton }.first { $0.title == "Connect Cursor IDE" }
        XCTAssertEqual(retry?.isEnabled, true)
        try? await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(provider.snapshot.filter { $0 }.count, 1)
    }

    func testLogoutRejectsLateAuthorizedCredential() async {
        let provider = Provider()
        provider.holdManual = true
        provider.manualResult = .available(IDECredential(cookieHeader: "synthetic", expiresAt: .distantFuture))
        let vm = model(provider)
        vm.connectViaIDE()
        await waitUntil { provider.snapshot.contains(true) }
        vm.logout()
        provider.release()
        await waitUntil { !vm.isAuthorizingIDE }
        XCTAssertEqual(vm.authState, .loggedOut)
        XCTAssertTrue(vm.ideAuthSuppressed)
        XCTAssertNil(vm.activeAuthSource)
    }

    func testManualSuccessRereadsCurrentDatabaseBeforeAnyNetwork() async {
        let provider = Provider()
        provider.manualResult = .available(IDECredential(cookieHeader: "stale-synthetic", expiresAt: .distantFuture))
        provider.backgroundResult = .unavailable
        let vm = model(provider)
        vm.connectViaIDE()
        await waitUntil { provider.snapshot.contains(false) && !vm.isLoading && !vm.isAuthorizingIDE }
        XCTAssertEqual(vm.authState, .loggedOut)
        XCTAssertNil(vm.activeAuthSource)
        XCTAssertEqual(provider.snapshot.first, true)
        vm.stopAutoRefreshForTests()
    }
    func testManualAuthorizationUsesFreshCredentialForSuccessfulTransport() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let defaults = UserDefaults(suiteName: "IDEEncryptedLoginSuccess.\(UUID().uuidString)")!
        let vm = makeTestUsageViewModel(apiClient: CursorAPIClient(configuration: configuration),
            refreshFeedback: RefreshFeedback(timing: .immediate), defaults: defaults)
        let fresh = IDECredential(cookieHeader: "WorkosCursorSessionToken=user_new%3A%3AJ.W.T", expiresAt: .distantFuture)
        let provider = Provider()
        provider.manualResult = .available(IDECredential(cookieHeader: "stale", expiresAt: .distantFuture))
        provider.backgroundResult = .available(fresh)
        vm.ideCredentialResultProvider = { provider.read($0) }
        MockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), fresh.cookieHeader)
            let url = request.url!
            let payload: String
            switch url.path {
            case "/api/usage-summary":
                payload = #"{"billingCycleStart":"2026-11-01T00:00:00Z","billingCycleEnd":"2026-12-01T00:00:00Z","membershipType":"pro","limitType":"user","individualUsage":{"plan":{"enabled":true,"used":8,"limit":2000,"remaining":1992,"totalPercentUsed":0.4}}}"#
            case "/api/auth/me": payload = #"{"sub":"auth0|user_new","name":"Synthetic"}"#
            default: payload = "{}"
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        defer { MockURLProtocol.requestHandler = nil; vm.stopAutoRefreshForTests() }
        vm.connectViaIDE()
        await waitUntil { vm.activeAuthSource == .cursorIDE && !vm.isLoading }
        XCTAssertEqual(vm.authState, .loggedIn)
        XCTAssertEqual(provider.snapshot.filter { $0 }.count, 1)
        XCTAssertFalse(vm.ideAuthorizationRequired)
    }

    func testEncryptedRecoveryRendersSyntheticArtifacts() throws {
        for (name, pending, unavailable) in [("encrypted-access", false, false), ("encrypted-pending", true, false), ("encrypted-unavailable", false, true)] {
            let vm = makeTestUsageViewModel(defaults: UserDefaults(suiteName: "IDERecoveryCapture.\(UUID().uuidString)")!)
            vm.ideCredentialAvailable = !unavailable
            vm.ideAuthorizationRequired = !unavailable
            vm.ideEncryptedCredentialUnavailable = unavailable
            vm.isAuthorizingIDE = pending
            let controller = MenuBarPopoverViewController(viewModel: vm, onLogin: {}, onSettings: {})
            _ = controller.view
            controller.updateUI()
            let size = controller.preferredContentSize
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["CM_UI_DARK"] == "1" ? .darkAqua : .aqua)
            controller.view.appearance = window.appearance
            window.contentViewController = controller
            window.setContentSize(size)
            controller.view.layoutSubtreeIfNeeded()
            defer { window.contentViewController = nil; window.close() }
            XCTAssertEqual(size.width, 260, accuracy: 1)
            XCTAssertLessThan(size.height, 700)
            let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
            window.appearance?.performAsCurrentDrawingAppearance {
                controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
            }
            let contents = NSImage(size: size)
            contents.addRepresentation(bitmap)
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor.windowBackgroundColor.setFill()
                rect.fill()
                contents.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
                return true
            }
            var png: Data?
            window.appearance?.performAsCurrentDrawingAppearance {
                png = image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?.representation(using: .png, properties: [:])
            }
            let data = try XCTUnwrap(png)
            XCTAssertGreaterThan(data.count, 1000)
            if let directory = ProcessInfo.processInfo.environment["CM_UI_ARTIFACT_DIR"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                try data.write(to: url.appendingPathComponent("\(name).png"))
            }
        }
    }

}
