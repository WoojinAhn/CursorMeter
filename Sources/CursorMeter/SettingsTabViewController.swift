import AppKit

// MARK: - SettingsTabViewController

/// Root of the settings window: toolbar-style tabs (#99). AppKit owns the
/// window's toolbar and animates the frame to each tab's fitting size on
/// selection; `CursorMeterApp` must not touch `window.toolbar` or set a
/// manual window title.
@MainActor
final class SettingsTabViewController: NSTabViewController {

    private let generalVC: SettingsGeneralTabViewController
    private let notificationsVC: SettingsNotificationsTabViewController
    private let appearanceVC: SettingsAppearanceTabViewController
    private let usageVC: SettingsUsageTabViewController

    init(viewModel: UsageViewModel) {
        generalVC = SettingsGeneralTabViewController(viewModel: viewModel)
        notificationsVC = SettingsNotificationsTabViewController(viewModel: viewModel)
        appearanceVC = SettingsAppearanceTabViewController(viewModel: viewModel)
        usageVC = SettingsUsageTabViewController(viewModel: viewModel)
        super.init(nibName: nil, bundle: nil)

        tabStyle = .toolbar
        canPropagateSelectedChildViewControllerTitle = true

        addTab(generalVC, symbol: "gearshape")
        addTab(notificationsVC, symbol: "bell.badge")
        addTab(appearanceVC, symbol: "paintbrush")
        addTab(usageVC, symbol: "list.bullet.rectangle")

        // Eager-load all children so updateUI() fan-out and per-tab fitting
        // sizes never hit an unloaded view (spec decision; views are small
        // and #93 frees the whole graph on window close).
        for item in tabViewItems {
            _ = item.viewController?.view
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("use init(viewModel:)") }

    // MARK: - Public API

    /// Single push-refresh entry point (#54 observation + popover parity).
    func updateUI() {
        generalVC.updateUI()
        notificationsVC.updateUI()
        appearanceVC.updateUI()
        usageVC.updateUI()
    }

    // MARK: - Helpers

    private func addTab(_ viewController: NSViewController, symbol: String) {
        let item = NSTabViewItem(viewController: viewController)
        item.label = viewController.title ?? ""
        item.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: viewController.title
        )
        addTabViewItem(item)
    }
}
