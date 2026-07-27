import AppKit
import ServiceManagement

// MARK: - SettingsGeneralTabViewController

/// General tab: Refresh, Startup, Version sections (#99).
@MainActor
final class SettingsGeneralTabViewController: NSViewController {

    private let viewModel: UsageViewModel

    // MARK: - Controls (retained as instance vars for updateUI)

    private var intervalPopUp = NSPopUpButton()
    private var activityRefreshToggle = NSSwitch()
    private var launchAtLoginToggle = NSSwitch()
    private var browserLoginToggle = NSSwitch()
    private var authSourceLabel = NSTextField(labelWithString: "")
    private var updateStatusLabel = NSTextField(labelWithString: "")
    private var updateSpinner = NSProgressIndicator()
    private var checkNowButton = NSButton()
    private var downloadButton = NSButton()

    // MARK: - Init

    init(viewModel: UsageViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
        title = "General"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("use init(viewModel:)") }

    // MARK: - Lifecycle

    override func loadView() {
        view = SettingsCardFactory.makeTabRoot(sections: [
            SettingsCardFactory.makeSection(header: "Refresh", content: makeRefreshCard()),
            SettingsCardFactory.makeSection(header: "Startup", content: makeStartupCard()),
            SettingsCardFactory.makeSection(header: "Version", content: makeVersionCard()),
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
        let currentIndex = RefreshInterval.allCases.firstIndex(of: viewModel.refreshInterval) ?? 0
        intervalPopUp.selectItem(at: currentIndex)
        activityRefreshToggle.state = viewModel.activityRefreshEnabled ? .on : .off
        launchAtLoginToggle.state = SMAppService.mainApp.status == .enabled ? .on : .off
        browserLoginToggle.state = viewModel.browserLoginEnabled ? .on : .off

        // #54: which credential source authenticated the current session.
        authSourceLabel.stringValue = {
            switch viewModel.activeAuthSource {
            case .cursorIDE:    return "Auth: Cursor IDE"
            case .browserLogin: return "Auth: Browser login"
            case nil:           return "Auth: —"
            }
        }()

        updateUpdatesUI()
    }

    // MARK: - Cards

    private func makeRefreshCard() -> NSView {
        intervalPopUp = NSPopUpButton()
        for interval in RefreshInterval.allCases {
            intervalPopUp.addItem(withTitle: interval.label)
        }
        intervalPopUp.target = self
        intervalPopUp.action = #selector(intervalChanged)

        activityRefreshToggle = NSSwitch()
        activityRefreshToggle.target = self
        activityRefreshToggle.action = #selector(activityRefreshToggleChanged)

        return SettingsCardFactory.makeCard(units: [
            SettingsCardFactory.makeCardRow(title: "Interval", control: intervalPopUp),
            SettingsCardFactory.makeDividedUnit(SettingsCardFactory.makeCardRow(
                title: "Refresh on Cursor activity",
                caption: "Refreshes ~1 min after Cursor use; Interval is the fallback.",
                control: activityRefreshToggle
            )),
        ])
    }

    private func makeStartupCard() -> NSView {
        launchAtLoginToggle = NSSwitch()
        launchAtLoginToggle.target = self
        launchAtLoginToggle.action = #selector(launchAtLoginChanged)

        // #90: browser login is deprecated — opt-in only.
        browserLoginToggle = NSSwitch()
        browserLoginToggle.target = self
        browserLoginToggle.action = #selector(browserLoginToggleChanged)

        return SettingsCardFactory.makeCard(units: [
            SettingsCardFactory.makeCardRow(title: "Launch at login", control: launchAtLoginToggle),
            SettingsCardFactory.makeDividedUnit(SettingsCardFactory.makeCardRow(
                title: "Enable browser login",
                caption: "Deprecated — Cursor IDE connection is the supported sign-in path.",
                control: browserLoginToggle
            )),
        ])
    }

    private func makeVersionCard() -> NSView {
        updateStatusLabel = NSTextField(labelWithString: "")
        updateStatusLabel.font = .systemFont(ofSize: 13)
        updateStatusLabel.textColor = .secondaryLabelColor
        // Long states ("Couldn't check (…)") must truncate, not push the
        // window past contentWidth (#101).
        updateStatusLabel.lineBreakMode = .byTruncatingTail
        updateStatusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        updateSpinner = NSProgressIndicator()
        updateSpinner.style = .spinning
        updateSpinner.controlSize = .small
        updateSpinner.isHidden = true
        updateSpinner.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            updateSpinner.widthAnchor.constraint(equalToConstant: 16),
            updateSpinner.heightAnchor.constraint(equalToConstant: 16),
        ])

        checkNowButton = NSButton(title: "Check Now", target: self, action: #selector(checkNowTapped))
        checkNowButton.bezelStyle = .rounded

        downloadButton = NSButton(title: "Download", target: self, action: #selector(downloadTapped))
        downloadButton.bezelStyle = .rounded

        let statusRow = NSStackView(views: [
            updateSpinner, updateStatusLabel, SettingsCardFactory.makeSpacer(),
            checkNowButton, downloadButton,
        ])
        statusRow.orientation = .horizontal
        statusRow.alignment = .centerY
        statusRow.spacing = 6
        statusRow.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

        // #54 auth source + credits.
        authSourceLabel.font = .systemFont(ofSize: 11)
        authSourceLabel.textColor = .secondaryLabelColor

        let authorLabel = NSTextField(labelWithString: "Made by WoojinAhn ·")
        authorLabel.font = .systemFont(ofSize: 11)
        authorLabel.textColor = .tertiaryLabelColor

        let githubLink = NSButton(title: "GitHub ↗", target: self, action: #selector(openGitHub))
        githubLink.isBordered = false
        githubLink.font = .systemFont(ofSize: 11)
        githubLink.contentTintColor = .linkColor

        let authorRow = NSStackView(views: [authorLabel, githubLink, SettingsCardFactory.makeSpacer()])
        authorRow.orientation = .horizontal
        authorRow.spacing = 2

        let aboutStack = NSStackView(views: [authSourceLabel, authorRow])
        aboutStack.orientation = .vertical
        aboutStack.alignment = .leading
        aboutStack.spacing = 3
        aboutStack.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)

        return SettingsCardFactory.makeCard(units: [
            statusRow,
            SettingsCardFactory.makeDividedUnit(aboutStack),
        ])
    }

    // MARK: - Actions

    @objc private func intervalChanged() {
        let index = intervalPopUp.indexOfSelectedItem
        guard index >= 0, index < RefreshInterval.allCases.count else { return }
        viewModel.setRefreshInterval(RefreshInterval.allCases[index])
    }

    @objc private func activityRefreshToggleChanged() {
        viewModel.setActivityRefreshEnabled(activityRefreshToggle.state == .on)
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

    @objc private func browserLoginToggleChanged() {
        viewModel.setBrowserLoginEnabled(browserLoginToggle.state == .on)
    }

    @objc private func openGitHub() {
        ExternalURL.openGitHub(URL(string: "https://github.com/WoojinAhn/CursorMeter")!)
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
        ExternalURL.openGitHub(url)
    }

    // MARK: - Updates UI

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// "2026-07-27T01:20:00Z" → "2026-07-27 10:20" (local). Falls back to the
    /// raw string on parse failure. Formatter-per-call: runs once per
    /// updateUI, and a shared mutable DateFormatter is a concurrency footgun.
    private static func devBuildDateText(_ iso: String?) -> String? {
        guard let iso else { return nil }
        let parser = ISO8601DateFormatter()
        guard let date = parser.date(from: iso) else { return iso }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    private func updateUpdatesUI() {
        // Dev build (#109): show provenance, never the update-check UI — the
        // stamped 0.1.0 placeholder makes release comparisons meaningless.
        if let commit = viewModel.devBuildCommit {
            updateSpinner.isHidden = true
            updateSpinner.stopAnimation(nil)
            let date = Self.devBuildDateText(viewModel.devBuildDate).map { " · built \($0)" } ?? ""
            updateStatusLabel.stringValue = "Dev build \(commit)\(date)"
            updateStatusLabel.textColor = .secondaryLabelColor
            checkNowButton.isHidden = true
            downloadButton.isHidden = true
            return
        }

        if viewModel.isCheckingUpdate {
            updateSpinner.isHidden = false
            updateSpinner.startAnimation(nil)
            updateStatusLabel.stringValue = "v\(currentVersion) · Checking..."
            updateStatusLabel.textColor = .secondaryLabelColor
            checkNowButton.isHidden = true
            downloadButton.isHidden = true
            return
        }

        updateSpinner.isHidden = true
        updateSpinner.stopAnimation(nil)

        switch viewModel.lastUpdateCheckResult {
        case .available(let release):
            updateStatusLabel.stringValue = "v\(currentVersion) · v\(release.version) new"
            updateStatusLabel.textColor = .labelColor
            checkNowButton.isHidden = true
            downloadButton.isHidden = false
        case .failed(let reason):
            updateStatusLabel.stringValue = "v\(currentVersion) · Couldn't check (\(reason))"
            updateStatusLabel.textColor = .secondaryLabelColor
            checkNowButton.isHidden = false
            downloadButton.isHidden = true
        case .upToDate, nil:
            updateStatusLabel.stringValue = "v\(currentVersion) · Up to date"
            updateStatusLabel.textColor = .secondaryLabelColor
            checkNowButton.isHidden = false
            downloadButton.isHidden = true
        }
    }
}
