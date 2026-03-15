import AppKit

// MARK: - App Entry Point

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Properties

    private var viewModel = UsageViewModel()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var settingsWindow: NSWindow?
    private var loginWindow: LoginWindow?
    private var eventMonitor: Any?

    // MARK: - NSApplicationDelegate Entry Point

    nonisolated static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    // MARK: - Application Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
        setupKeyboardShortcut()

        viewModel.checkExistingSession()
        observeViewModel()
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusItem()

        if let button = statusItem.button {
            button.action = #selector(statusItemClicked)
            button.target = self
            // Enable right-click to also toggle popover
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }

        if let data = viewModel.usageData {
            let forcePercent = data.isPercentOnly
            if viewModel.showMenuBarText && (viewModel.showMenuBarPercent || forcePercent) {
                button.image = CircularProgressIcon.menuBarImageWithPercent(
                    percent: data.percentUsed
                )
            } else if viewModel.showMenuBarText {
                button.image = CircularProgressIcon.menuBarImageWithText(
                    percent: data.percentUsed,
                    usedText: data.menuBarUsedText,
                    limitText: data.menuBarLimitText
                )
            } else {
                button.image = CircularProgressIcon.menuBarImage(percent: data.percentUsed)
            }
        } else {
            button.image = CircularProgressIcon.idleImage()
        }
    }

    @objc private func statusItemClicked() {
        if popover.isShown {
            hidePopover()
        } else {
            showPopover()
        }
    }

    // MARK: - Popover

    private func setupPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = MenuBarPopoverViewController(
            viewModel: viewModel,
            onLogin: { [weak self] in self?.showLogin() },
            onSettings: { [weak self] in self?.hidePopover(); self?.openSettings() }
        )
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func hidePopover() {
        popover.performClose(nil)
    }

    // MARK: - Settings Window

    func openSettings() {
        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsVC = SettingsViewController(viewModel: viewModel)
        let window = NSWindow(contentViewController: settingsVC)
        window.title = "Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.center()
        settingsWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Login Window

    func showLogin() {
        let window = LoginWindow()
        loginWindow = window
        window.open { [weak self] cookieHeader in
            guard let self else { return }
            if let cookieHeader {
                viewModel.onLoginSuccess(cookieHeader: cookieHeader)
            }
            loginWindow = nil
        }
    }

    // MARK: - Keyboard Shortcut (Cmd+,)

    private func setupKeyboardShortcut() {
        // Local monitor fires when the app is active (e.g., popover is open).
        // .accessory policy apps do not show a menu bar, so we use an event monitor
        // rather than an NSMenuItem to handle Cmd+,.
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            // Cmd+, (comma key, key code 43)
            if event.modifierFlags.contains(.command), event.keyCode == 43 {
                hidePopover()
                openSettings()
                return nil // Consume the event
            }
            return event
        }
    }

    // MARK: - ViewModel Observation

    // Subscribes to @Observable viewModel changes using Swift Observation's
    // withObservationTracking. The onChange callback fires once per change,
    // so we re-subscribe inside it to continue tracking subsequent mutations.
    private func observeViewModel() {
        withObservationTracking {
            // Access every property that should trigger a status item or popover redraw.
            _ = viewModel.usageData
            _ = viewModel.showMenuBarText
            _ = viewModel.showMenuBarPercent
            _ = viewModel.isLoading
            _ = viewModel.errorMessage
            _ = viewModel.authState
            _ = viewModel.availableUpdate
            _ = viewModel.refreshInterval
        } onChange: { [weak self] in
            // onChange is called on an arbitrary thread; dispatch back to MainActor.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.updateStatusItem()
                (self.popover.contentViewController as? MenuBarPopoverViewController)?.updateUI()
                self.observeViewModel() // Re-subscribe for the next change.
            }
        }
    }
}

