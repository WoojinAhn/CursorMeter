import AppKit
import ServiceManagement

// MARK: - SettingsViewController

@MainActor
final class SettingsViewController: NSViewController {

    // MARK: - Dependencies

    private let viewModel: UsageViewModel

    // MARK: - Controls (retained as instance vars for updateUI)

    private var intervalPopUp = NSPopUpButton()
    private var notificationToggle = NSButton()
    private var thresholdBox = NSView()
    private var warningValueLabel = NSTextField()
    private var warningSlider = NSSlider()
    private var criticalValueLabel = NSTextField()
    private var criticalSlider = NSSlider()
    private var showMenuBarTextToggle = NSButton()
    private var showMenuBarPercentToggle = NSButton()
    private var launchAtLoginToggle = NSButton()

    // Updates row controls
    private var updateStatusLabel = NSTextField()
    private var updateSpinner = NSProgressIndicator()
    private var checkNowButton = NSButton()
    private var downloadButton = NSButton()

    // MARK: - Init

    init(viewModel: UsageViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("use init(viewModel:)") }

    // MARK: - Lifecycle

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 350, height: 380))

        let outerStack = NSStackView()
        outerStack.orientation = .vertical
        outerStack.alignment = .left
        outerStack.spacing = 0
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(outerStack)

        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            outerStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            outerStack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            outerStack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -16),
        ])

        // Section: Refresh
        outerStack.addArrangedSubview(makeSectionHeader("Refresh"))
        outerStack.setCustomSpacing(6, after: outerStack.arrangedSubviews.last!)
        outerStack.addArrangedSubview(makeRefreshSection())
        outerStack.setCustomSpacing(10, after: outerStack.arrangedSubviews.last!)

        outerStack.addArrangedSubview(makeSeparator())
        outerStack.setCustomSpacing(10, after: outerStack.arrangedSubviews.last!)

        // Section: Notifications
        outerStack.addArrangedSubview(makeSectionHeader("Notifications"))
        outerStack.setCustomSpacing(6, after: outerStack.arrangedSubviews.last!)
        outerStack.addArrangedSubview(makeNotificationsSection())
        outerStack.setCustomSpacing(10, after: outerStack.arrangedSubviews.last!)

        outerStack.addArrangedSubview(makeSeparator())
        outerStack.setCustomSpacing(10, after: outerStack.arrangedSubviews.last!)

        // Section: Menu Bar
        outerStack.addArrangedSubview(makeSectionHeader("Menu Bar"))
        outerStack.setCustomSpacing(6, after: outerStack.arrangedSubviews.last!)
        outerStack.addArrangedSubview(makeMenuBarSection())
        outerStack.setCustomSpacing(10, after: outerStack.arrangedSubviews.last!)

        outerStack.addArrangedSubview(makeSeparator())
        outerStack.setCustomSpacing(10, after: outerStack.arrangedSubviews.last!)

        // Section: General
        outerStack.addArrangedSubview(makeSectionHeader("General"))
        outerStack.setCustomSpacing(6, after: outerStack.arrangedSubviews.last!)
        outerStack.addArrangedSubview(makeGeneralSection())
        outerStack.setCustomSpacing(10, after: outerStack.arrangedSubviews.last!)

        outerStack.addArrangedSubview(makeSeparator())
        outerStack.setCustomSpacing(10, after: outerStack.arrangedSubviews.last!)

        // Section: Updates
        outerStack.addArrangedSubview(makeSectionHeader("Updates"))
        outerStack.setCustomSpacing(6, after: outerStack.arrangedSubviews.last!)
        outerStack.addArrangedSubview(makeUpdatesSection())

        self.view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateUI()
    }

    // MARK: - Public API

    func updateUI() {
        // Refresh interval
        let currentIndex = RefreshInterval.allCases.firstIndex(of: viewModel.refreshInterval) ?? 0
        intervalPopUp.selectItem(at: currentIndex)

        // Notifications
        notificationToggle.state = viewModel.notificationEnabled ? .on : .off
        thresholdBox.isHidden = !viewModel.notificationEnabled

        // Warning slider
        let warning = viewModel.warningThreshold
        warningSlider.integerValue = warning
        warningValueLabel.stringValue = "\(warning)%"

        // Critical slider - min must be warning+5
        let criticalMin = min(warning + 5, 100)
        criticalSlider.minValue = Double(criticalMin)
        let critical = max(viewModel.criticalThreshold, criticalMin)
        criticalSlider.integerValue = critical
        criticalValueLabel.stringValue = "\(critical)%"

        // Menu bar text
        showMenuBarTextToggle.state = viewModel.showMenuBarText ? .on : .off
        showMenuBarPercentToggle.state = viewModel.showMenuBarPercent ? .on : .off
        showMenuBarPercentToggle.isEnabled = viewModel.showMenuBarText

        // Launch at login
        launchAtLoginToggle.state = SMAppService.mainApp.status == .enabled ? .on : .off

        // Updates
        updateUpdatesUI()
    }

    // MARK: - Section Builders

    private func makeRefreshSection() -> NSView {
        intervalPopUp = NSPopUpButton()
        for interval in RefreshInterval.allCases {
            intervalPopUp.addItem(withTitle: interval.label)
        }
        intervalPopUp.target = self
        intervalPopUp.action = #selector(intervalChanged)
        intervalPopUp.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [
            makeLabel("Interval"),
            intervalPopUp,
            makeSpacer(),
        ])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func makeNotificationsSection() -> NSView {
        notificationToggle = makeCheckbox(
            title: "Enable usage alerts",
            action: #selector(notificationToggleChanged)
        )

        // Threshold controls (shown when notifications enabled)
        let warningGrid = makeThresholdGrid(
            label: "Warning",
            valueField: &warningValueLabel
        )
        warningSlider = makeSlider(min: 50, max: 90, action: #selector(warningSliderChanged))

        let criticalGrid = makeThresholdGrid(
            label: "Critical",
            valueField: &criticalValueLabel
        )
        criticalSlider = makeSlider(min: 55, max: 100, action: #selector(criticalSliderChanged))

        let thresholdStack = NSStackView(views: [
            warningGrid,
            warningSlider,
            criticalGrid,
            criticalSlider,
        ])
        thresholdStack.orientation = .vertical
        thresholdStack.alignment = .left
        thresholdStack.spacing = 4
        thresholdStack.translatesAutoresizingMaskIntoConstraints = false

        thresholdBox = thresholdStack
        thresholdBox.isHidden = !viewModel.notificationEnabled

        let sectionStack = NSStackView(views: [notificationToggle, thresholdBox])
        sectionStack.orientation = .vertical
        sectionStack.alignment = .left
        sectionStack.spacing = 6
        return sectionStack
    }

    private func makeMenuBarSection() -> NSView {
        showMenuBarTextToggle = makeCheckbox(
            title: "Show usage text next to icon",
            action: #selector(showMenuBarTextChanged)
        )
        showMenuBarPercentToggle = makeCheckbox(
            title: "Show percentage instead of fraction",
            action: #selector(showMenuBarPercentChanged)
        )

        let stack = NSStackView(views: [showMenuBarTextToggle, showMenuBarPercentToggle])
        stack.orientation = .vertical
        stack.alignment = .left
        stack.spacing = 4
        return stack
    }

    private func makeGeneralSection() -> NSView {
        launchAtLoginToggle = makeCheckbox(
            title: "Launch at login",
            action: #selector(launchAtLoginChanged)
        )
        return launchAtLoginToggle
    }

    private func makeUpdatesSection() -> NSView {
        updateStatusLabel = makeLabel("")
        updateStatusLabel.textColor = .secondaryLabelColor

        updateSpinner = NSProgressIndicator()
        updateSpinner.style = .spinning
        updateSpinner.controlSize = .small
        updateSpinner.isHidden = true
        updateSpinner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            updateSpinner.widthAnchor.constraint(equalToConstant: 16),
            updateSpinner.heightAnchor.constraint(equalToConstant: 16),
        ])

        checkNowButton = NSButton(
            title: "Check Now",
            target: self,
            action: #selector(checkNowTapped)
        )
        checkNowButton.bezelStyle = .rounded

        downloadButton = NSButton(
            title: "Download",
            target: self,
            action: #selector(downloadTapped)
        )
        downloadButton.bezelStyle = .rounded

        let row = NSStackView(views: [
            updateSpinner,
            updateStatusLabel,
            makeSpacer(),
            checkNowButton,
            downloadButton,
        ])
        row.orientation = .horizontal
        row.spacing = 6
        row.alignment = .centerY

        return row
    }

    // MARK: - Actions

    @objc private func intervalChanged() {
        let index = intervalPopUp.indexOfSelectedItem
        guard index >= 0, index < RefreshInterval.allCases.count else { return }
        viewModel.setRefreshInterval(RefreshInterval.allCases[index])
    }

    @objc private func notificationToggleChanged() {
        let enabled = notificationToggle.state == .on
        viewModel.setNotificationEnabled(enabled)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            thresholdBox.animator().isHidden = !enabled
        }
    }

    @objc private func warningSliderChanged() {
        let stepped = roundToStep(warningSlider.doubleValue, step: 5)
        warningSlider.integerValue = Int(stepped)
        viewModel.setWarningThreshold(Int(stepped))

        // Auto-adjust critical if needed
        let minCritical = Int(stepped) + 5
        if viewModel.criticalThreshold < minCritical {
            viewModel.setCriticalThreshold(minCritical)
        }
        updateUI()
    }

    @objc private func criticalSliderChanged() {
        let stepped = roundToStep(criticalSlider.doubleValue, step: 5)
        criticalSlider.integerValue = Int(stepped)
        viewModel.setCriticalThreshold(Int(stepped))
        criticalValueLabel.stringValue = "\(Int(stepped))%"
    }

    @objc private func showMenuBarTextChanged() {
        let enabled = showMenuBarTextToggle.state == .on
        viewModel.setShowMenuBarText(enabled)
        showMenuBarPercentToggle.isEnabled = enabled
    }

    @objc private func showMenuBarPercentChanged() {
        viewModel.setShowMenuBarPercent(showMenuBarPercentToggle.state == .on)
    }

    @objc private func launchAtLoginChanged() {
        let enable = launchAtLoginToggle.state == .on
        do {
            if enable {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.error("Launch at login failed: \(error)")
            // Revert toggle on failure
            launchAtLoginToggle.state = enable ? .off : .on
        }
    }

    @objc private func checkNowTapped() {
        updateSpinner.isHidden = false
        updateSpinner.startAnimation(nil)
        updateStatusLabel.stringValue = "Checking..."
        updateStatusLabel.textColor = .secondaryLabelColor
        checkNowButton.isHidden = true
        downloadButton.isHidden = true

        Task {
            await viewModel.checkForUpdate()
            updateUpdatesUI()
        }
    }

    @objc private func downloadTapped() {
        guard let update = viewModel.availableUpdate,
              let url = URL(string: update.htmlURL)
        else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Helpers: UI Factory

    private func makeSectionHeader(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title.uppercased())
        label.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func makeSeparator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    private func makeLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.systemFont(ofSize: 13)
        label.textColor = .labelColor
        return label
    }

    private func makeCheckbox(title: String, action: Selector) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.font = NSFont.systemFont(ofSize: 13)
        return button
    }

    private func makeSlider(min: Double, max: Double, action: Selector) -> NSSlider {
        let slider = NSSlider(value: min, minValue: min, maxValue: max, target: self, action: action)
        slider.isContinuous = false
        slider.numberOfTickMarks = Int((max - min) / 5) + 1
        slider.allowsTickMarkValuesOnly = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        return slider
    }

    private func makeThresholdGrid(label: String, valueField: inout NSTextField) -> NSView {
        let labelField = makeLabel(label)
        let valueDisplay = NSTextField(labelWithString: "--%")
        valueDisplay.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        valueDisplay.alignment = .right
        valueField = valueDisplay

        let row = NSStackView(views: [labelField, makeSpacer(), valueDisplay])
        row.orientation = .horizontal
        row.spacing = 4
        return row
    }

    private func makeSpacer() -> NSView {
        let v = NSView()
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return v
    }

    // MARK: - Helpers: Updates UI

    private func updateUpdatesUI() {
        if let update = viewModel.availableUpdate {
            updateSpinner.isHidden = true
            updateSpinner.stopAnimation(nil)
            updateStatusLabel.stringValue = "v\(update.version) available"
            updateStatusLabel.textColor = .labelColor
            checkNowButton.isHidden = true
            downloadButton.isHidden = false
        } else if viewModel.isCheckingUpdate {
            updateSpinner.isHidden = false
            updateSpinner.startAnimation(nil)
            updateStatusLabel.stringValue = "Checking..."
            updateStatusLabel.textColor = .secondaryLabelColor
            checkNowButton.isHidden = true
            downloadButton.isHidden = true
        } else {
            updateSpinner.isHidden = true
            updateSpinner.stopAnimation(nil)
            updateStatusLabel.stringValue = "Up to date"
            updateStatusLabel.textColor = .secondaryLabelColor
            checkNowButton.isHidden = false
            downloadButton.isHidden = true
        }
    }

    // MARK: - Helpers: Math

    private func roundToStep(_ value: Double, step: Double) -> Double {
        (value / step).rounded() * step
    }
}
