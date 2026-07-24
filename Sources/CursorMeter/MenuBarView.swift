import AppKit

// MARK: - MenuBarPopoverViewController

final class MenuBarPopoverViewController: NSViewController {

    // MARK: - Dependencies

    private let viewModel: UsageViewModel
    private let onLogin: () -> Void
    private let onSettings: () -> Void

    /// Set by the owner so we can push a new size to the live NSPopover frame.
    /// `preferredContentSize` alone is not enough — popover only consults it on
    /// the first `show`, so toggles after that leave a stale frame behind.
    var onContentSizeChange: ((NSSize) -> Void)?

    // MARK: - Root layout

    private let rootStack = NSStackView()

    // MARK: - State section views (swapped in updateUI)

    private let statusStack = NSStackView()   // Loading / Error / Not-logged-in
    private let dataStack   = NSStackView()   // User info + usage (shown when data available)

    // MARK: - Data section subviews

    // User info row
    private let nameLabel        = NSTextField(labelWithString: "")
    private let badgeLabel       = NSTextField(labelWithString: "")
    private let emailLabel       = NSTextField(labelWithString: "")

    // Usage row
    private let usageTitleLabel  = NSTextField(labelWithString: "")
    private let usageValueLabel  = NSTextField(labelWithString: "")
    private let refreshButton    = NSButton()

    // Progress row
    private let progressBar      = ColoredProgressBar()
    private let percentLabel     = NSTextField(labelWithString: "")

    // Secondary metric row (hidden when no secondary data). In normal mode shows
    // On-demand; in on-demand mode shows the previous primary (Requests or Plan).
    private let secondaryRow      = NSStackView()
    private let secondaryKey      = NSTextField(labelWithString: "")
    private let secondaryValue    = NSTextField(labelWithString: "")

    // Weekly chart (enterprise teams only). `lazy var` so a user who never
    // opens the popover (or who's on a non-enterprise account) doesn't pay
    // for the chart NSView allocation up front.
    private lazy var weeklyChartContainer = NSView()
    private lazy var weeklyChartView = WeeklyUsageChartView(frame: .zero)
    private var weeklyChartHeightConstraint: NSLayoutConstraint!
    private var weeklyChartTopConstraint: NSLayoutConstraint!

    // Reset + interval row
    private let resetLabel       = NSTextField(labelWithString: "")
    private let intervalButton   = NSPopUpButton()

    // Update row (hidden when nil)
    private let updateRow        = NSStackView()
    private let updateButton     = NSButton()
    private var updateURL: URL?

    // Stale-data indicator (hidden unless viewModel.isDataStale) (#77)
    private let staleLabel       = NSTextField(labelWithString: "")
    // Explicit MainActor isolation: DateFormatter is mutable/non-Sendable and
    // CI's stricter Sendable checking may not infer isolation for statics.
    @MainActor private static let staleTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    // MARK: - Init

