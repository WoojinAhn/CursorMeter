import AppKit

// MARK: - SettingsNotificationsTabViewController

/// Notifications tab: usage alerts, thresholds, app status (#99).
@MainActor
final class SettingsNotificationsTabViewController: NSViewController {

    private let viewModel: UsageViewModel

    // MARK: - Controls (retained as instance vars for updateUI)

    private var notificationToggle = NSSwitch()
    private var appStatusToggle = NSSwitch()
    private var thresholdSlider = ThresholdRangeSlider()
    /// Divided-unit wrapper around the slider row — the conditional-hide
    /// target (divider collapses with the row).
    private var thresholdUnit = NSView()
    private let cursorTarget = NSButton(checkboxWithTitle: "Cursor Models", target: nil, action: nil)
    private let otherTarget = NSButton(checkboxWithTitle: "Other Models", target: nil, action: nil)
    private let paidTarget = NSButton(checkboxWithTitle: "Paid budget", target: nil, action: nil)
    private let permissionLabel = SettingsCardFactory.makeCaption("")

    // MARK: - Init

    init(viewModel: UsageViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "Alerts"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("use init(viewModel:)") }

    // MARK: - Lifecycle

    override func loadView() {
        view = SettingsCardFactory.makeTabRoot(sections: [
            SettingsCardFactory.makeSection(header: "Notifications", content: makeNotificationsCard()),
        ])
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateUI()
    }

    // NSTabViewController animates the window to the selected child's
    // preferredContentSize on tab switch — it does NOT read fitting sizes
    // by itself. Report ours each time this tab is about to show.
    override func viewWillAppear() {
        super.viewWillAppear()
        preferredContentSize = view.fittingSize
    }

    // MARK: - Public API

    func updateUI() {
        notificationToggle.state = viewModel.notificationEnabled ? .on : .off
        thresholdUnit.isHidden = !viewModel.notificationEnabled
        appStatusToggle.state = viewModel.appStatusNotificationEnabled ? .on : .off

        // Threshold range slider — setValues normalizes corrupted pairs
        // (gap + bounds), so no cross-slider juggling is needed here.
        thresholdSlider.setValues(
            warning: viewModel.warningThreshold,
            critical: viewModel.criticalThreshold
        )
        let split = viewModel.splitUsage.eligibility == .eligible
        for (button, scope) in [(cursorTarget, SplitAlertScope.cursor), (otherTarget, .other), (paidTarget, .onDemand)] {
            button.state = viewModel.splitAlertTargets.contains(scope) ? .on : .off
            button.isEnabled = split && viewModel.notificationEnabled
        }
        paidTarget.isEnabled = paidTarget.isEnabled && viewModel.usageData?.onDemandEnabled == true
            && (viewModel.usageData?.onDemandLimitCents ?? 0) > 0
        permissionLabel.stringValue = "Notification permission: \(viewModel.notificationPermissionStatus)"
    }

    // MARK: - Card

    private func makeNotificationsCard() -> NSView {
        notificationToggle = NSSwitch()
        notificationToggle.target = self
        notificationToggle.action = #selector(notificationToggleChanged)

        thresholdSlider = ThresholdRangeSlider()
        thresholdSlider.onChange = { [weak self] warning, critical in
            self?.viewModel.setWarningThreshold(warning)
            self?.viewModel.setCriticalThreshold(critical)
        }

        appStatusToggle = NSSwitch()
        appStatusToggle.target = self
        appStatusToggle.action = #selector(appStatusToggleChanged)

        thresholdUnit = SettingsCardFactory.makeDividedUnit(
            SettingsCardFactory.makeFullWidthCardRow(thresholdSlider)
        )
        for (index, button) in [cursorTarget, otherTarget, paidTarget].enumerated() {
            button.tag = index
            button.target = self
            button.action = #selector(targetChanged(_:))
            button.setAccessibilityLabel(button.title)
        }
        let targets = NSStackView(views: [cursorTarget, otherTarget, paidTarget])
        targets.orientation = .vertical
        targets.alignment = .leading
        targets.spacing = 6

        return SettingsCardFactory.makeCard(units: [
            SettingsCardFactory.makeCardRow(title: "Enable usage alerts", control: notificationToggle),
            thresholdUnit,
            SettingsCardFactory.makeDividedUnit(SettingsCardFactory.makeFullWidthCardRow(targets)),
            SettingsCardFactory.makeFullWidthCardRow(SettingsCardFactory.makeCaption(
                "Targets apply independently to split pools. Paid budget requires enabled paid spending and a positive cap. Changes apply on the next fresh update. Percentages marked Current period are display-only and do not trigger alerts.")),
            SettingsCardFactory.makeFullWidthCardRow(SettingsCardFactory.makeCaption(
                "Bold jump notifications are independent of these usage alerts. Configure Bold in Display.")),
            SettingsCardFactory.makeFullWidthCardRow(permissionLabel),
            SettingsCardFactory.makeDividedUnit(SettingsCardFactory.makeCardRow(
                title: "App status notifications",
                caption: "New version · connection errors",
                control: appStatusToggle
            )),
        ])
    }

    // MARK: - Actions

    @objc private func notificationToggleChanged() {
        let enabled = notificationToggle.state == .on
        viewModel.setNotificationEnabled(enabled)
        // Same NSStackView caveat as the jump-effect toggle: animator().isHidden
        // causes a layout/alpha desync that reads as a "blink". Snap instead.
        thresholdUnit.isHidden = !enabled
        updateUI()
    }

    @objc private func targetChanged(_ sender: NSButton) {
        let scopes: [SplitAlertScope] = [.cursor, .other, .onDemand]
        guard scopes.indices.contains(sender.tag) else { return }
        viewModel.setSplitAlertTarget(scopes[sender.tag], enabled: sender.state == .on)
        updateUI()
    }

    @objc private func appStatusToggleChanged() {
        viewModel.setAppStatusNotificationEnabled(appStatusToggle.state == .on)
    }
}
