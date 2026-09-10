import AppKit

// MARK: - SettingsAppearanceTabViewController

/// Appearance tab: menu bar text, usage jump, weekly chart (#99).
@MainActor
final class SettingsAppearanceTabViewController: NSViewController {

    private let viewModel: UsageViewModel

    // MARK: - Controls (retained as instance vars for updateUI)

    private var menuBarDisplayPopUp = NSPopUpButton()
    private var jumpEffectToggle = NSSwitch()
    private var jumpIntensitySegmented = NSSegmentedControl()
    private var jumpGlyphStyleSegmented = NSSegmentedControl()
    /// Container that wraps both jump sub-rows (Intensity + Style) so the
    /// effect-toggle collapse targets a single view rather than two stacking
    /// peers — avoids mid-animation spacing thrash in NSStackView.
    private var jumpSubRowsContainer = NSView()
    private var weeklyChartToggle = NSSwitch()
    private var weeklyChartStyleSegmented = NSSegmentedControl()
    private var weeklyChartMetricPopUp = NSPopUpButton()
    private let weeklyChartMetricCaption = SettingsCardFactory.makeCaption("")
    /// Header + card container.
    private var weeklyChartSection = NSView()

    // MARK: - Init

    init(viewModel: UsageViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "Display"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("use init(viewModel:)") }

    // MARK: - Lifecycle