    init(viewModel: UsageViewModel, onLogin: @escaping () -> Void, onSettings: @escaping () -> Void) {
        self.viewModel  = viewModel
        self.onLogin    = onLogin
        self.onSettings = onSettings
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    // MARK: - loadView

    override func loadView() {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        view = container

        configureRootStack()
        buildLayout()

        NSLayoutConstraint.activate([
            rootStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            rootStack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            rootStack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            rootStack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            container.widthAnchor.constraint(equalToConstant: 260),
        ])
    }

    // MARK: - Public API

    /// Test seam (#87): width the popover content demands from AutoLayout.
    func testHook_contentFittingWidth() -> CGFloat { rootStack.fittingSize.width }

    /// Test seam (#94): current auth-row button (nil while the row is hidden).
    func testHook_authRowButton() -> NSButton? { authContainer.subviews.first as? NSButton }

    /// Called by the owner whenever viewModel state changes.
    func updateUI() {
        if let data = viewModel.usageData {
            applyData(data)
            statusStack.isHidden = true
            dataStack.isHidden   = false
        } else {
            applyStatus()
            statusStack.isHidden = false
            dataStack.isHidden   = true
        }

        // Stale-data indicator (#77)
        if viewModel.isDataStale {
            let timeString = viewModel.lastSuccessAt.map(Self.staleTimeFormatter.string(from:)) ?? "—"
            staleLabel.stringValue = "⚠️ Last updated \(timeString) — retrying every \(viewModel.refreshInterval.label)"
            staleLabel.isHidden = false
        } else {
            staleLabel.isHidden = true
        }

        // Update row
        if let update = viewModel.availableUpdate {
            updateButton.title = "Update available: v\(update.version)"
            updateURL = URL(string: update.htmlURL)
            updateRow.isHidden = false
        } else {
            updateRow.isHidden = true
        }

        // Login / Logout button title
        updateAuthRow()

        // NSPopover pins the root view to the host frame, so `view.fittingSize`
        // can stay inflated after a row collapses. Measure the internal stack
        // instead (which is not pinned) and add the fixed outer padding.
        // Sync now, then re-publish on the next run loop tick to catch
        // layouts NSStackView defers after a constraint constant change.
        view.layoutSubtreeIfNeeded()
        publishCurrentSize()
        DispatchQueue.main.async { [weak self] in
            self?.view.layoutSubtreeIfNeeded()
            self?.publishCurrentSize()
        }
    }

    private func publishCurrentSize() {
        let size = NSSize(width: 260, height: ceil(rootStack.fittingSize.height + 12))
        preferredContentSize = size
        onContentSizeChange?(size)
    }

    // MARK: - Layout construction

    private func configureRootStack() {
        rootStack.orientation = .vertical
        rootStack.alignment   = .leading
        rootStack.spacing     = 2
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(rootStack)
    }

    private func buildLayout() {
        // --- Data section (user info + usage) ---
        buildDataStack()

        // --- Status section (loading / error / not logged in) ---
        buildStatusStack()

        // Swap between data and status
        rootStack.addArrangedSubview(dataStack)
        rootStack.addArrangedSubview(statusStack)

        rootStack.addArrangedSubview(makeDivider())

        // --- Action rows ---
        rootStack.addArrangedSubview(makeMenuRow("Open Dashboard", symbolName: "arrow.up.right") {
            if let url = URL(string: "https://www.cursor.com/dashboard?tab=usage") {
                NSWorkspace.shared.open(url)
            }
        })

        rootStack.addArrangedSubview(makeMenuRow("Settings...", symbolName: "gear") { [weak self] in
            self?.onSettings()
        })

        rootStack.addArrangedSubview(makeAuthRow())

        // Update row (initially hidden)
        buildUpdateRow()
        rootStack.addArrangedSubview(updateRow)

        rootStack.addArrangedSubview(makeDivider())

        rootStack.addArrangedSubview(makeMenuRow("Quit", symbolName: nil) {
            NSApplication.shared.terminate(nil)
        })

        // Expand all rows to fill the full width
        for view in rootStack.arrangedSubviews {
            view.translatesAutoresizingMaskIntoConstraints = false
            view.widthAnchor.constraint(equalTo: rootStack.widthAnchor).isActive = true
        }
    }

    // MARK: - Data stack

    private func buildDataStack() {
        dataStack.orientation = .vertical
        dataStack.alignment   = .leading
        dataStack.spacing     = 2
        dataStack.translatesAutoresizingMaskIntoConstraints = false

        // --- User info row ---
        let userInfoRow = NSStackView()
        userInfoRow.orientation = .horizontal
        userInfoRow.spacing = 5
        userInfoRow.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font      = NSFont.systemFont(ofSize: 13, weight: .semibold)
        nameLabel.textColor = NSColor.labelColor
        nameLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        styleBadge(badgeLabel)

        emailLabel.font      = NSFont.systemFont(ofSize: 10, weight: .regular)
        emailLabel.textColor = NSColor.secondaryLabelColor
        emailLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        emailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let spacer1 = makeFlexibleSpacer()
        userInfoRow.addArrangedSubview(nameLabel)
        userInfoRow.addArrangedSubview(badgeLabel)
        userInfoRow.addArrangedSubview(spacer1)
        userInfoRow.addArrangedSubview(emailLabel)

        dataStack.addArrangedSubview(userInfoRow)
        dataStack.addArrangedSubview(makeDivider())

        // --- Usage label + value + refresh ---
        let usageRow = NSStackView()
        usageRow.orientation = .horizontal
        usageRow.spacing = 4
        usageRow.translatesAutoresizingMaskIntoConstraints = false

        usageTitleLabel.font      = NSFont.systemFont(ofSize: 12, weight: .regular)
        usageTitleLabel.textColor = NSColor.secondaryLabelColor
        usageTitleLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        usageValueLabel.font      = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        usageValueLabel.textColor = NSColor.secondaryLabelColor
        usageValueLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        styleIconButton(refreshButton, symbolName: "arrow.clockwise", size: 10)
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)

        let spacer2 = makeFlexibleSpacer()
        usageRow.addArrangedSubview(usageTitleLabel)
        usageRow.addArrangedSubview(spacer2)
        usageRow.addArrangedSubview(usageValueLabel)
        usageRow.addArrangedSubview(refreshButton)

        dataStack.addArrangedSubview(usageRow)

        // --- Progress bar + percent ---
        let progressRow = NSStackView()
        progressRow.orientation = .horizontal
        progressRow.spacing = 6
        progressRow.translatesAutoresizingMaskIntoConstraints = false

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.heightAnchor.constraint(equalToConstant: 6).isActive = true
        progressBar.setContentHuggingPriority(.defaultLow, for: .horizontal)

        percentLabel.font      = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        percentLabel.textColor = NSColor.secondaryLabelColor
        percentLabel.alignment = .right
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        percentLabel.widthAnchor.constraint(equalToConstant: 32).isActive = true

        progressRow.addArrangedSubview(progressBar)
        progressRow.addArrangedSubview(percentLabel)

        dataStack.addArrangedSubview(progressRow)

        // --- Secondary metric row ---
        secondaryRow.orientation = .horizontal
        secondaryRow.spacing = 4
        secondaryRow.translatesAutoresizingMaskIntoConstraints = false

        secondaryKey.font      = NSFont.systemFont(ofSize: 12, weight: .regular)
        secondaryKey.textColor = NSColor.secondaryLabelColor

        secondaryValue.font      = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        secondaryValue.textColor = NSColor.secondaryLabelColor

        let spacer3 = makeFlexibleSpacer()
        secondaryRow.addArrangedSubview(secondaryKey)
        secondaryRow.addArrangedSubview(spacer3)
        secondaryRow.addArrangedSubview(secondaryValue)

        dataStack.addArrangedSubview(secondaryRow)

        // --- Weekly chart (enterprise) ---
        // The container stays in `dataStack` for its lifetime; toggling the
        // height constraint to 0 (instead of detaching the view) sidesteps
        // an NSStackView/AutoLayout quirk where `fittingSize` keeps caching
        // the inflated value after `removeArrangedSubview`.
        weeklyChartContainer.translatesAutoresizingMaskIntoConstraints = false
        weeklyChartView.translatesAutoresizingMaskIntoConstraints = false
        weeklyChartContainer.addSubview(weeklyChartView)
        weeklyChartTopConstraint = weeklyChartView.topAnchor.constraint(equalTo: weeklyChartContainer.topAnchor, constant: 4)
        weeklyChartHeightConstraint = weeklyChartContainer.heightAnchor.constraint(equalToConstant: 76)
        NSLayoutConstraint.activate([
            weeklyChartTopConstraint,
            weeklyChartView.bottomAnchor.constraint(equalTo: weeklyChartContainer.bottomAnchor),
            weeklyChartView.leadingAnchor.constraint(equalTo: weeklyChartContainer.leadingAnchor),
            weeklyChartView.trailingAnchor.constraint(equalTo: weeklyChartContainer.trailingAnchor),
            weeklyChartHeightConstraint,
        ])
        weeklyChartContainer.clipsToBounds = true
        dataStack.addArrangedSubview(weeklyChartContainer)

        // Default to collapsed; applyData decides visibility per refresh.
        weeklyChartHeightConstraint.constant = 0
        weeklyChartTopConstraint.constant = 0
        weeklyChartView.isHidden = true

        // --- Reset date + interval ---
        let bottomRow = NSStackView()
        bottomRow.orientation = .horizontal
        bottomRow.spacing = 4
        bottomRow.translatesAutoresizingMaskIntoConstraints = false

        resetLabel.font      = NSFont.systemFont(ofSize: 10, weight: .regular)
        resetLabel.textColor = NSColor.tertiaryLabelColor

        styleIntervalPopUp(intervalButton)

        let spacer4 = makeFlexibleSpacer()
        bottomRow.addArrangedSubview(resetLabel)
        bottomRow.addArrangedSubview(spacer4)
        bottomRow.addArrangedSubview(intervalButton)

        dataStack.addArrangedSubview(bottomRow)

        // --- Stale-data indicator (hidden by default) ---
        staleLabel.font      = NSFont.systemFont(ofSize: 11)
        staleLabel.textColor = CircularProgressIcon.warnColor
        staleLabel.isHidden  = true
        // #87: the message can exceed the 240pt inner width. Its width demand
        // must stay below fittingSize priority (50) so the text truncates
        // instead of inflating the content view past the popover window frame.
        staleLabel.lineBreakMode = .byTruncatingTail
        staleLabel.setContentCompressionResistancePriority(
            .init(NSLayoutConstraint.Priority.fittingSizeCompression.rawValue - 1),
            for: .horizontal
        )
        dataStack.addArrangedSubview(staleLabel)

        // Make all rows in dataStack fill full width
        for arrangedView in dataStack.arrangedSubviews {
            arrangedView.translatesAutoresizingMaskIntoConstraints = false
            arrangedView.widthAnchor.constraint(equalTo: dataStack.widthAnchor).isActive = true
        }
    }

