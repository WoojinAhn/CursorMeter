import AppKit

// MARK: - MenuBarPopoverViewController

final class MenuBarPopoverViewController: NSViewController {

    // MARK: - Dependencies

    private let viewModel: UsageViewModel
    private let onLogin: () -> Void
    private let onSettings: () -> Void

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
    private let progressBar      = NSProgressIndicator()
    private let percentLabel     = NSTextField(labelWithString: "")

    // On-demand row (hidden when nil)
    private let onDemandRow      = NSStackView()
    private let onDemandKey      = NSTextField(labelWithString: "On-demand")
    private let onDemandValue    = NSTextField(labelWithString: "")

    // Reset + interval row
    private let resetLabel       = NSTextField(labelWithString: "")
    private let intervalButton   = NSPopUpButton()

    // Update row (hidden when nil)
    private let updateRow        = NSStackView()
    private let updateButton     = NSButton()
    private var updateURL: URL?

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

        progressBar.style                 = .bar
        progressBar.isIndeterminate       = false
        progressBar.minValue              = 0
        progressBar.maxValue              = 1
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

        // --- On-demand row ---
        onDemandRow.orientation = .horizontal
        onDemandRow.spacing = 4
        onDemandRow.translatesAutoresizingMaskIntoConstraints = false

        onDemandKey.font      = NSFont.systemFont(ofSize: 12, weight: .regular)
        onDemandKey.textColor = NSColor.secondaryLabelColor

        onDemandValue.font      = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        onDemandValue.textColor = NSColor.secondaryLabelColor

        let spacer3 = makeFlexibleSpacer()
        onDemandRow.addArrangedSubview(onDemandKey)
        onDemandRow.addArrangedSubview(spacer3)
        onDemandRow.addArrangedSubview(onDemandValue)

        dataStack.addArrangedSubview(onDemandRow)

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

    private func rebuildAuthButton() {
        authContainer.subviews.forEach { $0.removeFromSuperview() }

        let (title, icon): (String, String)
        let action: () -> Void

        switch viewModel.authState {
        case .loggedOut, .loginRequired:
            title  = "Log In..."
            icon   = "person"
            action = { [weak self] in self?.onLogin() }
        case .loggedIn:
            title  = "Log Out"
            icon   = "person.slash"
            action = { [weak self] in self?.viewModel.logout() }
        }

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
        let clampedRatio = min(data.percentUsed / 100.0, 1.0)
        progressBar.doubleValue  = clampedRatio
        applyProgressBarColor(progressNSColor(for: data.percentUsed))
        percentLabel.stringValue = data.percentText

        // On-demand
        if let text = data.onDemandText {
            onDemandValue.stringValue = text
            onDemandRow.isHidden      = false
        } else {
            onDemandRow.isHidden = true
        }

        // Reset
        resetLabel.stringValue = data.resetText ?? ""

        // Interval popup
        syncIntervalPopUp()
    }

    private func applyStatus() {
        // Clear previous status labels
        statusStack.arrangedSubviews.forEach {
            statusStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
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
        } else {
            label.stringValue = "Not logged in"
            label.textColor   = NSColor.secondaryLabelColor
        }

        statusStack.addArrangedSubview(label)
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

    // MARK: - Progress bar color

    /// NSProgressIndicator does not expose a tint API on macOS 14.
    /// The standard technique is to apply a CIFilter to the indicator's layer.
    private func applyProgressBarColor(_ color: NSColor) {
        progressBar.wantsLayer = true
        // Remove any previously applied color filter before setting a new one.
        progressBar.layer?.filters = nil

        guard let cgColor = color.usingColorSpace(.deviceRGB)?.cgColor,
              let components = cgColor.components, components.count >= 3 else { return }

        let r = components[0], g = components[1], b = components[2]
        // Use a color matrix CIFilter to tint the bar fill.
        // The matrix maps the original blue bar color to the desired color.
        let colorMatrix = CIFilter(name: "CIColorMatrix")
        colorMatrix?.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputRVector")
        colorMatrix?.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputGVector")
        colorMatrix?.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBVector")
        colorMatrix?.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        colorMatrix?.setValue(CIVector(x: r, y: g, z: b, w: 0), forKey: "inputBiasVector")
        if let filter = colorMatrix {
            progressBar.layer?.filters = [filter]
        }
    }

    // MARK: - Progress color (NSColor mapping matching CircularProgressIcon thresholds)

    private func progressNSColor(for percent: Double) -> NSColor {
        if percent >= 90 { return NSColor.systemRed }
        if percent >= 80 { return NSColor.systemYellow }
        return NSColor.systemGreen
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
        NSWorkspace.shared.open(url)
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
