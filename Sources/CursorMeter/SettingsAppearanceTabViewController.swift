import AppKit

// MARK: - SettingsAppearanceTabViewController

/// Appearance tab: menu bar text, usage jump, weekly chart (#99).
@MainActor
final class SettingsAppearanceTabViewController: NSViewController {

    private let viewModel: UsageViewModel
    private let screenHeight: (() -> CGFloat)?
    private let scrollView = NSScrollView()
    private var content = NSView()
    private var viewportHeight: NSLayoutConstraint?

    // MARK: - Controls (retained as instance vars for updateUI)

    private var menuBarDisplayPopUp = NSPopUpButton()
    private let outerPoolPopUp = NSPopUpButton()
    private let poolLegend = SettingsCardFactory.makeCaption("")
    private let poolPreview = NSImageView()
    private var legacyTextRow = NSView()
    private var splitPlacementRows = NSView()
    private var menuBarSection = NSView()
    private var popoverSection = NSView()
    private var popoverValuesSegmented = NSSegmentedControl()
    private let valuePreview = SettingsCardFactory.makeCaption("")
    private let estimatedLimitsToggle = NSSwitch()
    private let estimateInfoButton = KeyboardAccessibleInfoButton()
    private let estimateHelp = EstimatedLimitsHelpController()
    private var estimatedLimitsRow = NSView()
    private var boldExplanation = NSView()
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

    init(viewModel: UsageViewModel, screenHeight: (() -> CGFloat)? = nil) {
        self.viewModel = viewModel
        self.screenHeight = screenHeight
        super.init(nibName: nil, bundle: nil)
        title = "Display"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("use init(viewModel:)") }

    // MARK: - Lifecycle

