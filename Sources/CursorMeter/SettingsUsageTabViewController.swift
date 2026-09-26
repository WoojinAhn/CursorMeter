import AppKit

@MainActor
final class SettingsUsageTabViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    private let viewModel: UsageViewModel
    private let refreshButton = RefreshFeedbackButton(style: .labeled, consumer: .recent)
    private let cachedLabel = NSTextField(labelWithString: "")
    private let failureColor = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? .systemOrange
            : NSColor(srgbRed: 0x95 / 255.0, green: 0x61 / 255.0, blue: 0x24 / 255.0, alpha: 1)
    }
    private let placeholderLabel = NSTextField(labelWithString: "")
    private let placeholderDetail = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private let zoneLabel = NSTextField(labelWithString: "")
    private let zoneControl = NSSegmentedControl(labels: ["Local", "UTC"], trackingMode: .selectOne,
                                                 target: nil, action: nil)
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private var rows: [RecentUsageEntry] = []
    private var renderedCandidate: RecentUsageCandidate?
    private var renderedTimeZone: RecentUsageTimeZone?
    private var renderedTimeZoneRevision: UInt64?

    init(viewModel: UsageViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "Usage"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("use init(viewModel:)") }

    override func loadView() {
        let heading = SettingsCardFactory.makeSectionHeader("Recent usage")
        heading.setAccessibilityLabel("Recent usage")
        cachedLabel.font = .systemFont(ofSize: 10)
        cachedLabel.textColor = .tertiaryLabelColor
        cachedLabel.setAccessibilityLabel("Cached at")
        countLabel.font = .systemFont(ofSize: 11)
        countLabel.textColor = .secondaryLabelColor
        zoneLabel.font = .systemFont(ofSize: 10)
        zoneLabel.textColor = .tertiaryLabelColor
        zoneControl.controlSize = .small
        zoneControl.target = self
        zoneControl.action = #selector(timeZoneChanged)
        zoneControl.setAccessibilityLabel("Time zone")
        refreshButton.target = self
        refreshButton.action = #selector(refreshTapped)

        tableView.headerView = nil
        tableView.style = .plain
        tableView.rowHeight = 44
        tableView.intercellSpacing = .zero
        tableView.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        tableView.allowsColumnResizing = false
        tableView.allowsColumnReordering = false
        tableView.selectionHighlightStyle = .none
        tableView.dataSource = self
        tableView.delegate = self
        tableView.setAccessibilityLabel("Recent usage events")
        for (id, width) in [("model", 233.0), ("tokens", 70.0), ("amount", 79.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.width = width
            column.minWidth = id == "model" ? 150 : width
            column.maxWidth = id == "model" ? 1_000 : width
            tableView.addTableColumn(column)
        }
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.setAccessibilityLabel("Recent usage events")

        placeholderLabel.font = .systemFont(ofSize: 12, weight: .medium)
        placeholderLabel.alignment = .center
        placeholderDetail.font = .systemFont(ofSize: 11)
        placeholderDetail.textColor = .secondaryLabelColor
        placeholderDetail.alignment = .center
        let placeholder = NSStackView(views: [placeholderLabel, placeholderDetail])
        placeholder.orientation = .vertical
        placeholder.alignment = .centerX
        placeholder.spacing = 5

        let tableHost = NSView()
        [scrollView, placeholder].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            tableHost.addSubview($0)
        }
        NSLayoutConstraint.activate([
            tableHost.heightAnchor.constraint(equalToConstant: 264),
            scrollView.leadingAnchor.constraint(equalTo: tableHost.leadingAnchor, constant: 11),
            scrollView.trailingAnchor.constraint(equalTo: tableHost.trailingAnchor, constant: -11),
            scrollView.topAnchor.constraint(equalTo: tableHost.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: tableHost.bottomAnchor),
            placeholder.centerXAnchor.constraint(equalTo: tableHost.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: tableHost.centerYAnchor),
            placeholder.leadingAnchor.constraint(greaterThanOrEqualTo: tableHost.leadingAnchor, constant: 14),
            placeholder.trailingAnchor.constraint(lessThanOrEqualTo: tableHost.trailingAnchor, constant: -14),
        ])

        let titleStack = NSStackView(views: [heading, cachedLabel])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3
        let header = NSStackView(views: [titleStack, SettingsCardFactory.makeSpacer(), refreshButton])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 6
        header.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 6, right: 14)

        let countRow = NSStackView(views: [countLabel, SettingsCardFactory.makeSpacer(), zoneLabel, zoneControl])
        countRow.orientation = .horizontal
        countRow.alignment = .centerY
        countRow.spacing = 7
        countRow.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)

        let caption = SettingsCardFactory.makeCaption("Included amounts show usage value covered by your plan.")
        let captionHost = SettingsCardFactory.makeFullWidthCardRow(caption)
        let openButton = NSButton(title: "Open Cursor ↗", target: self, action: #selector(openCursor))
        openButton.isBordered = false
        openButton.font = .systemFont(ofSize: 11)
        openButton.contentTintColor = .linkColor
        openButton.setAccessibilityLabel("Open Cursor")
        let footerTitle = NSTextField(labelWithString: "Full history and billing")
        footerTitle.font = .systemFont(ofSize: 11)
        footerTitle.textColor = .secondaryLabelColor
        let footer = NSStackView(views: [footerTitle, SettingsCardFactory.makeSpacer(), openButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.edgeInsets = NSEdgeInsets(top: 9, left: 14, bottom: 9, right: 14)

        let recentCard = SettingsCardFactory.makeCard(units: [
            header, SettingsCardFactory.makeDividedUnit(tableHost),
            SettingsCardFactory.makeDividedUnit(countRow), captionHost,
            SettingsCardFactory.makeDividedUnit(footer),
        ])
        view = SettingsCardFactory.makeTabRoot(sections: [recentCard], width: 440)
        view.setAccessibilityLabel("Usage")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        updateUI()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        preferredContentSize = view.fittingSize
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let width = scrollView.contentView.bounds.width
        guard width > 0 else { return }
        tableView.setFrameSize(NSSize(width: width, height: tableView.frame.height))
        tableView.sizeToFit()
    }

    func updateUI() {
        let snapshot = viewModel.recentUsage.snapshot
        let candidate = snapshot?.candidate
        let mode = viewModel.recentUsageTimeZone
        let revision = viewModel.recentUsageTimeZoneRevision
        if candidate != renderedCandidate || mode != renderedTimeZone || revision != renderedTimeZoneRevision {
            rows = candidate?.entries ?? []
            renderedCandidate = candidate
            renderedTimeZone = mode
            renderedTimeZoneRevision = revision
            tableView.reloadData()
        }
        let authenticated = viewModel.authState == .loggedIn
        let feedback = viewModel.refreshFeedback
        refreshButton.render(phase: feedback.phase, isReady: feedback.isReady,
                             attempt: feedback.currentAttempt, isAuthenticated: authenticated,
                             reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        zoneControl.selectedSegment = mode == .local ? 0 : 1
        zoneLabel.stringValue = RecentUsageFormatter.zoneLabel(mode: mode)
        let zoneIdentifier = RecentUsageFormatter.zoneIdentifier(mode: mode)
        zoneLabel.toolTip = zoneIdentifier
        zoneLabel.setAccessibilityHelp(zoneIdentifier)
        zoneControl.toolTip = zoneIdentifier
        zoneControl.setAccessibilityHelp(zoneIdentifier)
        let cachedText = candidate.map {
            "Cached \(RecentUsageFormatter.cachedTime($0.cachedAt, mode: mode)) \(RecentUsageFormatter.zoneLabel(mode: mode, at: $0.cachedAt))"
        } ?? ""
        let cacheStatus = NSMutableAttributedString(string: cachedText, attributes: [
            .font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.tertiaryLabelColor,
        ])
        if candidate != nil, viewModel.recentUsage.status == .failed, feedback.phase != .updating {
            cacheStatus.append(NSAttributedString(string: " · Update failed", attributes: [
                .font: NSFont.systemFont(ofSize: 10), .foregroundColor: failureColor,
            ]))
        }
        cachedLabel.attributedStringValue = cacheStatus
        countLabel.stringValue = candidate.map {
            $0.entries.count == 1 ? "Latest 1 request" : "\($0.entries.isEmpty ? "0 requests" : "Latest \($0.entries.count) requests")"
        } ?? ""
        scrollView.isHidden = rows.isEmpty
        placeholderLabel.isHidden = !rows.isEmpty
        placeholderDetail.isHidden = !rows.isEmpty
        if !authenticated {
            placeholderLabel.stringValue = "Connect Cursor to view recent usage."
            placeholderDetail.stringValue = ""
        } else if candidate == nil, viewModel.recentUsage.status == .failed, feedback.phase != .updating {
            placeholderLabel.stringValue = "Unable to load recent usage."
            placeholderDetail.stringValue = "Try again later."
        } else if candidate == nil {
            placeholderLabel.stringValue = "Loading recent usage…"
            placeholderDetail.stringValue = ""
        } else {
            placeholderLabel.stringValue = "No recent usage"
            placeholderDetail.stringValue = "New requests will appear here after Cursor reports them."
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, rows.indices.contains(row) else { return nil }
        let entry = rows[row]
        let mode = viewModel.recentUsageTimeZone
        let host = NSView()
        let primary: NSTextField
        let detail: NSTextField?
        switch tableColumn.identifier.rawValue {
        case "model":
            let fullModel = entry.model.flatMap { $0.isEmpty ? nil : $0 } ?? "—"
            primary = text(fullModel, size: 12, color: .labelColor)
            primary.lineBreakMode = .byTruncatingTail
            primary.toolTip = fullModel
            primary.setAccessibilityLabel(fullModel)
            detail = text("\(RecentUsageFormatter.eventTime(entry.date, mode: mode)) · \(entry.kind.title)",
                          size: 10, color: .secondaryLabelColor)
        case "tokens":
            primary = text(RecentUsageFormatter.tokens(entry.tokens), size: 11, color: .secondaryLabelColor)
            primary.alignment = .right
            primary.setAccessibilityHelp(entry.tokens.map { "\($0) tokens" } ?? "Tokens unavailable")
            detail = nil
        default:
            primary = text(RecentUsageFormatter.amount(cents: entry.chargedCents), size: 12, color: .labelColor)
            primary.font = .systemFont(ofSize: 12, weight: .medium)
            primary.alignment = .right
            detail = nil
        }
        host.addSubview(primary)
        primary.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            primary.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            primary.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
        ])
        if let detail {
            host.addSubview(detail)
            detail.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                primary.topAnchor.constraint(equalTo: host.topAnchor, constant: 7),
                detail.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                detail.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
                detail.topAnchor.constraint(equalTo: primary.bottomAnchor, constant: 2),
            ])
        } else {
            primary.centerYAnchor.constraint(equalTo: host.centerYAnchor).isActive = true
        }
        return host
    }

    private func text(_ value: String, size: CGFloat, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: size)
        label.textColor = color
        return label
    }

    @objc private func timeZoneChanged() {
        viewModel.setRecentUsageTimeZone(zoneControl.selectedSegment == 1 ? .utc : .local)
        updateUI()
    }

    @objc private func refreshTapped() {
        Task { await viewModel.refreshFromUser() }
    }

    @objc private func openCursor() {
        NSWorkspace.shared.open(URL(string: "https://www.cursor.com/dashboard?tab=usage")!)
    }
}