    // MARK: - Status stack

    private func buildStatusStack() {
        statusStack.orientation = .vertical
        statusStack.alignment   = .leading
        statusStack.spacing     = 2
        statusStack.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - Auth row

    private let authContainer = NSView()

    private func makeAuthRow() -> NSView {
        authContainer.translatesAutoresizingMaskIntoConstraints = false
        authContainer.identifier = NSUserInterfaceItemIdentifier("authRow")
        rebuildAuthButton()
        return authContainer
    }

    private func updateAuthRow() {
        rebuildAuthButton()
    }

    /// Derived state of the currently built auth row ("hidden" or the button
    /// title). Guards rebuildAuthButton against recreating an identical button
    /// on every updateUI pass (#94).
    private var lastAuthRowKey: String?

    private func rebuildAuthButton() {
        let (title, icon): (String, String)
        let action: () -> Void

        switch viewModel.authState {
        case .loggedOut, .loginRequired:
            // #90: browser login is deprecated — the row shows only when
            // opted in (or the IDE app is absent). The login layout above
            // already carries the recovery hint when hidden.
            let ideInstalled = viewModel.ideAppPresenceCheck?() ?? true
            guard UsageViewModel.shouldShowBrowserLogin(
                enabled: viewModel.browserLoginEnabled, ideInstalled: ideInstalled)
            else {
                guard lastAuthRowKey != "hidden" else { return }
                lastAuthRowKey = "hidden"
                authContainer.subviews.forEach { $0.removeFromSuperview() }
                authContainer.isHidden = true
                return
            }
            title  = "Log in with Browser... (deprecated)"
            icon   = "person"
            action = { [weak self] in self?.onLogin() }
        case .loggedIn:
            title  = "Log Out"
            icon   = "person.slash"
            action = { [weak self] in self?.viewModel.logout() }
        }
        guard lastAuthRowKey != title else { return }
        lastAuthRowKey = title
        authContainer.subviews.forEach { $0.removeFromSuperview() }
        authContainer.isHidden = false

        let btn = makeMenuRowButton(title: title, symbolName: icon, action: action)
        btn.translatesAutoresizingMaskIntoConstraints = false
        authContainer.addSubview(btn)
        NSLayoutConstraint.activate([
            btn.topAnchor.constraint(equalTo: authContainer.topAnchor),
            btn.bottomAnchor.constraint(equalTo: authContainer.bottomAnchor),
            btn.leadingAnchor.constraint(equalTo: authContainer.leadingAnchor),
            btn.trailingAnchor.constraint(equalTo: authContainer.trailingAnchor),
        ])
    }

    // MARK: - Update row

    private func buildUpdateRow() {
        updateRow.orientation = .vertical
        updateRow.alignment   = .leading
        updateRow.spacing     = 0
        updateRow.isHidden    = true
        updateRow.translatesAutoresizingMaskIntoConstraints = false

        updateButton.bezelStyle      = .inline
        updateButton.isBordered      = false
        updateButton.alignment       = .left
        updateButton.font            = NSFont.systemFont(ofSize: 13)
        updateButton.contentTintColor = NSColor.systemBlue
        if let img = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: nil) {
            updateButton.image          = img
            updateButton.imagePosition  = .imageLeft
            updateButton.imageScaling   = .scaleProportionallyDown
        }
        updateButton.target = self
        updateButton.action = #selector(openUpdateURL)
        updateButton.translatesAutoresizingMaskIntoConstraints = false
        updateButton.heightAnchor.constraint(equalToConstant: 26).isActive = true

        updateRow.addArrangedSubview(updateButton)
    }

