import AppKit
import XCTest
@testable import CursorMeter

/// #93: the Settings window must tear down when closed. Keeping the strong
/// `settingsWindow` reference after close retained ~12 MB of view hierarchy
/// and layer backing that reopening never reused (a fresh window is built).
@MainActor
final class SettingsWindowLifecycleTests: XCTestCase {

    func test_injectedModelDrivesUsageFeedbackAfterSettingsReopens() throws {
        let viewModel = UsageViewModel()
        viewModel.updateCheckRunner = { .upToDate }
        viewModel.authState = .loggedIn
        _ = viewModel.refreshFeedback.begin(generation: 1)
        let delegate = AppDelegate(viewModel: viewModel)

        func refreshButton(in view: NSView) -> NSButton? {
            if let button = view as? NSButton,
               button.accessibilityLabel() == "Refresh recent usage" {
                return button
            }
            return view.subviews.lazy.compactMap { refreshButton(in: $0) }.first
        }

        for _ in 0..<2 {
            delegate.openSettings()
            let tabs = try XCTUnwrap(delegate.settingsWindow?.contentViewController as? SettingsTabViewController)
            let usage = try XCTUnwrap(tabs.tabViewItems.last?.viewController)
            let button = try XCTUnwrap(refreshButton(in: usage.view))
            XCTAssertEqual(button.accessibilityValue() as? String, "Updating")
            XCTAssertFalse(button.isEnabled)
            delegate.settingsWindow?.close()
        }
    }

    func test_closeSettingsWindow_clearsStrongReference() {
        let delegate = AppDelegate()
        delegate.openSettings()
        XCTAssertNotNil(delegate.settingsWindow)

        delegate.settingsWindow?.close()

        XCTAssertNil(delegate.settingsWindow)
    }

    func test_closeSettingsWindow_deallocatesWindowAndContentVC() {
        let delegate = AppDelegate()
        weak var window: NSWindow?
        weak var contentVC: NSViewController?
        autoreleasepool {
            delegate.openSettings()
            window = delegate.settingsWindow
            contentVC = delegate.settingsWindow?.contentViewController
            XCTAssertNotNil(window)
            XCTAssertNotNil(contentVC)
            delegate.settingsWindow?.close()
        }
        // AppKit releases ordered-in windows on a later runloop turn; give it
        // a few short spins before judging deallocation.
        for _ in 0..<10 where window != nil {
            autoreleasepool {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
        }
        XCTAssertNil(window, "closed Settings window must deallocate")
        XCTAssertNil(contentVC, "Settings VC must deallocate with its window")
    }

    /// AppKit's last-key-window bookkeeping can keep the closed NSWindow shell
    /// alive until another window becomes key. The heavy part — the VC + view
    /// tree — must not wait for that: it detaches at close time.
    func test_closeSettingsWindow_deallocatesContentVCImmediately() {
        let delegate = AppDelegate()
        weak var contentVC: NSViewController?
        autoreleasepool {
            delegate.openSettings()
            contentVC = delegate.settingsWindow?.contentViewController
            XCTAssertNotNil(contentVC)
            delegate.settingsWindow?.close()
        }
        XCTAssertNil(contentVC, "Settings VC must deallocate at close, without waiting for the window shell")
    }

    func test_reopenAfterClose_buildsFreshWindow() {
        let delegate = AppDelegate()
        delegate.openSettings()
        let first = delegate.settingsWindow
        first?.close()

        delegate.openSettings()

        XCTAssertNotNil(delegate.settingsWindow)
        XCTAssertFalse(delegate.settingsWindow === first)
        delegate.settingsWindow?.close()
    }

    func test_openWhileVisible_reusesSameWindow() {
        let delegate = AppDelegate()
        delegate.openSettings()
        let first = delegate.settingsWindow

        delegate.openSettings()

        XCTAssertTrue(delegate.settingsWindow === first)
        delegate.settingsWindow?.close()
    }
}
