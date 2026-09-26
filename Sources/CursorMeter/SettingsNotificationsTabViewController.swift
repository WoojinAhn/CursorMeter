import AppKit

/// Notifications tab: independent usage thresholds and app status.
@MainActor
final class SettingsNotificationsTabViewController: NSViewController {
    private struct AlertCard {
        let view: NSView
        let toggle: NSSwitch
        let slider: ThresholdRangeSlider
        let sliderUnit: NSView
    }

    private let viewModel: UsageViewModel
    private let notificationToggle = NSSwitch()
    private let appStatusToggle = NSSwitch()
    private var scopeCards: [SplitAlertScope: AlertCard] = [:]
    private var legacyCard: AlertCard?
    private var permissionCard = NSView()
    private let screenHeight: (() -> CGFloat)?
    private let scrollView = NSScrollView()
    private var content = NSView()
    private var viewportHeight: NSLayoutConstraint?

    init(viewModel: UsageViewModel, screenHeight: (() -> CGFloat)? = nil) {
        self.viewModel = viewModel
        self.screenHeight = screenHeight
        super.init(nibName: nil, bundle: nil)
        title = "Alerts"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("use init(viewModel:)") }

    override func loadView() {
        notificationToggle.target = self
        notificationToggle.action = #selector(notificationToggleChanged)
        notificationToggle.setAccessibilityLabel("Enable usage alerts")
        appStatusToggle.target = self
        appStatusToggle.action = #selector(appStatusToggleChanged)
        appStatusToggle.setAccessibilityLabel("App status notifications")

        let settingsButton = NSButton(title: "Open Settings", target: self, action: #selector(openNotificationSettings))
        permissionCard = SettingsCardFactory.makeCard(units: [SettingsCardFactory.makeCardRow(
            title: "Notifications blocked in macOS.", control: settingsButton)])
        let master = SettingsCardFactory.makeCard(units: [SettingsCardFactory.makeCardRow(
            title: "Usage alerts", control: notificationToggle)])
        var cards: [NSView] = [permissionCard, master]
        let legacy = makeAlertCard(title: "Included usage", scope: nil)
        legacyCard = legacy
        cards.append(legacy.view)
        for scope in [SplitAlertScope.cursor, .other, .onDemand] {
            let card = makeAlertCard(title: scope == .onDemand ? "Paid budget" : scope.label, scope: scope)
            scopeCards[scope] = card
            cards.append(card.view)
        }
        cards.append(SettingsCardFactory.makeCard(units: [SettingsCardFactory.makeCardRow(
            title: "App status notifications", caption: "New version · connection errors", control: appStatusToggle)]))
        content = SettingsCardFactory.makeTabRoot(sections: cards)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.setAccessibilityLabel("Alert settings")
        let document = AlertSettingsDocumentView()
        scrollView.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        NSLayoutConstraint.activate([
            document.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor),
            content.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            scrollView.widthAnchor.constraint(equalToConstant: SettingsCardFactory.contentWidth),
        ])
        viewportHeight = scrollView.heightAnchor.constraint(equalToConstant: 1)
        viewportHeight?.isActive = true
        view = scrollView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateUI()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        updateViewport()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateViewport()
    }

    private func updateViewport() {
        content.layoutSubtreeIfNeeded()
        let screen = screenHeight?() ?? view.window?.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height ?? 800
        let chrome = view.window.map { max(0, $0.frame.height - $0.contentLayoutRect.height) } ?? 0
        let height = min(ceil(content.fittingSize.height), max(1, floor(screen - chrome - 20)))
        viewportHeight?.constant = height
        preferredContentSize = NSSize(width: SettingsCardFactory.contentWidth, height: height)
    }

    func updateUI() {
        let enabled = viewModel.notificationEnabled
        let split = viewModel.splitUsage.eligibility == .eligible
        notificationToggle.state = enabled ? .on : .off
        appStatusToggle.state = viewModel.appStatusNotificationEnabled ? .on : .off
        permissionCard.isHidden = viewModel.notificationPermissionStatus != "Denied in macOS Settings"
        legacyCard?.view.isHidden = split || !enabled
        legacyCard?.toggle.state = enabled ? .on : .off
        legacyCard?.slider.setValues(warning: viewModel.warningThreshold, critical: viewModel.criticalThreshold)
        for (scope, card) in scopeCards {
            let selected = viewModel.splitAlertTargets.contains(scope)
            let paidEligible = scope != .onDemand || (viewModel.usageData?.onDemandEnabled == true
                && (viewModel.usageData?.onDemandLimitCents ?? 0) > 0)
            card.view.isHidden = !split || !enabled || !paidEligible
            card.toggle.state = selected ? .on : .off
            card.sliderUnit.isHidden = !selected
            let thresholds = viewModel.splitThresholds(for: scope)
            card.slider.setValues(warning: thresholds.warning, critical: thresholds.critical)
        }
        updateViewport()
    }

    private func makeAlertCard(title: String, scope: SplitAlertScope?) -> AlertCard {
        let toggle = NSSwitch()
        toggle.target = self
        toggle.action = scope == nil ? #selector(legacyToggleChanged(_:)) : #selector(targetChanged(_:))
        toggle.tag = scope.flatMap { SplitAlertScope.allCases.firstIndex(of: $0) } ?? -1
        toggle.setAccessibilityLabel("\(title) alerts")
        toggle.isHidden = scope == nil
        let slider = ThresholdRangeSlider()
        slider.setAccessibilityLabel("\(title) thresholds")
        slider.setAccessibilityScope(title)
        slider.onChange = { [weak self] warning, critical in
            guard let self else { return }
            if let scope {
                self.viewModel.setSplitThresholds(SplitAlertThresholds(warning: warning, critical: critical), for: scope)
            } else {
                self.viewModel.setWarningThreshold(warning)
                self.viewModel.setCriticalThreshold(critical)
            }
        }
        let sliderUnit = SettingsCardFactory.makeDividedUnit(SettingsCardFactory.makeFullWidthCardRow(slider))
        let card = SettingsCardFactory.makeCard(units: [
            SettingsCardFactory.makeCardRow(title: title, control: toggle), sliderUnit])
        return AlertCard(view: card, toggle: toggle, slider: slider, sliderUnit: sliderUnit)
    }

    @objc private func notificationToggleChanged() {
        viewModel.setNotificationEnabled(notificationToggle.state == .on)
        updateUI()
    }

    @objc private func legacyToggleChanged(_ sender: NSSwitch) {
        viewModel.setNotificationEnabled(sender.state == .on)
        updateUI()
    }

    @objc private func targetChanged(_ sender: NSSwitch) {
        guard SplitAlertScope.allCases.indices.contains(sender.tag) else { return }
        viewModel.setSplitAlertTarget(SplitAlertScope.allCases[sender.tag], enabled: sender.state == .on)
        updateUI()
    }

    @objc private func appStatusToggleChanged() {
        viewModel.setAppStatusNotificationEnabled(appStatusToggle.state == .on)
    }

    @objc private func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

private final class AlertSettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}