    // MARK: - Apply state

    private func applyData(_ data: UsageDisplayData) {
        // User info
        nameLabel.stringValue = data.name
        emailLabel.stringValue = data.email

        if let type = data.membershipType {
            badgeLabel.stringValue = type.capitalized
            badgeLabel.isHidden    = false
        } else {
            badgeLabel.isHidden = true
        }

        // Usage
        usageTitleLabel.stringValue = data.usageLabel
        usageValueLabel.stringValue = data.usageText
        refreshButton.isEnabled     = !viewModel.isLoading
        refreshButton.isHidden      = (viewModel.authState != .loggedIn)

        // Progress
        progressBar.progress = min(data.percentUsed / 100.0, 1.0)
        progressBar.barColor = CircularProgressIcon.tokenColor(for: data.percentUsed)
        percentLabel.stringValue = data.percentText

        // Secondary metric row (label + value vary by mode — see UsageDisplayData)
        if let label = data.secondaryUsageLabel, let value = data.secondaryUsageValue {
            secondaryKey.stringValue   = label
            secondaryValue.stringValue = value
            // Highlight over-limit values in red so the user immediately notices
            // the previous-primary dimension is exceeded while in on-demand mode.
            secondaryValue.textColor = data.secondaryUsageIsOverLimit
                ? NSColor.systemRed
                : NSColor.secondaryLabelColor
            secondaryRow.isHidden = false
        } else {
            secondaryRow.isHidden = true
        }

        // Weekly chart (enterprise + master toggle gate).
        if viewModel.weeklyChartEnabled,
           viewModel.weeklyChartAvailable,
           let weekly = viewModel.weeklyData, weekly.count == 7
        {
            weeklyChartView.update(
                days: weekly,
                style: viewModel.weeklyChartStyle,
                creditBased: data.isCreditBased
            )
            setWeeklyChartVisible(true)
        } else {
            setWeeklyChartVisible(false)
        }

        // Reset
        resetLabel.stringValue = data.resetText ?? ""
        resetLabel.toolTip = data.resetAbsoluteText

        // Interval popup
        syncIntervalPopUp()
    }