    override func loadView() {
        weeklyChartSection = SettingsCardFactory.makeSection(
            header: "Weekly Chart", content: makeWeeklyChartCard())
        menuBarSection = SettingsCardFactory.makeSection(header: "Menu Bar", content: makeMenuBarCard())
        popoverSection = SettingsCardFactory.makeSection(header: "Popover", content: makePopoverCard())
        content = SettingsCardFactory.makeTabRoot(sections: [
            menuBarSection,
            popoverSection,
            SettingsCardFactory.makeSection(header: "Usage Jump", content: makeJumpCard()),
            weeklyChartSection,
        ])
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.setAccessibilityLabel("Display settings")
        let document = AppearanceDocumentView()
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

    // NSTabViewController animates the window to the selected child's
    // preferredContentSize on tab switch — it does NOT read fitting sizes
    // by itself. Report ours each time this tab is about to show.
    override func viewWillAppear() {
        super.viewWillAppear()
        updateViewport()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateViewport()
    }

    // MARK: - Public API

    func updateUI() {
        // Menu bar display mode — percent-only plans have no ratio denominator
        // at all (Cursor's own dashboard shows no ratio concept on free), so
        // the Ratio item is HIDDEN there, not disabled (#107). Items are
        // tag-addressed (tag = mode value) so removal can't shift the mapping.
        // The popup reflects the EFFECTIVE mode (None stays None, #105) via
        // the same resolver the status item uses.
        let split = viewModel.splitUsage.suppressesLegacyMeter
        let percentOnly = !split && viewModel.usageData?.isPercentOnly == true
        let ratioIndex = menuBarDisplayPopUp.indexOfItem(withTag: 1)
        if percentOnly {
            if ratioIndex >= 0 { menuBarDisplayPopUp.removeItem(at: ratioIndex) }
        } else if ratioIndex < 0 {
            menuBarDisplayPopUp.insertItem(withTitle: Self.ratioItemTitle, at: 1)
            menuBarDisplayPopUp.item(at: 1)?.tag = 1
        }
        menuBarDisplayPopUp.selectItem(withTag: UsageViewModel.resolvedMenuBarDisplayMode(
            isPercentOnly: percentOnly, setting: viewModel.menuBarDisplayMode))
        menuBarDisplayPopUp.isEnabled = !split
        legacyTextRow.isHidden = split
        splitPlacementRows.isHidden = !split
        menuBarSection.isHidden = !split && viewModel.usageData == nil
        let verifiedSplit = viewModel.splitUsage.eligibility == .eligible
        let monetaryLegacy = !split && (viewModel.usageData?.isCreditBased == true || viewModel.usageData?.isOnDemandActive == true)
        popoverSection.isHidden = !verifiedSplit && !monetaryLegacy
        estimatedLimitsRow.isHidden = !verifiedSplit
        popoverValuesSegmented.selectedSegment = viewModel.popoverValueMode.rawValue
        estimatedLimitsToggle.state = viewModel.estimatedLimitsEnabled ? .on : .off
        if verifiedSplit, let presentation = viewModel.splitPresentation {
            valuePreview.stringValue = presentation.pools.map { pool in
                let detail = pool.detailText.map { " · " + $0 } ?? ""
                return "\(pool.id.displayName): \(pool.readoutText)\(detail)"
            }.joined(separator: "\n")
        } else if monetaryLegacy, let data = viewModel.usageData {
            switch viewModel.popoverValueMode {
            case .percent: valuePreview.stringValue = data.percentText
            case .dollars: valuePreview.stringValue = data.usageText
            case .both: valuePreview.stringValue = "\(data.percentText) · \(data.usageText)"
            }
        } else {
            valuePreview.stringValue = ""
        }
        outerPoolPopUp.selectItem(at: viewModel.splitOuterPool == .other ? 0 : 1)
        outerPoolPopUp.isEnabled = viewModel.splitUsage.eligibility != .legacy
        let center: UsagePoolID = viewModel.splitOuterPool == .other ? .cursor : .other
        poolLegend.stringValue = "Outer: \(viewModel.splitOuterPool.displayName)\nCenter: \(center.displayName)"
        poolPreview.image = CircularProgressIcon.makeSplitImage(
            cursorPercent: viewModel.splitUsage.snapshot?.cursorPercent,
            otherPercent: viewModel.splitUsage.snapshot?.otherPercent,
            outerPool: viewModel.splitOuterPool)
        poolPreview.setAccessibilityLabel(poolLegend.stringValue)

        jumpEffectToggle.state = viewModel.jumpEffectEnabled ? .on : .off
        jumpIntensitySegmented.selectedSegment = viewModel.jumpIntensity.rawValue
        jumpGlyphStyleSegmented.selectedSegment = viewModel.jumpGlyphStyle.rawValue
        jumpSubRowsContainer.isHidden = !viewModel.jumpEffectEnabled
        boldExplanation.isHidden = !viewModel.jumpEffectEnabled || viewModel.jumpIntensity != .bold

        // Keep chart preferences reachable when the weekly endpoint is unavailable.
        weeklyChartSection.isHidden = viewModel.authState != .loggedIn
        weeklyChartToggle.state = viewModel.weeklyChartEnabled ? .on : .off
        weeklyChartStyleSegmented.selectedSegment = viewModel.weeklyChartStyle.rawValue
        weeklyChartStyleSegmented.isEnabled = viewModel.weeklyChartEnabled
        updateWeeklyChartMetric()
        updateViewport()
    }

    private func updateViewport() {
        content.layoutSubtreeIfNeeded()
        let screen = screenHeight?() ?? view.window?.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height ?? 800
        // Once attached, reserve the actual title bar and toolbar as well as
        // a screen-edge margin. Recalculate after layout and visibility changes.
        let chrome = view.window.map { max(0, $0.frame.height - $0.contentLayoutRect.height) } ?? 0
        let height = min(ceil(content.fittingSize.height), max(1, floor(screen - chrome - 20)))
        viewportHeight?.constant = height
        let size = NSSize(width: SettingsCardFactory.contentWidth, height: height)
        if preferredContentSize != size { preferredContentSize = size }
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
        menuBarDisplayPopUp.setAccessibilityLabel("Legacy usage text")
        outerPoolPopUp.addItems(withTitles: ["Other Models", "Cursor Models"])
        outerPoolPopUp.target = self
        outerPoolPopUp.action = #selector(outerPoolChanged)
        outerPoolPopUp.setAccessibilityLabel("Outer ring")
        poolPreview.imageScaling = .scaleProportionallyUpOrDown
        poolPreview.widthAnchor.constraint(equalToConstant: 28).isActive = true
        poolPreview.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let legend = NSStackView(views: [poolPreview, poolLegend, SettingsCardFactory.makeSpacer()])
        legend.orientation = .horizontal
        legend.spacing = 12

        let previewHelp = "Icon colors use 70% and 90%. Alert thresholds are configured separately."
        poolPreview.toolTip = previewHelp
        poolPreview.setAccessibilityHelp(previewHelp)
        legacyTextRow = SettingsCardFactory.makeCardRow(title: "Usage text", control: menuBarDisplayPopUp)
        splitPlacementRows = SettingsCardFactory.makeCard(units: [
            SettingsCardFactory.makeCardRow(title: "Outer ring", control: outerPoolPopUp),
            SettingsCardFactory.makeFullWidthCardRow(legend),
        ])
        return SettingsCardFactory.makeCard(units: [legacyTextRow, splitPlacementRows])
    }

    private func makePopoverCard() -> NSView {
        popoverValuesSegmented = NSSegmentedControl(
            labels: ["%", "$", "Both"], trackingMode: .selectOne,
            target: self, action: #selector(popoverValueModeChanged))
        popoverValuesSegmented.setAccessibilityLabel("Popover values")
        estimatedLimitsToggle.target = self
        estimatedLimitsToggle.action = #selector(estimatedLimitsChanged)
        estimatedLimitsToggle.setAccessibilityLabel("Show estimated limits")
        estimateInfoButton.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        estimateInfoButton.isBordered = false
        estimateInfoButton.title = ""
        estimateInfoButton.setAccessibilityLabel("About estimated limits")
        estimateInfoButton.toolTip = "About estimated limits"
        estimateInfoButton.target = self
        estimateInfoButton.action = #selector(showEstimateHelp)
        estimateHelp.onShow = { [weak self] in self?.viewModel.markEstimateExplanationSeen() }
        let controls = NSStackView(views: [estimateInfoButton, estimatedLimitsToggle])
        controls.orientation = .horizontal
        controls.spacing = 8
        estimatedLimitsRow = SettingsCardFactory.makeDividedUnit(
            SettingsCardFactory.makeCardRow(title: "Show estimated limits", control: controls))
        valuePreview.setAccessibilityLabel("Popover values preview")
        return SettingsCardFactory.makeCard(units: [
            SettingsCardFactory.makeCardRow(title: "Usage values", control: popoverValuesSegmented),
            SettingsCardFactory.makeFullWidthCardRow(valuePreview),
            estimatedLimitsRow,
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

        boldExplanation = SettingsCardFactory.makeFullWidthCardRow(
            SettingsCardFactory.makeCaption("Large jumps also send a notification."))
        let subRows = NSStackView(views: [
            SettingsCardFactory.makeDividedUnit(SettingsCardFactory.makeCardRow(
                title: "Intensity", control: jumpIntensitySegmented)),
            SettingsCardFactory.makeDividedUnit(SettingsCardFactory.makeCardRow(
                title: "Style", control: jumpGlyphStyleSegmented)),
            boldExplanation,
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

    @objc private func popoverValueModeChanged() {
        guard let mode = PopoverValueMode(rawValue: popoverValuesSegmented.selectedSegment) else { return }
        viewModel.setPopoverValueMode(mode)
        updateUI()
    }

    @objc private func estimatedLimitsChanged() {
        let enabled = estimatedLimitsToggle.state == .on
        let firstEnable = enabled && !viewModel.estimatedLimitsEnabled && !viewModel.estimateExplanationSeen
        viewModel.setEstimatedLimitsEnabled(enabled)
        updateUI()
        if firstEnable { showEstimateHelp() }
    }

    func testHook_estimateHelp() -> EstimatedLimitsHelpController { estimateHelp }

    @objc private func showEstimateHelp() {
        estimateHelp.show(relativeTo: estimateInfoButton)
    }

    @objc private func menuBarDisplayModeChanged() {
        guard let tag = menuBarDisplayPopUp.selectedItem?.tag else { return }
        viewModel.setMenuBarDisplayMode(tag)
    }

    @objc private func outerPoolChanged() {
        viewModel.setSplitOuterPool(outerPoolPopUp.indexOfSelectedItem == 0 ? .other : .cursor)
        updateUI()
    }

    @objc private func jumpEffectToggleChanged() {
        let enabled = jumpEffectToggle.state == .on
        viewModel.setJumpEffectEnabled(enabled)
        // animator().isHidden in an NSStackView is misleading: layout removes
        // the view immediately while alpha fades over the animation window, so
        // siblings appear to jump first and the view "blinks" away. Setting
        // isHidden directly avoids the mid-animation discontinuity.
        updateUI()
    }

    @objc private func jumpIntensityChanged() {
        let raw = jumpIntensitySegmented.selectedSegment
        guard let intensity = JumpIntensity(rawValue: raw) else { return }
        viewModel.setJumpIntensity(intensity)
        updateUI()
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
        updateViewport()
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
        updateViewport()
    }
}

private final class AppearanceDocumentView: NSView {
    override var isFlipped: Bool { true }
}