    override func loadView() {
        weeklyChartSection = SettingsCardFactory.makeSection(
            header: "Weekly Chart", content: makeWeeklyChartCard())
        view = SettingsCardFactory.makeTabRoot(sections: [
            SettingsCardFactory.makeSection(header: "Menu Bar", content: makeMenuBarCard()),
            SettingsCardFactory.makeSection(header: "Usage Jump", content: makeJumpCard()),
            weeklyChartSection,
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
        // Menu bar display mode — percent-only plans have no ratio denominator
        // at all (Cursor's own dashboard shows no ratio concept on free), so
        // the Ratio item is HIDDEN there, not disabled (#107). Items are
        // tag-addressed (tag = mode value) so removal can't shift the mapping.
        // The popup reflects the EFFECTIVE mode (None stays None, #105) via
        // the same resolver the status item uses.
        let percentOnly = viewModel.usageData?.isPercentOnly == true
        let ratioIndex = menuBarDisplayPopUp.indexOfItem(withTag: 1)
        if percentOnly {
            if ratioIndex >= 0 { menuBarDisplayPopUp.removeItem(at: ratioIndex) }
        } else if ratioIndex < 0 {
            menuBarDisplayPopUp.insertItem(withTitle: Self.ratioItemTitle, at: 1)
            menuBarDisplayPopUp.item(at: 1)?.tag = 1
        }
        menuBarDisplayPopUp.selectItem(withTag: UsageViewModel.resolvedMenuBarDisplayMode(
            isPercentOnly: percentOnly, setting: viewModel.menuBarDisplayMode))

        jumpEffectToggle.state = viewModel.jumpEffectEnabled ? .on : .off
        jumpIntensitySegmented.selectedSegment = viewModel.jumpIntensity.rawValue
        jumpGlyphStyleSegmented.selectedSegment = viewModel.jumpGlyphStyle.rawValue
        jumpSubRowsContainer.isHidden = !viewModel.jumpEffectEnabled

        // Keep chart preferences reachable when the weekly endpoint is unavailable.
        weeklyChartSection.isHidden = viewModel.authState != .loggedIn
        weeklyChartToggle.state = viewModel.weeklyChartEnabled ? .on : .off
        weeklyChartStyleSegmented.selectedSegment = viewModel.weeklyChartStyle.rawValue
        weeklyChartStyleSegmented.isEnabled = viewModel.weeklyChartEnabled
        updateWeeklyChartMetric()
    }

    private func updateWeeklyChartMetric() {
        let amountAvailable = viewModel.weeklyData?.isAmountAvailable == true
        weeklyChartMetricPopUp.item(at: 0)?.isEnabled = amountAvailable
        weeklyChartMetricPopUp.selectItem(at: viewModel.effectiveWeeklyChartMetric == .amount ? 0 : 1)
        weeklyChartMetricPopUp.isEnabled = viewModel.weeklyChartEnabled
        if !amountAvailable {
            weeklyChartMetricCaption.stringValue = "Amount unavailable for this history; showing usage units."
        } else if viewModel.effectiveWeeklyChartMetric == .amount {
            weeklyChartMetricCaption.stringValue = "Total usage value, including plan-covered usage."
        } else {
            weeklyChartMetricCaption.stringValue = "Weighted activity, not the number of requests."
        }
    }

    // MARK: - Cards

    private static let ratioItemTitle = "Ratio (e.g. 120/500)"

    private func makeMenuBarCard() -> NSView {
        menuBarDisplayPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
        menuBarDisplayPopUp.addItems(withTitles: [
            "None",
            Self.ratioItemTitle,
            "Percent (e.g. 24%)",
        ])
        // tag = persisted mode value; selection/persistence go through tags so
        // hiding the Ratio item can't shift the mapping (#107).
        for (index, item) in menuBarDisplayPopUp.itemArray.enumerated() {
            item.tag = index
        }
        menuBarDisplayPopUp.target = self
        menuBarDisplayPopUp.action = #selector(menuBarDisplayModeChanged)

        return SettingsCardFactory.makeCard(units: [
            SettingsCardFactory.makeCardRow(
                title: "Usage text next to icon", control: menuBarDisplayPopUp),
        ])
    }

    private func makeJumpCard() -> NSView {
        jumpEffectToggle = NSSwitch()
        jumpEffectToggle.target = self
        jumpEffectToggle.action = #selector(jumpEffectToggleChanged)

        jumpIntensitySegmented = NSSegmentedControl(
            labels: ["Quiet", "Normal", "Bold"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(jumpIntensityChanged)
        )

        // Style row — segment labels are the actual emoji pairs so the result
        // is visible inline. Pair order tracks `JumpGlyphStyle` raw values.
        jumpGlyphStyleSegmented = NSSegmentedControl(
            labels: ["⚡ 🚀", "💲 💸"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(jumpGlyphStyleChanged)
        )

        let subRows = NSStackView(views: [
            SettingsCardFactory.makeDividedUnit(SettingsCardFactory.makeCardRow(
                title: "Intensity", control: jumpIntensitySegmented)),
            SettingsCardFactory.makeDividedUnit(SettingsCardFactory.makeCardRow(
                title: "Style", control: jumpGlyphStyleSegmented)),
        ])
        subRows.orientation = .vertical
        subRows.alignment = .leading
        subRows.spacing = 0
        for unit in subRows.arrangedSubviews {
            NSLayoutConstraint.activate([
                unit.leadingAnchor.constraint(equalTo: subRows.leadingAnchor),
                unit.trailingAnchor.constraint(equalTo: subRows.trailingAnchor),
            ])
        }
        jumpSubRowsContainer = subRows

        return SettingsCardFactory.makeCard(units: [
            SettingsCardFactory.makeCardRow(
                title: "Visual jump effect",
                caption: "Highlight sudden usage jumps in the menu bar.",
                control: jumpEffectToggle
            ),
            jumpSubRowsContainer,
        ])
    }

    private func makeWeeklyChartCard() -> NSView {
        weeklyChartToggle = NSSwitch()
        weeklyChartToggle.target = self
        weeklyChartToggle.action = #selector(weeklyChartToggleChanged)

        weeklyChartStyleSegmented = NSSegmentedControl(
            labels: ["Outline", "Dim", "Both"],
            trackingMode: .selectOne,
            target: self,
            action: #selector(weeklyChartStyleChanged)
        )

        weeklyChartMetricPopUp.addItems(withTitles: ["Amount", "Usage units"])
        weeklyChartMetricPopUp.autoenablesItems = false
        weeklyChartMetricPopUp.setAccessibilityLabel("Chart metric")
        weeklyChartMetricPopUp.target = self
        weeklyChartMetricPopUp.action = #selector(weeklyChartMetricChanged)
        let metricRow = SettingsCardFactory.makeCardRow(title: "Chart metric", control: weeklyChartMetricPopUp)
        let captionHost = NSView()
        weeklyChartMetricCaption.translatesAutoresizingMaskIntoConstraints = false
        captionHost.addSubview(weeklyChartMetricCaption)
        NSLayoutConstraint.activate([
            weeklyChartMetricCaption.leadingAnchor.constraint(equalTo: captionHost.leadingAnchor, constant: 14),
            weeklyChartMetricCaption.trailingAnchor.constraint(equalTo: captionHost.trailingAnchor, constant: -14),
            weeklyChartMetricCaption.topAnchor.constraint(equalTo: captionHost.topAnchor),
            weeklyChartMetricCaption.bottomAnchor.constraint(equalTo: captionHost.bottomAnchor, constant: -10),
        ])
        let metricUnit = NSStackView(views: [metricRow, captionHost])
        metricUnit.orientation = .vertical
        metricUnit.alignment = .leading
        metricUnit.spacing = 0
        for row in metricUnit.arrangedSubviews {
            row.translatesAutoresizingMaskIntoConstraints = false
            row.widthAnchor.constraint(equalTo: metricUnit.widthAnchor).isActive = true
        }

        return SettingsCardFactory.makeCard(units: [
            SettingsCardFactory.makeCardRow(
                title: "Show weekly chart",
                caption: "Rolling 7-day usage.",
                control: weeklyChartToggle
            ),
            SettingsCardFactory.makeDividedUnit(metricUnit),
            SettingsCardFactory.makeDividedUnit(SettingsCardFactory.makeCardRow(
                title: "Today", control: weeklyChartStyleSegmented)),
        ])
    }

    // MARK: - Actions

    @objc private func menuBarDisplayModeChanged() {
        guard let tag = menuBarDisplayPopUp.selectedItem?.tag else { return }
        viewModel.setMenuBarDisplayMode(tag)
    }

    @objc private func jumpEffectToggleChanged() {
        let enabled = jumpEffectToggle.state == .on
        viewModel.setJumpEffectEnabled(enabled)
        // animator().isHidden in an NSStackView is misleading: layout removes
        // the view immediately while alpha fades over the animation window, so
        // siblings appear to jump first and the view "blinks" away. Setting
        // isHidden directly avoids the mid-animation discontinuity.
        jumpSubRowsContainer.isHidden = !enabled
    }

    @objc private func jumpIntensityChanged() {
        let raw = jumpIntensitySegmented.selectedSegment
        guard let intensity = JumpIntensity(rawValue: raw) else { return }
        viewModel.setJumpIntensity(intensity)
    }

    @objc private func jumpGlyphStyleChanged() {
        let raw = jumpGlyphStyleSegmented.selectedSegment
        guard let style = JumpGlyphStyle(rawValue: raw) else { return }
        viewModel.setJumpGlyphStyle(style)
    }

    @objc private func weeklyChartToggleChanged() {
        let enabled = weeklyChartToggle.state == .on
        viewModel.setWeeklyChartEnabled(enabled)
        weeklyChartStyleSegmented.isEnabled = enabled
        updateWeeklyChartMetric()
    }

    @objc private func weeklyChartStyleChanged() {
        let raw = weeklyChartStyleSegmented.selectedSegment
        guard let style = WeeklyChartStyle(rawValue: raw) else { return }
        viewModel.setWeeklyChartStyle(style)
    }

    @objc private func weeklyChartMetricChanged() {
        let metric: WeeklyChartMetric = weeklyChartMetricPopUp.indexOfSelectedItem == 0 ? .amount : .usageUnits
        viewModel.setWeeklyChartMetric(metric)
        updateWeeklyChartMetric()
    }
}