    private func setWeeklyChartVisible(_ visible: Bool) {
        // `weeklyChartHeightConstraint` / `weeklyChartTopConstraint` are
        // populated inside `buildDataStack` (only called from `loadView`).
        // Guard so an early `updateUI()` (e.g. fired from `observePopover`
        // before the popover is shown) can't trip an implicit-unwrap crash.
        guard let heightConstraint = weeklyChartHeightConstraint,
              let topConstraint = weeklyChartTopConstraint
        else { return }
        heightConstraint.constant = visible ? 76 : 0
        topConstraint.constant = visible ? 4 : 0
        weeklyChartView.isHidden = !visible
        weeklyChartContainer.invalidateIntrinsicContentSize()
        dataStack.needsLayout = true
        rootStack.needsLayout = true
        view.needsLayout = true
    }

    private func applyStatus() {
        // Clear previous status labels
        statusStack.arrangedSubviews.forEach {
            statusStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }

        // applyLoginRequiredStatus() overrides these and the stack persists
        // across state changes — restore the configured defaults each pass.
        statusStack.alignment = .leading
        statusStack.spacing   = 2

        if viewModel.authState == .loginRequired
            || (viewModel.authState == .loggedOut && !viewModel.isLoading && viewModel.errorMessage == nil) {
            applyLoginRequiredStatus()
            return
        }

        let label = NSTextField(labelWithString: "")
        label.font = NSFont.systemFont(ofSize: 13)

        if viewModel.isLoading {
            label.stringValue = "Loading..."
            label.textColor   = NSColor.secondaryLabelColor
        } else if let error = viewModel.errorMessage {
            label.stringValue = "Error: \(error)"
            label.textColor   = NSColor.systemRed
            label.font        = NSFont.systemFont(ofSize: 11)
        }

        statusStack.addArrangedSubview(label)
    }

    /// Logged-out / expired state: IDE-first guidance (#54) with the browser
    /// login as the secondary path (#76 kept the prominent recovery layout).
    /// Branches on IDE credential availability (#88): when the IDE has no
    /// session, [Connect Cursor IDE] is replaced by an [Open Cursor IDE]
    /// inducement (or hidden entirely when the IDE app is absent) and the
    /// browser login becomes the default action.
    private func applyLoginRequiredStatus() {
        // Re-probe on every render; the observable flag re-renders this
        // layout when the answer changes (popover reopen included).
        viewModel.refreshIDEAvailability()

        statusStack.orientation = .vertical
        statusStack.alignment   = .centerX
        statusStack.spacing     = 6

        let title = NSTextField(labelWithString:
            viewModel.authState == .loginRequired ? "⚠️ Session expired" : "Not connected")
        title.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        statusStack.addArrangedSubview(title)

        let ideUnavailable = viewModel.ideCredentialAvailable == false
        // #90: presence is an independent render-time input (spec matrix),
        // no longer derived only inside the unavailable branch.
        let ideInstalled = viewModel.ideAppPresenceCheck?() ?? true
        let showBrowser = UsageViewModel.shouldShowBrowserLogin(
            enabled: viewModel.browserLoginEnabled, ideInstalled: ideInstalled)

        let bodyText: String
        if !ideInstalled {
            bodyText = "Log in with your browser to connect."
        } else if ideUnavailable {
            bodyText = "Cursor IDE is not signed in. Open it and sign in — this app connects automatically."
        } else {
            // Available or still unknown (nil): never degrade the primary path.
            bodyText = "Sign in to the Cursor IDE to connect automatically."
        }
        let body = NSTextField(wrappingLabelWithString: bodyText)
        body.font      = NSFont.systemFont(ofSize: 11)
        body.textColor = NSColor.secondaryLabelColor
        body.alignment = .center
        body.preferredMaxLayoutWidth = 220
        statusStack.addArrangedSubview(body)

        // IDE button always carries Enter when present (#90 supersedes the
        // #88 rule — a deprecated path must never be the default action).
        if ideInstalled {
            if ideUnavailable {
                let openButton = NSButton(
                    title: "Open Cursor IDE",
                    target: self,
                    action: #selector(openIDETapped))
                openButton.bezelStyle    = .rounded
                openButton.keyEquivalent = "\r"
                statusStack.addArrangedSubview(openButton)
            } else {
                let connectButton = NSButton(
                    title: "Connect Cursor IDE",
                    target: self,
                    action: #selector(connectIDETapped))
                connectButton.bezelStyle    = .rounded
                connectButton.keyEquivalent = "\r"
                statusStack.addArrangedSubview(connectButton)
            }
        }

        if showBrowser {
            let browserButton = NSButton(
                title: "Log in with Browser (deprecated)",
                target: self,
                action: #selector(loginRequiredLoginTapped))
            browserButton.bezelStyle = .rounded
            if !ideInstalled {
                browserButton.keyEquivalent = "\r"   // sole button in this state
            }
            statusStack.addArrangedSubview(browserButton)
        } else {
            let hint = NSTextField(labelWithString: "Browser login can be enabled in Settings.")
            hint.font      = NSFont.systemFont(ofSize: 10)
            hint.textColor = NSColor.tertiaryLabelColor
            statusStack.addArrangedSubview(hint)
        }
    }

    @objc private func connectIDETapped() {
        viewModel.connectViaIDE()
    }

    @objc private func openIDETapped() {
        viewModel.openIDEAndWatch()
    }

    @objc private func loginRequiredLoginTapped() {
        onLogin()
    }

    // MARK: - Interval popup

    private func styleIntervalPopUp(_ popup: NSPopUpButton) {
        popup.bezelStyle  = .inline
        popup.isBordered  = false
        popup.font        = NSFont.systemFont(ofSize: 10)
        popup.removeAllItems()

        for interval in RefreshInterval.allCases {
            popup.addItem(withTitle: "⏱ \(interval.label)")
            popup.lastItem?.representedObject = interval
            popup.lastItem?.tag = interval.rawValue
        }

        popup.target = self
        popup.action = #selector(intervalChanged(_:))
        popup.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    }

    private func syncIntervalPopUp() {
        let current = viewModel.refreshInterval
        for item in intervalButton.itemArray {
            if let interval = item.representedObject as? RefreshInterval, interval == current {
                intervalButton.select(item)
                break
            }
        }
    }

    // MARK: - Factory helpers

    private func makeDivider() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        box.translatesAutoresizingMaskIntoConstraints = false
        return box
    }

    private func makeFlexibleSpacer() -> NSView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spacer.translatesAutoresizingMaskIntoConstraints = false
        return spacer
    }

    /// Returns an NSView container housing a plain-style menu-row button.
    private func makeMenuRow(_ title: String, symbolName: String?, action: @escaping () -> Void) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let btn = makeMenuRowButton(title: title, symbolName: symbolName, action: action)
        btn.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(btn)

        NSLayoutConstraint.activate([
            btn.topAnchor.constraint(equalTo: container.topAnchor),
            btn.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            btn.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            btn.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        return container
    }

    private func makeMenuRowButton(
        title: String,
        symbolName: String?,
        action: @escaping () -> Void
    ) -> MenuRowButton {
        let btn = MenuRowButton(action: action)
        btn.title       = title
        btn.font        = NSFont.systemFont(ofSize: 13)
        btn.alignment   = .left
        btn.isBordered  = false
        btn.bezelStyle  = .inline

        if let name = symbolName,
           let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            btn.image         = img
            btn.imagePosition = .imageLeft
            btn.imageScaling  = .scaleProportionallyDown
        }

        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.heightAnchor.constraint(equalToConstant: 26).isActive = true
        return btn
    }

    private func styleIconButton(_ button: NSButton, symbolName: String, size: CGFloat) {
        button.bezelStyle  = .inline
        button.isBordered  = false
        button.title       = ""
        if let img = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
            button.image        = img.withSymbolConfiguration(cfg)
            button.imageScaling = .scaleProportionallyDown
        }
        button.contentTintColor = NSColor.secondaryLabelColor
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    private func styleBadge(_ label: NSTextField) {
        label.font            = NSFont.systemFont(ofSize: 9, weight: .medium)
        label.textColor       = NSColor.secondaryLabelColor
        label.backgroundColor = NSColor.quaternaryLabelColor
        label.drawsBackground = true
        label.isBezeled       = false
        label.isEditable      = false
        label.isSelectable    = false
        label.wantsLayer      = true
        label.layer?.cornerRadius = 3
        label.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    }

    // MARK: - Actions

    @objc private func refreshTapped() {
        Task { await viewModel.refresh() }
    }

    @objc private func intervalChanged(_ sender: NSPopUpButton) {
        guard let interval = sender.selectedItem?.representedObject as? RefreshInterval else { return }
        viewModel.setRefreshInterval(interval)
    }

    @objc private func openUpdateURL() {
        guard let url = updateURL else { return }
        ExternalURL.openGitHub(url)
    }
}

// MARK: - MenuRowButton

/// A borderless button that highlights its background on hover, matching menu-item feel.
private final class MenuRowButton: NSButton {

    private let actionHandler: () -> Void
    private var isHovered = false

    init(action: @escaping () -> Void) {
        self.actionHandler = action
        super.init(frame: .zero)
        target = self
        self.action = #selector(buttonClicked)
        wantsLayer = true
        layer?.cornerRadius = 4
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.08).cgColor
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        layer?.backgroundColor = nil
    }

    // MARK: Action

    @objc private func buttonClicked() {
        actionHandler()
    }
}

// MARK: - ColoredProgressBar

/// A simple custom progress bar that draws fill and track with explicit colors.
private final class ColoredProgressBar: NSView {

    var progress: Double = 0 {
        didSet { needsDisplay = true }
    }

    var barColor: NSColor = .systemGreen {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 3
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let trackColor = NSColor.quaternaryLabelColor
        let rect = bounds

        // Track
        trackColor.setFill()
        let trackPath = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
        trackPath.fill()

        // Fill
        let fillWidth = rect.width * CGFloat(min(max(progress, 0), 1))
        if fillWidth > 0 {
            let fillRect = NSRect(x: 0, y: 0, width: fillWidth, height: rect.height)
            barColor.setFill()
            let fillPath = NSBezierPath(roundedRect: fillRect, xRadius: 3, yRadius: 3)
            fillPath.fill()
        }
    }
}
