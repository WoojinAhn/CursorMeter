import Foundation
import Observation

enum AuthState {
    case loggedOut
    case loggedIn
    case loginRequired
}

/// Credential origin for the active session (#54).
enum AuthSource: Sendable, Equatable {
    case cursorIDE
    case browserLogin
}

/// Centralized UserDefaults keys. Avoids the typo class of bug where a
/// setter writes one literal and `loadSettings` reads a slightly different one.
private enum SettingsKey: String {
    case refreshInterval = "refreshIntervalSeconds"
    case notificationEnabled
    case warningThreshold
    case criticalThreshold
    case menuBarDisplayMode
    case jumpEffectEnabled
    case jumpIntensity
    case jumpGlyphStyle
    case weeklyChartEnabled
    case weeklyChartStyle
    case appStatusNotificationEnabled
    case lastNotifiedUpdateVersion
    case sessionExpiryHistory
    case ideAuthSuppressed
    case browserLoginEnabled
    case activityRefreshEnabled
    // Legacy keys consulted only by `loadSettings` migration block.
    case legacyShowMenuBarText = "showMenuBarText"
    case legacyShowMenuBarPercent = "showMenuBarPercent"
}

private extension UserDefaults {
    func set(_ value: Any?, for key: SettingsKey) { set(value, forKey: key.rawValue) }
    func object(for key: SettingsKey) -> Any? { object(forKey: key.rawValue) }
}

enum RefreshInterval: Int, CaseIterable {
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300
    case fifteenMinutes = 900

    var label: String {
        switch self {
        case .oneMinute: "1 min"
        case .twoMinutes: "2 min"
        case .fiveMinutes: "5 min"
        case .fifteenMinutes: "15 min"
        }
    }
}

/// Origin of an update-check result. Only automatic checks may notify —
/// a manual check's result is already on screen in the settings window.
enum UpdateCheckSource: Sendable, Equatable {
    case automatic
    case manual
}

// MARK: - Jump Effect Types

/// Magnitude of a usage jump between successive refreshes.
struct JumpEvent: Sendable, Equatable {
    enum Tier: Int, Sendable { case zero = 0, one = 1, two = 2 }

    /// Display mode the delta was computed in. Determines `displayDelta` formatting.
    enum Mode: Sendable, Equatable {
        case credit       // USD cents
        case request      // request count
        case percent      // server-provided percent (%-points)
        case onDemand     // USD cents (on-demand billing dimension)
    }

    let tier: Tier
    /// Delta in canonical units (cents / requests / %-points).
    let deltaCanonical: Double
    /// Delta as % of plan limit (used for tier classification).
    let deltaPct: Double
    let mode: Mode
    /// User-facing string already formatted with sign (e.g. "+$0.30", "+30 / 50", "+15.0%").
    let displayDelta: String
    let timestamp: Date
}

/// User-selectable visual intensity for the jump effect.
enum JumpIntensity: Int, Sendable, CaseIterable {
    case quiet = 0
    case normal = 1
    case bold = 2
}

/// User-selectable emoji pair for the jump effect. `classic` keeps the
/// original energy/propulsion theme; `dollar` swaps to spend semantics for
/// users whose mental model centers on dollar burn.
enum JumpGlyphStyle: Int, Sendable, CaseIterable {
    case classic = 0   // ⚡ / 🚀
    case dollar = 1    // 💲 / 💸
}

/// Today-bar emphasis style for the weekly chart.
enum WeeklyChartStyle: Int, Sendable, CaseIterable {
    case outline = 0
    case dimOthers = 1
    case both = 2
}

@Observable
@MainActor
final class UsageViewModel {
    // MARK: - Auth & Data

    var authState: AuthState = .loggedOut
    /// Which credential source authenticated the most recent successful
    /// refresh (#54). nil while logged out. Read by the settings window.
    var activeAuthSource: AuthSource?
    /// True after an explicit Log Out — the IDE source stays disabled until
    /// the user reconnects (Connect Cursor IDE / browser login), otherwise
    /// logout would silently resurrect on the next refresh (#54).
    private(set) var ideAuthSuppressed: Bool = false
    var usageData: UsageDisplayData?
    var errorMessage: String?
    var isLoading = false
    /// Consecutive failed refreshes (any failure except the unauthorized →
    /// logout path). Drives the stale-data indicator (#77).
    private(set) var consecutiveFailureCount = 0
    /// Awake-only failure counter feeding the refresh-failing notification
    /// (#112). Failures while the display is asleep (system sleep / dark
    /// wake) are expected noise and don't advance it, so the ==threshold
    /// edge can't fire mid-sleep — while `consecutiveFailureCount` above
    /// keeps the stale indicator truthful across the same stretch.
    @ObservationIgnored private(set) var notificationFailureCount = 0
    /// Wall-clock time of the last successful refresh — the stale line's
    /// "Last updated" timestamp.
    private(set) var lastSuccessAt: Date?
    /// Failures before cached data is flagged stale (5 × default 2-min
    /// interval ≈ 10 min without an update).
    nonisolated static let staleThreshold = 5

    var isDataStale: Bool {
        usageData != nil && consecutiveFailureCount >= Self.staleThreshold
    }

    /// Release notification eligibility (#83). Pure so dedup logic is unit-testable.
    nonisolated static func shouldNotifyUpdate(version: String, lastNotified: String?, enabled: Bool) -> Bool {
        enabled && version != lastNotified
    }

    /// Error notification fires exactly on the transition to stale (== not >=),
    /// so failures 6, 7, … don't re-fire; a success resets the counter and re-arms.
    nonisolated static func shouldNotifyRefreshFailing(failureCount: Int, enabled: Bool) -> Bool {
        enabled && failureCount == staleThreshold
    }

    /// Session-expiry audit history cap (#84): ~50 entries covers a year of
    /// even weekly expiries while bounding the UserDefaults payload.
    nonisolated static let expiryHistoryCap = 50

    nonisolated static func cappedExpiryHistory(_ history: [Date], appending date: Date) -> [Date] {
        var result = history + [date]
        if result.count > expiryHistoryCap {
            result.removeFirst(result.count - expiryHistoryCap)
        }
        return result
    }
    /// Outcome of the most recent update check (nil = never checked this session).
    /// Settings UI consults this to distinguish "up to date" from "check failed";
    /// the popover only cares about `availableUpdate` (computed below).
    var lastUpdateCheckResult: UpdateCheckResult?
    /// Convenience for callers that only care about "is there a new release?".
    /// Returns nil for both `.upToDate` and `.failed` so existing popover code
    /// keeps working unchanged.
    var availableUpdate: UpdateChecker.Release? {
        if case .available(let release) = lastUpdateCheckResult { return release }
        return nil
    }
    var isCheckingUpdate = false
    /// Wall-clock time of the most recent update check (launch, manual, or
    /// periodic). Gates the periodic re-check for long-running instances (#80).
    @ObservationIgnored private var lastUpdateCheckAt: Date?

    /// Dev-build provenance markers stamped into Info.plist by package_app.sh
    /// on non-release channels (#109). A non-nil commit short-circuits every
    /// update-check path — a dev build comparing its placeholder 0.1.0 against
    /// GitHub Releases is pure noise. Internal (not private) so tests can
    /// simulate a dev bundle; immutable in production after launch.
    @ObservationIgnored internal var devBuildCommit: String? =
        Bundle.main.object(forInfoDictionaryKey: "CMDevBuildCommit") as? String
    @ObservationIgnored internal var devBuildDate: String? =
        Bundle.main.object(forInfoDictionaryKey: "CMDevBuildDate") as? String

    // MARK: - Settings

    var refreshInterval: RefreshInterval = .fiveMinutes
    var notificationEnabled: Bool = true
    var warningThreshold: Int = 80
    var criticalThreshold: Int = 90
    /// 0 = none, 1 = fraction (e.g. 120/500), 2 = percent (e.g. 24%)
    var menuBarDisplayMode: Int = 0
    /// Unified toggle for app-status notifications (#83): new-release and
    /// refresh-failing. Independent of usage-threshold and jump settings.
    var appStatusNotificationEnabled: Bool = true
    /// Browser login is deprecated (#90): hidden unless the user opts in.
    /// The IDE-absent case auto-exposes it regardless (zero-path guard).
    var browserLoginEnabled: Bool = false

    /// Single source of truth for every browser-login surface (#90).
    nonisolated static func shouldShowBrowserLogin(enabled: Bool, ideInstalled: Bool) -> Bool {
        enabled || !ideInstalled
    }

    // MARK: - Jump Effect

    /// Last detected jump (set on every successful refresh that produced a positive delta).
    /// `nil` while no jump has occurred since launch (or after skip conditions).
    var lastJump: JumpEvent?
    var jumpEffectEnabled: Bool = true
    var jumpIntensity: JumpIntensity = .normal
    var jumpGlyphStyle: JumpGlyphStyle = .classic

    // MARK: - Weekly Chart

    /// Last successful weekly fetch, retained across failed refreshes so the
    /// chart keeps rendering when the network blips.
    var weeklyData: [DayUsage]?
    /// True when a weekly fetch succeeded for the active account (enterprise
    /// team path or personal teamId-0 path, #103). Gates the popover chart and
    /// the Settings weekly-chart section.
    var weeklyChartAvailable: Bool = false
    var weeklyChartEnabled: Bool = true
    var weeklyChartStyle: WeeklyChartStyle = .outline

    // MARK: - Private

    private var isRefreshing = false
    private let apiClient: CursorAPIClient
    private var refreshTask: Task<Void, Never>?
    private var cachedCookieHeader: String?
    private let notificationManager = NotificationManager()

    /// Keychain deletion, injectable for tests — the default deletes the real
    /// `com.cursormeter.session` item, which tests must never touch.
    @ObservationIgnored internal var keychainDeleteHandler: () throws -> Void =
        KeychainStore.deleteCookieHeader

    /// Expiry-notification hook, injectable for tests. nil → real
    /// NotificationManager path (UNUserNotificationCenter crashes in the SPM
    /// test host, so tests always override this).
    @ObservationIgnored internal var sessionExpiredNotifier: (@MainActor () async -> Void)?

    /// App-status notification hooks (#83), injectable for tests. Unlike
    /// `sessionExpiredNotifier` these have NO real fallback: nil → skip.
    /// Production wires them in CursorMeterApp; a nil seam must never reach
    /// UNUserNotificationCenter (SPM test host crash) or queue work.
    @ObservationIgnored internal var updateAvailableNotifier: (@MainActor (_ version: String, _ releaseURL: String) async -> Void)?
    @ObservationIgnored internal var refreshFailingNotifier: (@MainActor () async -> Void)?

    /// #112 sleep-aware notification seams. Same nil contract as the #83
    /// notifiers: production wires them in CursorMeterApp; nil → treated as
    /// display-awake / skip withdrawal, so the SPM test host never touches
    /// CGDisplay* or UNUserNotificationCenter.
    @ObservationIgnored internal var displayAsleepChecker: (() -> Bool)?
    @ObservationIgnored internal var refreshFailingWithdrawer: (@MainActor () -> Void)?

    /// Update-check runner, injectable for tests (#83). The startup/periodic
    /// checks otherwise hit the real GitHub API from the SPM test host (whose
    /// Bundle version falls back to "0.0.0", making every release "newer") and
    /// could write `lastNotifiedUpdateVersion` nondeterministically mid-suite.
    @ObservationIgnored internal var updateCheckRunner: @MainActor () async -> UpdateCheckResult = {
        await UpdateChecker.shared.check()
    }

    /// IDE credential source (#54), nil by default so the SPM test host can
    /// never read the developer's real state.vscdb; production wires the real
    /// CursorAppAuthReader in CursorMeterApp (same pattern as the #83 seams).
    @ObservationIgnored internal var ideCredentialProvider: (@Sendable () -> IDECredential?)?

    // MARK: - IDE availability & sign-in watch (#88)

    /// Whether the Cursor IDE currently has a session. nil until the first
    /// check completes; drives the login-required layout branch. Presence
    /// only — intentionally ignores `ideAuthSuppressed` (display concern).
    var ideCredentialAvailable: Bool?

    /// Is the Cursor IDE app installed? Production wires NSWorkspace lookup.
    @ObservationIgnored internal var ideAppPresenceCheck: (() -> Bool)?
    /// Launches the Cursor IDE app; completion reports launch success.
    @ObservationIgnored internal var ideAppLauncher: ((@escaping @MainActor (Bool) -> Void) -> Void)?
    @ObservationIgnored internal var watchTickInterval: Duration = .seconds(3)
    @ObservationIgnored internal var watchTimeout: Duration = .seconds(60)

    /// Event-driven refresh (#92): activity from CursorActivityWatcher is
    /// debounced, then deferred past a min-interval guard shared with every
    /// other refresh source. Defer — never drop — so a burst always lands.
    var activityRefreshEnabled = true
    @ObservationIgnored internal var activityDebounceInterval: Duration = .seconds(5)
    @ObservationIgnored internal var activityMinRefreshInterval: Duration = .seconds(60)
    @ObservationIgnored private var activityDebounceTask: Task<Void, Never>?
    @ObservationIgnored private var activityGeneration = 0
    @ObservationIgnored private var lastRefreshAttempt: ContinuousClock.Instant?

    /// Two separate monotonic tokens (codex review): sharing one would let a
    /// routine availability probe (every login-layout render) invalidate an
    /// active watch.
    /// - `ideProbeGeneration` orders availability reads: a stale off-main
    ///   result can never overwrite a newer flag.
    /// - `ideWatchGeneration` scopes the watch and the pending launch
    ///   completion: bumped on restart and logout, so a late launch success
    ///   or provider read can neither start nor continue a watch the user
    ///   has implicitly cancelled.
    @ObservationIgnored private var ideProbeGeneration = 0
    @ObservationIgnored private var ideWatchGeneration = 0
    @ObservationIgnored private var availabilityCheckInFlight = false
    @ObservationIgnored private var ideSignInWatchTask: Task<Void, Never>?

    /// Async availability probe (login-layout render path). Deduped while a
    /// read is in flight; writes the flag only on change so observation does
    /// not re-render (and re-probe) in a loop.
    func refreshIDEAvailability() {
        guard let provider = ideCredentialProvider, !availabilityCheckInFlight else { return }
        availabilityCheckInFlight = true
        ideProbeGeneration += 1
        let generation = ideProbeGeneration
        Task { [weak self] in
            let available = await Task.detached { provider() != nil }.value
            guard let self else { return }
            self.availabilityCheckInFlight = false
            guard generation == self.ideProbeGeneration else { return }
            self.setIDEAvailability(available)
        }
    }

    private func setIDEAvailability(_ available: Bool) {
        if ideCredentialAvailable != available {
            ideCredentialAvailable = available
        }
    }

    /// [Open Cursor IDE]: launch the IDE; only a successful launch starts the
    /// sign-in watch (a failed launch must not leave a background poll).
    func openIDEAndWatch() {
        guard let launcher = ideAppLauncher else { return }
        let generation = ideWatchGeneration
        launcher { [weak self] success in
            guard let self, success,
                  generation == self.ideWatchGeneration else { return }
            self.beginIDESignInWatch()
        }
    }

    /// Polls the IDE credential (tick/timeout above) and auto-connects when
    /// the user finishes signing in. Per tick: logged in → stop; credential
    /// present and no refresh in flight → connect (a collision retries next
    /// tick). Restart cancels the prior task; logout invalidates any pending
    /// read via the generation token.
    func beginIDESignInWatch() {
        ideSignInWatchTask?.cancel()
        guard let provider = ideCredentialProvider else { return }
        ideWatchGeneration += 1
        let generation = ideWatchGeneration
        let interval = watchTickInterval
        let timeout = watchTimeout
        ideSignInWatchTask = Task { [weak self] in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)
            while !Task.isCancelled, clock.now < deadline {
                guard let self, self.authState != .loggedIn else { return }
                let found = await Task.detached { provider() != nil }.value
                guard !Task.isCancelled, generation == self.ideWatchGeneration else { return }
                if found, self.authState != .loggedIn, !self.isRefreshing {
                    self.connectViaIDE()
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    // Previous canonical values for delta tracking. Reset to nil when display mode changes
    // (e.g. plan migration) so we don't compare across incompatible units.
    private var previousPlanUsedCents: Int?
    private var previousRequestsUsed: Int?
    private var previousServerPercent: Double?
    private var previousOnDemandUsedCents: Int?
    private var previousMode: JumpEvent.Mode?

    /// Discovered team id, cached after the first successful teams fetch.
    /// Stays set across refreshes so we don't re-call `/api/dashboard/teams`
    /// on every cycle.
    private var cachedTeamId: Int?

    /// Numeric user id (e.g. 232352588) for the dashboard filtered-usage endpoint.
    /// Discovered from `/api/dashboard/get-team-spend` and cached across refreshes.
    private var cachedUserId: Int?

    /// Which weekly-fetch shape succeeded last for the active account. Drives
    /// the optimistic parallel fetch on subsequent refreshes (#103). Internal
    /// (not private) so tests can assert invalidation; never mutated outside
    /// this file.
    enum WeeklyMode: Equatable, Sendable {
        case enterprise(teamId: Int, userId: Int)
        case personal
    }
    @ObservationIgnored internal private(set) var cachedWeeklyMode: WeeklyMode?

    /// Per-seat on-demand limit (whole dollars) for token-based enterprise plans,
    /// from the team-spend roster. Cached across refreshes (heavier fetch); feeds
    /// the personal on-demand row. nil when unset or not applicable.
    private var cachedOnDemandLimitDollars: Int?

    /// Last observed billing-cycle start. Used to detect cycle rollover so we
    /// can clear the threshold-notification dedup set and let the user know
    /// when usage crosses 80/90 in the new cycle.
    private var previousCycleStart: Date?

    /// Sticky-latched flag: once on-demand mode is entered, it persists until the
    /// billing cycle rolls over (or the user logs out). Prevents oscillation from
    /// API jitter at the request-limit boundary.
    private var isOnDemandLatched: Bool = false

    // MARK: - Init

    init(apiClient: CursorAPIClient = CursorAPIClient()) {
        self.apiClient = apiClient
        loadSettings()
        lastUpdateCheckAt = Date()
        Task {
            guard devBuildCommit == nil else { return }
            let result = await updateCheckRunner()
            await recordUpdateCheckResult(result, source: .automatic)
        }
    }

    // MARK: - Session

    func checkExistingSession() {
        do {
            if let header = try KeychainStore.loadCookieHeader() {
                cachedCookieHeader = header
                startSession()
                return
            }
        } catch {
            Log.error("Failed to load keychain: \(error)")
        }
        // No captured cookie — the IDE source may still authenticate (#54).
        if !ideAuthSuppressed, ideCredentialProvider != nil {
            startSession()
        }
    }

    /// Re-enables the IDE credential source after a logout and starts a
    /// session; the chain resolves the actual credential on refresh (#54).
    func connectViaIDE() {
        ideAuthSuppressed = false
        UserDefaults.standard.set(false, for: .ideAuthSuppressed)
        startSession()
    }

    func onLoginSuccess(cookieHeader: String) {
        cachedCookieHeader = cookieHeader
        // Explicit reconnect intent — re-enable the IDE source too (#54).
        ideAuthSuppressed = false
        UserDefaults.standard.set(false, for: .ideAuthSuppressed)
        // The previous session's per-account caches must not leak into the
        // new account — a user signing in to a different team would
        // otherwise see the prior team's weekly data, baselines, and
        // membership flag until the next logout/login round-trip.
        resetPerAccountState()
        do {
            try KeychainStore.saveCookieHeader(cookieHeader)
            Log.info("Cookie header saved to Keychain")
        } catch {
            Log.error("Failed to save cookie: \(error)")
        }
        startSession()
    }

    /// Identity of the account behind the last successful refresh (#54).
    @ObservationIgnored private var lastAccountEmail: String?

    /// Returns true when a switch was detected — callers must then discard
    /// any in-flight work that captured the previous account's cached ids.
    @discardableResult
    private func resetIfAccountSwitched(newEmail: String?) -> Bool {
        guard let newEmail else { return false }
        defer { lastAccountEmail = newEmail }
        guard let previous = lastAccountEmail, previous != newEmail else { return false }
        Log.error("Account switched — resetting per-account state (#54)")
        resetPerAccountState()
        notificationManager.resetNotifications()
        previousPlanUsedCents = nil
        previousRequestsUsed = nil
        previousServerPercent = nil
        previousOnDemandUsedCents = nil
        previousMode = nil
        lastJump = nil
        return true
    }

    private func resetPerAccountState() {
        cachedTeamId = nil
        cachedUserId = nil
        cachedOnDemandLimitDollars = nil
        cachedWeeklyMode = nil
        weeklyData = nil
        weeklyChartAvailable = false
        previousCycleStart = nil
        isOnDemandLatched = false
        previousPlanUsedCents = nil
        previousRequestsUsed = nil
        previousServerPercent = nil
        previousOnDemandUsedCents = nil
        previousMode = nil
        lastJump = nil
        notificationManager.resetNotifications()
    }

    private func startSession() {
        authState = .loggedIn
        Task { await refresh() }
        startAutoRefresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        lastRefreshAttempt = ContinuousClock.now
        isRefreshing = true
        isLoading = true
        errorMessage = nil
        defer {
            isLoading = false
            isRefreshing = false
        }

        // Chain step 1: IDE credential (#54). Read off-main — the reader's
        // SQLite busy_timeout can block up to 250ms. The read also publishes
        // availability (#88) so a failed connect flips the login layout to
        // the guidance state immediately.
        if let provider = ideCredentialProvider, !ideAuthSuppressed {
            let ideCredential = await Task.detached(operation: { provider() }).value
            setIDEAvailability(ideCredential != nil)
            if let ide = ideCredential {
                do {
                    try await runRefreshAttempt(cookieHeader: ide.cookieHeader)
                    authState = .loggedIn
                    activeAuthSource = .cursorIDE
                    return
                } catch APIError.unauthorized {
                    // Fall through to the captured cookie. The IDE credential is
                    // unrelated to it — never clear keychain or notify here.
                    Log.error("IDE credential rejected (401) — falling back to captured cookie")
                } catch {
                    await handleRefreshError(error)
                    return
                }
            }
        }

        // Chain step 2: captured cookie (pre-#54 behavior).
        guard let cookieHeader = cachedCookieHeader else {
            // Chain exhausted. "Session expired" (.loginRequired) is reserved
            // for sessions that actually worked before — the optimistic
            // startSession() makes this guard reachable on a first-ever
            // launch, which should read "Not connected" (.loggedOut). An
            // already-expired state must persist, not downgrade.
            if authState != .loginRequired {
                authState = activeAuthSource == nil ? .loggedOut : .loginRequired
            }
            activeAuthSource = nil
            return
        }
        do {
            try await runRefreshAttempt(cookieHeader: cookieHeader)
            authState = .loggedIn
            activeAuthSource = .browserLogin
        } catch APIError.unauthorized {
            activeAuthSource = nil
            await handleCapturedCookieExpiry()
        } catch {
            await handleRefreshError(error)
        }
    }

    /// One credential's full refresh batch (#54): fetch, decode, apply state,
    /// and success-path side effects. Throws instead of handling errors so the
    /// credential chain in refresh() can decide fallback vs terminal handling.
    private func runRefreshAttempt(cookieHeader: String) async throws {
        let apiClient = self.apiClient
        // `async let` (not unstructured `Task {}`) keeps the three calls
        // tied to refresh()'s cancellation lifecycle; `capture` turns each
        // outcome into a Result so the expiry check below can inspect ALL
        // failures before any single error aborts the refresh.
        async let summaryCapture = Self.capture { try await apiClient.fetchUsageSummary(cookieHeader: cookieHeader) }
        async let usageCapture = Self.capture { try await apiClient.fetchUsage(cookieHeader: cookieHeader) }
        async let userInfoCapture = Self.capture { try await apiClient.fetchUserInfo(cookieHeader: cookieHeader) }

        // Optimistic weekly fetch — runs in parallel with the primary batch
        // once a prior refresh established the account's weekly fetch shape
        // (cachedWeeklyMode). Saves one round-trip on every subsequent refresh.
        // First refresh after login/account-switch falls back to the sequential
        // path inside `refreshWeeklyChart`.
        let optimisticWeekly: Task<[DayUsage], Error>? =
            makeOptimisticWeeklyTask(cookieHeader: cookieHeader)

        // Optimistic hard-limit fetch — same prior-refresh teamId gating as
        // the weekly task. Runs in parallel once a teamId is cached.
        let optimisticHardLimit: Task<HardLimitResponse?, Never>? =
            makeOptimisticHardLimitTask(cookieHeader: cookieHeader)

        let userInfoRes = await userInfoCapture
        let summaryRes = await summaryCapture
        let usageRes = await usageCapture

        // Expiry check runs over ALL results before any decode failure can
        // abort the refresh — the 2026-07-03 incident: /api/auth/me decode
        // error masked usage-summary's 401 and the logout path never fired.
        if Self.hasUnauthorized([userInfoRes.failure, summaryRes.failure, usageRes.failure]) {
            throw APIError.unauthorized
        }

        let userInfo = try userInfoRes.get()
        let summary = try? summaryRes.get()
        let usage = try? usageRes.get()

        // The IDE credential can silently belong to a different account than
        // the previous refresh (#54) — reset per-account state BEFORE applying
        // the new account's data so no cross-account deltas or caches leak.
        // The optimistic tasks above captured the OLD account's cached
        // team/user ids before this check could run — on a switch their
        // results must be discarded, not merely the caches reset.
        let accountSwitched = resetIfAccountSwitched(newEmail: userInfo.email)
        if accountSwitched {
            optimisticWeekly?.cancel()
        }

        // Resolve per-seat limits for token-based enterprise plans (no `plan`
        // object). The monthly limit feeds the credit-style $used/$limit
        // display; the on-demand limit feeds the PERSONAL on-demand row
        // (replacing the misleading team-wide figure). Monthly limit uses the
        // optimistic hard-limit task (parallel); the on-demand limit is cached
        // for the session since team-spend is a heavier roster fetch. First
        // refresh resolves both synchronously so values appear immediately.
        var perUserMonthlyLimitDollars = accountSwitched
            ? nil
            : (await optimisticHardLimit?.value ?? nil)?.perUserMonthlyLimitDollars
        var perUserOnDemandLimitDollars = cachedOnDemandLimitDollars
        let isTokenBased = summary.map {
            $0.individualUsage?.plan == nil && $0.individualUsage?.overall != nil
        } ?? false
        if isTokenBased,
           perUserMonthlyLimitDollars == nil || perUserOnDemandLimitDollars == nil,
           let teamId = await resolveTeamId(cookieHeader: cookieHeader) {
            if perUserMonthlyLimitDollars == nil {
                perUserMonthlyLimitDollars = (try? await apiClient
                    .fetchHardLimit(cookieHeader: cookieHeader, teamId: teamId))?
                    .perUserMonthlyLimitDollars
            }
            if perUserOnDemandLimitDollars == nil,
               let member = await fetchMyTeamMember(
                   cookieHeader: cookieHeader, teamId: teamId, email: userInfo.email) {
                if cachedUserId == nil { cachedUserId = member.userId }
                perUserOnDemandLimitDollars = member.hardLimitOverrideDollars
                cachedOnDemandLimitDollars = perUserOnDemandLimitDollars
            }
        }

        let baseData: UsageDisplayData?
        if let summary {
            baseData = UsageDisplayData.from(
                summary: summary, usage: usage, userInfo: userInfo,
                perUserMonthlyLimitDollars: perUserMonthlyLimitDollars,
                perUserOnDemandLimitDollars: perUserOnDemandLimitDollars)
        } else if let usage {
            baseData = UsageDisplayData.from(usage: usage, userInfo: userInfo)
        } else {
            throw APIError.httpError(statusCode: 0)
        }

        if let base = baseData {
            // Rollover detection must precede the latch update: otherwise the
            // first refresh of a new cycle paints stale `isOnDemandActive = true`
            // from the previous cycle's latch, and only unlatches on the *next*
            // refresh (1-refresh display lag).
            if let newStart = base.cycleStartDate, newStart != previousCycleStart {
                if previousCycleStart != nil {
                    notificationManager.resetNotifications()
                    isOnDemandLatched = false
                    Log.info("Billing cycle rollover — reset notification dedup + on-demand latch")
                }
                previousCycleStart = newStart
            }

            // Latch update: once activated, stays active until cycle rollover
            // (handled in the rollover block above) or logout (resetPerAccountState).
            if !isOnDemandLatched && base.wouldActivateOnDemand {
                isOnDemandLatched = true
                notificationManager.resetNotifications()
                Log.info("On-demand mode latched ON — threshold notifications reset")
            }
            usageData = base.withOnDemandActive(isOnDemandLatched)
        }
        Log.info("Usage data refreshed")
        lastSuccessAt = Date()
        consecutiveFailureCount = 0
        notificationFailureCount = 0
        // #112: recovery clears any lingering "connection trouble" banner —
        // idempotent at the UNUserNotificationCenter layer, so unconditional.
        refreshFailingWithdrawer?()
        networkRetryTask?.cancel()
        networkRetryTask = nil

        // Periodic update re-check rides the refresh cycle (success path
        // only, so an offline stretch can't hammer GitHub) instead of
        // owning a timer — at most one API call per updateRecheckInterval.
        if devBuildCommit == nil,
           Self.shouldRecheckUpdate(lastCheck: lastUpdateCheckAt, now: Date()) {
            lastUpdateCheckAt = Date()
            Task {
                let result = await updateCheckRunner()
                await recordUpdateCheckResult(result, source: .automatic)
            }
        }

        // Compute jump delta against previous canonical value (skip on first refresh,
        // mode change, or non-positive delta).
        if let data = usageData {
            updateJumpState(from: data)
        }

        // Weekly chart: consume the optimistic task if we had one, otherwise
        // fall through to the sequential path that resolves teamId first.
        // The optimistic task was built from a cached shape BEFORE this
        // refresh's membershipType was known — if the plan changed underneath
        // it, its result is for the wrong shape and must be discarded (#110).
        let modeContradicted = Self.weeklyModeContradicts(
            cachedWeeklyMode, membershipType: usageData?.membershipType)
        if modeContradicted {
            Log.info("Weekly mode contradicts the reported membership — re-discovering")
            optimisticWeekly?.cancel()
            clearWeeklyDiscoveryCaches()
        }
        if let task = optimisticWeekly, !accountSwitched, !modeContradicted {
            let needsRediscovery = await applyOptimisticWeekly(task)
            if needsRediscovery, let data = usageData {
                await refreshWeeklyChart(cookieHeader: cookieHeader, data: data, userInfo: userInfo)
            }
        } else if let data = usageData {
            await refreshWeeklyChart(cookieHeader: cookieHeader, data: data, userInfo: userInfo)
        }

        // Check notification thresholds
        if let data = usageData {
            await notificationManager.checkAndNotify(
                percentUsed: data.percentUsed,
                warningThreshold: warningThreshold,
                criticalThreshold: criticalThreshold,
                enabled: notificationEnabled,
                mode: Self.notificationMode(for: data)
            )
        }
    }

    /// Terminal expiry handling for the captured-cookie credential (#76/#84).
    private func handleCapturedCookieExpiry() async {
        // Error level (not info): unified logging evicts info entries within
        // hours, and expiry timestamps must survive for interval analysis (#84).
        Log.error("Session expired, clearing keychain")
        let wasLoggedIn = (authState == .loggedIn)
        cachedCookieHeader = nil
        do {
            try keychainDeleteHandler()
        } catch {
            Log.error("Keychain delete failed: \(error.localizedDescription)")
        }
        authState = .loginRequired
        usageData = nil
        // Expired session has its own dedicated UI; stale must not leak
        // into the next login.
        consecutiveFailureCount = 0
        notificationFailureCount = 0
        // stopAutoRefresh() cancels the auto-refresh task this code may be
        // running inside — notify FIRST so the notification awaits don't run
        // in a cancelled task. Re-entrance meanwhile is blocked by isRefreshing.
        // Notify only on the loggedIn → loginRequired transition so a
        // manual refresh in the expired state can't re-fire the banner.
        if wasLoggedIn {
            recordSessionExpiry(at: Date())
            if let sessionExpiredNotifier {
                await sessionExpiredNotifier()
            } else {
                await notificationManager.notifySessionExpired()
            }
        }
        stopAutoRefresh()
    }

    /// Non-auth refresh failures: forbidden and network/decoding errors.
    private func handleRefreshError(_ error: Error) async {
        if case APIError.forbidden = error {
            errorMessage = "Access denied (subscription may be inactive)"
            await registerRefreshFailure()
            Log.error("API returned 403 Forbidden")
            return
        }
        await registerRefreshFailure()
        if usageData == nil {
            // URLSession failures are wrapped as `APIError.networkError(URLError)`
            // by the API client, so direct cast misses offline cases. Unwrap both
            // layers before deciding whether to schedule a background retry.
            let urlError: URLError? = {
                if let direct = error as? URLError { return direct }
                if case APIError.networkError(let underlying) = error {
                    return underlying as? URLError
                }
                return nil
            }()
            if urlError?.code == .notConnectedToInternet || urlError?.code == .networkConnectionLost {
                errorMessage = "Waiting for network..."
                scheduleNetworkRetry()
            } else {
                errorMessage = Self.fallbackErrorMessage(for: error)
            }
        }
        Log.error("Refresh failed: \(error.localizedDescription)")
    }

    // MARK: - Weekly chart refresh

    /// Max pages to walk before giving up. Safety cap — realistic 7-day volume
    /// is ~30 events for an active user, so even a 100-event/day burst stops
    /// well within 5 pages of size 100.
    private static let weeklyMaxPages = 5
    private static let weeklyPageSize = 100

    /// Returns an optimistic weekly task only when a prior refresh established
    /// the fetch shape for this account — otherwise the sequential path inside
    /// `refreshWeeklyChart` discovers it first.
    private func makeOptimisticWeeklyTask(
        cookieHeader: String
    ) -> Task<[DayUsage], Error>? {
        guard let mode = cachedWeeklyMode else { return nil }
        let apiClient = self.apiClient
        let pageSize = Self.weeklyPageSize
        let maxPages = Self.weeklyMaxPages
        let teamId: Int
        let userId: Int?
        switch mode {
        case let .enterprise(cachedTeam, cachedUser):
            teamId = cachedTeam
            userId = cachedUser
        case .personal:
            teamId = 0
            userId = nil
        }
        return Task {
            try await Self.collectWeeklyEvents(
                apiClient: apiClient,
                cookieHeader: cookieHeader,
                teamId: teamId,
                userId: userId,
                pageSize: pageSize,
                maxPages: maxPages
            ).sevenDayRolling(today: Date(), calendar: .current)
        }
    }

    /// Discovers and caches the active `teamId` (once per session). Returns nil
    /// on personal plans (teams fetch empty / non-200), which callers treat as
    /// non-enterprise. Shared by the hard-limit and weekly-chart paths.
    private func resolveTeamId(cookieHeader: String) async -> Int? {
        if cachedTeamId == nil {
            do {
                let teams = try await apiClient.fetchTeams(cookieHeader: cookieHeader)
                cachedTeamId = teams.teams.first?.id
            } catch {
                Log.info("Teams fetch failed (treating as non-enterprise): \(error.localizedDescription)")
            }
        }
        return cachedTeamId
    }

    /// Fetches the team-spend roster and returns the current user's row (matched
    /// by email). Source of the numeric userId and the per-seat on-demand limit.
    /// Returns nil on missing email or fetch failure.
    private func fetchMyTeamMember(
        cookieHeader: String, teamId: Int, email: String?
    ) async -> TeamMember? {
        guard let email, !email.isEmpty else {
            Log.info("Skipping team-spend lookup: userInfo email missing or empty")
            return nil
        }
        do {
            let spend = try await apiClient.fetchTeamSpend(cookieHeader: cookieHeader, teamId: teamId)
            let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return spend.teamMemberSpend.first {
                ($0.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) == normalized
            }
        } catch {
            Log.info("Team-spend fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Fires the hard-limit fetch in parallel when a teamId was cached by a
    /// prior refresh. Returns nil on the first refresh (no teamId yet) or on any
    /// fetch error — callers treat a nil result as "no member-visible limit".
    private func makeOptimisticHardLimitTask(
        cookieHeader: String
    ) -> Task<HardLimitResponse?, Never>? {
        guard let teamId = cachedTeamId else { return nil }
        let apiClient = self.apiClient
        return Task {
            try? await apiClient.fetchHardLimit(cookieHeader: cookieHeader, teamId: teamId)
        }
    }

    /// Walks pages newest-first, stopping once a page contains events older
    /// than the 7-day cutoff. Returns the flattened event list (caller folds
    /// via `sevenDayRolling`).
    nonisolated static func collectWeeklyEvents(
        apiClient: CursorAPIClient,
        cookieHeader: String,
        teamId: Int,
        userId: Int?,
        pageSize: Int,
        maxPages: Int,
        today: Date = Date(),
        calendar: Calendar = .current
    ) async throws -> [UsageEvent] {
        let cutoff = calendar.date(
            byAdding: .day,
            value: -6,
            to: calendar.startOfDay(for: today)
        )!
        var collected: [UsageEvent] = []
        for page in 1...maxPages {
            let response = try await apiClient.fetchWeeklyUsage(
                cookieHeader: cookieHeader,
                teamId: teamId,
                userId: userId,
                page: page,
                pageSize: pageSize
            )
            let events = response.usageEventsDisplay
            collected.append(contentsOf: events)
            if events.isEmpty { break }
            guard let oldest = events.oldestEventDate() else { break }
            if oldest < cutoff { break }
        }
        return collected
    }

    /// True when a cached fetch shape contradicts the membership the server
    /// just reported — a personal cache on an account that is now enterprise,
    /// or vice versa (#110). A nil membershipType means usage-summary failed
    /// and says nothing about the plan, so it never counts as a contradiction
    /// (#103).
    nonisolated static func weeklyModeContradicts(
        _ mode: WeeklyMode?, membershipType: String?
    ) -> Bool {
        guard let mode, let membership = membershipType?.lowercased() else { return false }
        let isEnterprise = membership == "enterprise"
        switch mode {
        case .enterprise: return !isEnterprise
        case .personal:   return isEnterprise
        }
    }

    /// A 400/404 from the weekly endpoint means the request shape itself is
    /// wrong (stale team/user ids, or a plan that no longer accepts it) — the
    /// cached shape must go so the next refresh re-discovers. 5xx / network
    /// errors are transient and must NOT throw away a working cache (#110).
    nonisolated static func weeklyErrorInvalidatesShape(_ error: Error) -> Bool {
        if case APIError.httpError(let statusCode) = error {
            return statusCode == 400 || statusCode == 404
        }
        return false
    }

    private func clearWeeklyDiscoveryCaches() {
        cachedTeamId = nil
        cachedUserId = nil
        cachedOnDemandLimitDollars = nil
        cachedWeeklyMode = nil
    }

    /// Returns true when the caller should fall through to the sequential
    /// discovery path in this same refresh (the cached shape was rejected).
    private func applyOptimisticWeekly(_ task: Task<[DayUsage], Error>) async -> Bool {
        do {
            weeklyData = try await task.value
            weeklyChartAvailable = true
            return false
        } catch APIError.forbidden {
            Log.info("Optimistic weekly fetch returned 403 — clearing weekly caches")
            clearWeeklyDiscoveryCaches()
            weeklyChartAvailable = false
            weeklyData = nil
            return false
        } catch {
            if Self.weeklyErrorInvalidatesShape(error) {
                // Enterprise has team/user ids worth re-discovering; personal is
                // a fixed teamId-0 shape, so repeating it in the same refresh
                // would just re-send the rejected call (#110).
                let canRediscover = cachedWeeklyMode.map { mode in
                    if case .enterprise = mode { return true } else { return false }
                } ?? false
                clearWeeklyDiscoveryCaches()
                if canRediscover {
                    Log.info("Optimistic weekly fetch rejected the cached shape — re-discovering")
                    return true
                }
                Log.info("Weekly fetch rejected the request shape — hiding chart")
                weeklyChartAvailable = false
                weeklyData = nil
                return false
            }
            Log.info("Weekly fetch failed: \(error.localizedDescription)")
            if weeklyData == nil {
                weeklyChartAvailable = false
            }
            return false
        }
    }

    private func refreshWeeklyChart(
        cookieHeader: String,
        data: UsageDisplayData,
        userInfo: UserInfoResponse
    ) async {
        // nil membershipType = usage-summary failed (legacy fallback), which
        // says nothing about the plan — an enterprise account mid-outage must
        // not be routed to the personal teamId-0 path (#103 Codex review).
        guard let membership = data.membershipType?.lowercased() else {
            weeklyChartAvailable = false
            weeklyData = nil
            return
        }
        if membership == "enterprise" {
            await refreshWeeklyChartEnterprise(cookieHeader: cookieHeader, userInfo: userInfo)
        } else {
            await refreshWeeklyChartPersonal(cookieHeader: cookieHeader)
        }
    }

    private func refreshWeeklyChartEnterprise(
        cookieHeader: String,
        userInfo: UserInfoResponse
    ) async {
        guard let teamId = await resolveTeamId(cookieHeader: cookieHeader) else {
            weeklyChartAvailable = false
            weeklyData = nil
            return
        }

        // Discover numeric userId if absent. Matched by email against team-spend
        // roster (token-based refreshes may already have cached it).
        if cachedUserId == nil {
            cachedUserId = await fetchMyTeamMember(
                cookieHeader: cookieHeader, teamId: teamId, email: userInfo.email)?.userId
        }
        guard let userId = cachedUserId else {
            weeklyChartAvailable = false
            weeklyData = nil
            return
        }

        do {
            let events = try await Self.collectWeeklyEvents(
                apiClient: apiClient,
                cookieHeader: cookieHeader,
                teamId: teamId,
                userId: userId,
                pageSize: Self.weeklyPageSize,
                maxPages: Self.weeklyMaxPages
            )
            weeklyData = events.sevenDayRolling(today: Date(), calendar: .current)
            weeklyChartAvailable = true
            cachedWeeklyMode = .enterprise(teamId: teamId, userId: userId)
        } catch APIError.forbidden {
            Log.info("Weekly fetch returned 403 — clearing enterprise cache")
            clearWeeklyDiscoveryCaches()
            weeklyChartAvailable = false
            weeklyData = nil
        } catch {
            // 400/404 = the team/user shape is stale; drop it so the next
            // refresh re-discovers rather than repeating a doomed call (#110).
            if Self.weeklyErrorInvalidatesShape(error) {
                // Freshly discovered ids were rejected too — not a transient
                // blip, so stop showing a chart that can no longer be refreshed.
                Log.info("Weekly fetch rejected the enterprise shape — clearing cache and hiding chart")
                clearWeeklyDiscoveryCaches()
                weeklyChartAvailable = false
                weeklyData = nil
            } else {
                Log.info("Weekly fetch failed: \(error.localizedDescription)")
                if weeklyData == nil {
                    weeklyChartAvailable = false
                }
            }
        }
    }

    /// Personal accounts: the events endpoint accepts teamId 0 with no userId
    /// and scopes to the session cookie (verified live 2026-07-24, free plan).
    /// No team/roster discovery — two fewer round-trips than enterprise.
    private func refreshWeeklyChartPersonal(cookieHeader: String) async {
        do {
            let events = try await Self.collectWeeklyEvents(
                apiClient: apiClient,
                cookieHeader: cookieHeader,
                teamId: 0,
                userId: nil,
                pageSize: Self.weeklyPageSize,
                maxPages: Self.weeklyMaxPages
            )
            weeklyData = events.sevenDayRolling(today: Date(), calendar: .current)
            weeklyChartAvailable = true
            cachedWeeklyMode = .personal
        } catch APIError.forbidden {
            Log.info("Personal weekly fetch returned 403 — hiding chart")
            cachedWeeklyMode = nil
            weeklyChartAvailable = false
            weeklyData = nil
        } catch {
            if Self.weeklyErrorInvalidatesShape(error) {
                Log.info("Personal weekly fetch rejected the request shape — hiding chart")
                cachedWeeklyMode = nil
                weeklyChartAvailable = false
                weeklyData = nil
            } else {
                Log.info("Personal weekly fetch failed: \(error.localizedDescription)")
                if weeklyData == nil {
                    weeklyChartAvailable = false
                }
            }
        }
    }

    /// Trailing-edge debounce + shared min-interval guard (defer semantics).
    func noteActivity() {
        guard activityRefreshEnabled else { return }
        activityDebounceTask?.cancel()
        let generation = activityGeneration
        activityDebounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: self.activityDebounceInterval)
            guard !Task.isCancelled, generation == self.activityGeneration else { return }
            // Recompute the guard window after every sleep: an interleaved
            // refresh (timer/manual/retry) can re-stamp lastRefreshAttempt while
            // this task sleeps, opening a fresh min-interval window the deferred
            // fire must respect — otherwise the "at most 1 refresh/min" ceiling
            // breaks. Keep sleeping while a positive remainder persists.
            while let last = self.lastRefreshAttempt {
                let remaining = self.activityMinRefreshInterval - last.duration(to: ContinuousClock.now)
                guard remaining > .zero else { break }
                try? await Task.sleep(for: remaining)
                guard !Task.isCancelled, generation == self.activityGeneration else { return }
            }
            self.activityDebounceTask = nil
            await self.refresh()
        }
    }

    func logout() {
        // Stop the sign-in watch and invalidate pending provider reads AND
        // any in-flight launch completion — a late result must not reconnect
        // against the user's intent (#88).
        ideSignInWatchTask?.cancel()
        ideSignInWatchTask = nil
        ideProbeGeneration += 1
        ideWatchGeneration += 1
        // Suppress the IDE source, or logout would silently resurrect on the
        // next refresh (#54).
        ideAuthSuppressed = true
        UserDefaults.standard.set(true, for: .ideAuthSuppressed)
        activeAuthSource = nil
        lastAccountEmail = nil
        cachedCookieHeader = nil
        do {
            // Through the seam (#82) — tests calling logout() must not touch
            // the real Keychain; production default is KeychainStore.
            try keychainDeleteHandler()
        } catch {
            Log.error("Keychain delete failed: \(error.localizedDescription)")
        }
        authState = .loggedOut
        usageData = nil
        errorMessage = nil
        weeklyData = nil
        weeklyChartAvailable = false
        cachedTeamId = nil
        cachedUserId = nil
        cachedOnDemandLimitDollars = nil
        cachedWeeklyMode = nil
        previousCycleStart = nil
        isOnDemandLatched = false
        // Jump baselines must clear on logout so the next account's first
        // refresh doesn't compute a phantom delta against the previous user's
        // values. (resetPerAccountState catches this on re-login, but symmetry
        // here also covers any post-logout refresh path that bypasses login.)
        previousPlanUsedCents = nil
        previousRequestsUsed = nil
        previousServerPercent = nil
        previousOnDemandUsedCents = nil
        previousMode = nil
        lastJump = nil
        // Cancel any pending offline retry so it can't fire ~60s after logout
        // and clobber the cleared auth state with a 401.
        networkRetryTask?.cancel()
        networkRetryTask = nil
        stopAutoRefresh()
        notificationManager.resetNotifications()
        Log.info("Logged out")
    }

    // MARK: - Settings Setters

    func setRefreshInterval(_ interval: RefreshInterval) {
        refreshInterval = interval
        UserDefaults.standard.set(interval.rawValue, for: .refreshInterval)
        if authState == .loggedIn {
            startAutoRefresh()
        }
    }

    func setNotificationEnabled(_ enabled: Bool) {
        notificationEnabled = enabled
        UserDefaults.standard.set(enabled, for: .notificationEnabled)
    }

    func setBrowserLoginEnabled(_ enabled: Bool) {
        browserLoginEnabled = enabled
        UserDefaults.standard.set(enabled, for: .browserLoginEnabled)
    }

    func setWarningThreshold(_ value: Int) {
        warningThreshold = value
        UserDefaults.standard.set(value, for: .warningThreshold)
    }

    func setCriticalThreshold(_ value: Int) {
        criticalThreshold = value
        UserDefaults.standard.set(value, for: .criticalThreshold)
    }

    func setMenuBarDisplayMode(_ mode: Int) {
        menuBarDisplayMode = mode
        UserDefaults.standard.set(mode, for: .menuBarDisplayMode)
    }

    func setAppStatusNotificationEnabled(_ enabled: Bool) {
        appStatusNotificationEnabled = enabled
        UserDefaults.standard.set(enabled, for: .appStatusNotificationEnabled)
    }

    func setJumpEffectEnabled(_ enabled: Bool) {
        jumpEffectEnabled = enabled
        UserDefaults.standard.set(enabled, for: .jumpEffectEnabled)
    }

    func setJumpIntensity(_ intensity: JumpIntensity) {
        jumpIntensity = intensity
        UserDefaults.standard.set(intensity.rawValue, for: .jumpIntensity)
    }

    func setJumpGlyphStyle(_ style: JumpGlyphStyle) {
        jumpGlyphStyle = style
        UserDefaults.standard.set(style.rawValue, for: .jumpGlyphStyle)
    }

    func setWeeklyChartEnabled(_ enabled: Bool) {
        weeklyChartEnabled = enabled
        UserDefaults.standard.set(enabled, for: .weeklyChartEnabled)
    }

    func setWeeklyChartStyle(_ style: WeeklyChartStyle) {
        weeklyChartStyle = style
        UserDefaults.standard.set(style.rawValue, for: .weeklyChartStyle)
    }

    func setActivityRefreshEnabled(_ enabled: Bool) {
        activityRefreshEnabled = enabled
        UserDefaults.standard.set(enabled, for: .activityRefreshEnabled)
        if !enabled {
            activityGeneration += 1
            activityDebounceTask?.cancel()
            activityDebounceTask = nil
        }
    }

    func checkForUpdate() async {
        guard devBuildCommit == nil else { return }
        isCheckingUpdate = true
        lastUpdateCheckAt = Date()
        async let result = updateCheckRunner()
        let start = ContinuousClock.now
        await recordUpdateCheckResult(await result, source: .manual)
        let elapsed = ContinuousClock.now - start
        if elapsed < .milliseconds(1200) {
            try? await Task.sleep(for: .milliseconds(1200) - elapsed)
        }
        isCheckingUpdate = false
    }

    /// Single recording point for update-check results (#83). Assigns
    /// `lastUpdateCheckResult` and, for automatic sources only, fires the
    /// release notification with write-before-send dedup: the version is
    /// persisted before dispatch so overlapping check paths can't double-fire.
    func recordUpdateCheckResult(_ result: UpdateCheckResult, source: UpdateCheckSource) async {
        lastUpdateCheckResult = result
        guard source == .automatic, case .available(let release) = result,
              let updateAvailableNotifier
        else { return }
        let defaults = UserDefaults.standard
        guard Self.shouldNotifyUpdate(
            version: release.version,
            lastNotified: defaults.object(for: .lastNotifiedUpdateVersion) as? String,
            enabled: appStatusNotificationEnabled
        ) else { return }
        // A version counts as "notified" only when a dispatch is actually
        // attempted (notifier wired) — but the write still precedes the await
        // so overlapping check paths can't double-fire.
        defaults.set(release.version, for: .lastNotifiedUpdateVersion)
        await updateAvailableNotifier(release.version, release.htmlURL)
    }

    /// Appends an expiry detection timestamp to the audited UserDefaults
    /// history (#84) so "is the cookie expiring faster?" is answerable weeks
    /// later, independent of unified-log retention. Read via:
    /// `defaults read com.woojin.CursorMeter sessionExpiryHistory`.
    private func recordSessionExpiry(at date: Date) {
        let defaults = UserDefaults.standard
        let history = (defaults.object(for: .sessionExpiryHistory) as? [Date]) ?? []
        let updated = Self.cappedExpiryHistory(history, appending: date)
        defaults.set(updated, for: .sessionExpiryHistory)
        Log.error("Session expiry recorded (#84) — total \(updated.count) entries")
    }

    /// Registers a non-auth refresh failure (#112): every failure drives the
    /// stale indicator, but only display-awake failures advance the
    /// notification counter — a nil checker (test host without an explicit
    /// override) counts as awake.
    private func registerRefreshFailure() async {
        consecutiveFailureCount += 1
        if displayAsleepChecker?() != true {
            notificationFailureCount += 1
            await maybeNotifyRefreshFailing()
        }
    }

    /// Fires the refresh-failing notification on the 4→5 transition of the
    /// awake-only counter (#112). The unauthorized path never reaches this
    /// (it resets the counters and routes to the session-expired
    /// notification, #76).
    private func maybeNotifyRefreshFailing() async {
        guard Self.shouldNotifyRefreshFailing(
            failureCount: notificationFailureCount,
            enabled: appStatusNotificationEnabled
        ), let refreshFailingNotifier else { return }
        await refreshFailingNotifier()
    }

    // MARK: - Private

    private func loadSettings() {
        let defaults = UserDefaults.standard
        if let raw = defaults.object(for: .refreshInterval) as? Int,
           let interval = RefreshInterval(rawValue: raw)
        {
            refreshInterval = interval
        }
        if let val = defaults.object(for: .notificationEnabled) as? Bool {
            notificationEnabled = val
        }
        if let val = defaults.object(for: .warningThreshold) as? Int {
            warningThreshold = min(val, 90)
        }
        if let val = defaults.object(for: .criticalThreshold) as? Int {
            criticalThreshold = max(min(val, 100), warningThreshold + 5)
        }
        if let val = defaults.object(for: .menuBarDisplayMode) as? Int {
            menuBarDisplayMode = val
        } else {
            // Migrate from old boolean settings
            let hadText = defaults.object(for: .legacyShowMenuBarText) as? Bool ?? false
            let hadPercent = defaults.object(for: .legacyShowMenuBarPercent) as? Bool ?? false
            if hadText && hadPercent {
                menuBarDisplayMode = 2
            } else if hadText {
                menuBarDisplayMode = 1
            }
        }
        if let val = defaults.object(for: .appStatusNotificationEnabled) as? Bool {
            appStatusNotificationEnabled = val
        }
        if let val = defaults.object(for: .ideAuthSuppressed) as? Bool {
            ideAuthSuppressed = val
        }
        if let val = defaults.object(for: .jumpEffectEnabled) as? Bool {
            jumpEffectEnabled = val
        }
        if let raw = defaults.object(for: .jumpIntensity) as? Int,
           let intensity = JumpIntensity(rawValue: raw)
        {
            jumpIntensity = intensity
        }
        if let raw = defaults.object(for: .jumpGlyphStyle) as? Int,
           let style = JumpGlyphStyle(rawValue: raw)
        {
            jumpGlyphStyle = style
        }
        if let val = defaults.object(for: .weeklyChartEnabled) as? Bool {
            weeklyChartEnabled = val
        }
        if let raw = defaults.object(for: .weeklyChartStyle) as? Int,
           let style = WeeklyChartStyle(rawValue: raw)
        {
            weeklyChartStyle = style
        }
        if let val = defaults.object(for: .browserLoginEnabled) as? Bool {
            browserLoginEnabled = val
        }
        if let enabled = defaults.object(for: .activityRefreshEnabled) as? Bool {
            activityRefreshEnabled = enabled
        }
    }

    /// Update re-check cadence for long-running instances. Menu bar apps run
    /// for weeks without a relaunch, so the launch-time check alone never
    /// sees new releases (#80).
    nonisolated static let updateRecheckInterval: TimeInterval = 86_400

    /// Pure gate for the periodic update re-check: true when no check has
    /// happened yet, the last one is older than `interval`, or the clock has
    /// gone backwards (a rolled-back wall clock would otherwise suppress
    /// checks until it catches up past the stale timestamp).
    nonisolated static func shouldRecheckUpdate(
        lastCheck: Date?,
        now: Date,
        interval: TimeInterval = updateRecheckInterval
    ) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) > interval || now < lastCheck
    }

    /// True when any captured refresh failure is `.unauthorized`. Session
    /// expiry may surface on ANY of the three endpoints (all unofficial, all
    /// respond differently to an invalid cookie), so the 401 check must run
    /// over every result before a decode error from one endpoint can abort
    /// the refresh (#76).
    nonisolated static func hasUnauthorized(_ errors: [Error?]) -> Bool {
        errors.contains { error in
            guard let apiError = error as? APIError else { return false }
            if case .unauthorized = apiError { return true }
            return false
        }
    }

    /// Runs `body` and captures its outcome as a Result. Used with `async let`
    /// so the three primary refresh calls stay structured — cancelled together
    /// with refresh() — while still letting the caller inspect every failure
    /// instead of aborting on the first thrown error (#76).
    nonisolated private static func capture<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async -> Result<T, Error> {
        do { return .success(try await body()) } catch { return .failure(error) }
    }

    /// Maps an error to a user-facing message for the fallback (non-network-down, non-auth) error path.
    /// Avoid surfacing raw `localizedDescription` to UI: it can leak request URLs or other diagnostic
    /// detail picked up by crash reporters that auto-capture user-visible state.
    nonisolated static func fallbackErrorMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            return urlError.code == .timedOut ? "Request timed out" : "Network error"
        }
        if error is DecodingError {
            return "Failed to read usage data"
        }
        if case APIError.httpError(let code) = error {
            return "Server error (\(code))"
        }
        if case APIError.networkError(let underlying) = error {
            if let urlError = underlying as? URLError {
                return urlError.code == .timedOut ? "Request timed out" : "Network error"
            }
            return "Network error"
        }
        return "Unexpected error"
    }

    // MARK: - Jump Detection

    /// Computes delta between this refresh and the previous canonical value, classifies
    /// tier, and updates `lastJump`. Skip conditions (no event, only previous reset):
    ///   - first refresh (no baseline)
    ///   - display mode changed (unit mismatch)
    ///   - delta ≤ 0
    /// Effective menu-bar text mode. Percent-only plans have no ratio
    /// denominator, so Ratio (1) coerces to Percent (2) — but None (0) is the
    /// user saying "no text" and must pass through (#105; the original #48 gate
    /// respected it, the #49 dropdown migration regressed it). Shared by the
    /// status-item renderer and the Settings popup so both show the same truth.
    nonisolated static func resolvedMenuBarDisplayMode(isPercentOnly: Bool, setting: Int) -> Int {
        if isPercentOnly && setting == 1 { return 2 }
        return setting
    }

    // MARK: - Threshold Notifications

    /// Picks the threshold-notification mode for the refreshed display data.
    /// Pure so the percent-only branch (#104) is unit-testable: free plans have
    /// no usable used/limit pair and must not fall through to a "(0 / 0)"
    /// request-quota body.
    nonisolated static func notificationMode(for data: UsageDisplayData) -> NotificationMode {
        if data.isOnDemandActive {
            return .onDemand(
                usedCents: data.onDemandUsedCents ?? 0,
                limitCents: data.onDemandLimitCents ?? 0)
        }
        if data.isCreditBased {
            return .creditPlan(
                usedCents: data.planUsedCents ?? 0,
                limitCents: data.planLimitCents ?? 0)
        }
        if data.isPercentOnly {
            return .percentOnly
        }
        return .requestQuota(used: data.requestsUsed, limit: data.requestsLimit)
    }

    private func updateJumpState(from data: UsageDisplayData) {
        let mode: JumpEvent.Mode
        let current: Double
        if data.isOnDemandActive {
            mode = .onDemand
            current = Double(data.onDemandUsedCents ?? 0)
        } else if data.isPercentOnly {
            mode = .percent
            current = data.serverPercentUsed ?? 0
        } else if data.isCreditBased {
            mode = .credit
            current = Double(data.planUsedCents ?? 0)
        } else {
            mode = .request
            current = Double(data.requestsUsed)
        }

        let previous: Double? = {
            switch mode {
            case .credit:   return previousPlanUsedCents.map(Double.init)
            case .request:  return previousRequestsUsed.map(Double.init)
            case .percent:  return previousServerPercent
            case .onDemand: return previousOnDemandUsedCents.map(Double.init)
            }
        }()

        let modeChanged = previousMode != nil && previousMode != mode

        // Always update the baseline for the active mode.
        switch mode {
        case .credit:   previousPlanUsedCents = data.planUsedCents ?? 0
        case .request:  previousRequestsUsed = data.requestsUsed
        case .percent:  previousServerPercent = data.serverPercentUsed ?? 0
        case .onDemand: previousOnDemandUsedCents = data.onDemandUsedCents ?? 0
        }
        previousMode = mode

        guard let prev = previous, !modeChanged else {
            // First refresh in this mode: only set baseline.
            // Guard against `@Observable` firing on `nil → nil` every refresh.
            if lastJump != nil { lastJump = nil }
            return
        }

        let delta = current - prev
        guard delta > 0 else {
            if lastJump != nil { lastJump = nil }
            return
        }

        let limit: Double
        switch mode {
        case .credit:   limit = Double(data.planLimitCents ?? 0)
        case .request:  limit = Double(data.requestsLimit)
        case .percent:  limit = 100  // percent-only: deltas are already %-points
        case .onDemand: limit = Double(data.onDemandLimitCents ?? 0)
        }

        let event = Self.makeJumpEvent(
            mode: mode,
            delta: delta,
            limit: limit,
            timestamp: Date()
        )
        lastJump = event
    }

    /// Test-only entry point for `updateJumpState`. Not for production callers —
    /// the regular `refresh()` path is the only legitimate caller in app code.
    internal func testHook_updateJumpState(from data: UsageDisplayData) {
        updateJumpState(from: data)
    }

    /// Test-only entry to mirror `refresh()`'s latch + injection step.
    /// Not for production code — `refresh()` is the legitimate caller.
    internal func testHook_applyLatch(base: UsageDisplayData) {
        if !isOnDemandLatched && base.wouldActivateOnDemand {
            isOnDemandLatched = true
            notificationManager.resetNotifications()
        }
        usageData = base.withOnDemandActive(isOnDemandLatched)
    }

    /// Test-only entry that mirrors `refresh()`'s rollover detection followed by
    /// the latch update. Lets tests verify both transitions in sequence without
    /// driving the full refresh pipeline.
    internal func testHook_applyLatchAndRollover(base: UsageDisplayData) {
        if let newStart = base.cycleStartDate, newStart != previousCycleStart {
            if previousCycleStart != nil {
                notificationManager.resetNotifications()
                isOnDemandLatched = false
            }
            previousCycleStart = newStart
        }
        if !isOnDemandLatched && base.wouldActivateOnDemand {
            isOnDemandLatched = true
            notificationManager.resetNotifications()
        }
        usageData = base.withOnDemandActive(isOnDemandLatched)
    }

    /// Read accessor for the latched-threshold dedup set (for test assertions).
    internal func testHook_notifiedThresholds() -> Set<Int> {
        notificationManager.notifiedThresholds
    }

    /// Seed the threshold dedup set so tests can simulate post-notification state.
    internal func testHook_setNotifiedThresholds(_ set: Set<Int>) {
        notificationManager.testHook_seed(set)
    }

    /// Test-only — seeds the in-memory cookie so refresh() proceeds past the
    /// auth guard without touching the Keychain.
    /// Test-only — seeds the periodic-recheck clock so DevBuildGateTests can
    /// force the recheck window open without waiting out the real interval.
    internal func testHook_setLastUpdateCheckAt(_ date: Date?) {
        lastUpdateCheckAt = date
    }

    internal func testHook_setCookieHeader(_ header: String) {
        cachedCookieHeader = header
    }

    /// Test-only — seeds weekly data so account-switch reset is observable.
    internal func testHook_seedWeeklyData(_ data: [DayUsage]) {
        weeklyData = data
    }

    /// Test-only — cancels the auto-refresh loop that connectViaIDE/startSession
    /// spins up, so tests can drive refresh() deterministically.
    internal func stopAutoRefreshForTests() {
        stopAutoRefresh()
    }

    /// Builds a `JumpEvent` from raw delta/limit. Pure function — exposed for testing.
    /// Classification is the OR of percent-of-limit (5/15%) and per-mode absolute
    /// thresholds; `limit ≤ 0` falls back to absolute-only.
    nonisolated static func makeJumpEvent(
        mode: JumpEvent.Mode,
        delta: Double,
        limit: Double,
        timestamp: Date = Date()
    ) -> JumpEvent {
        let tier = classifyTier(mode: mode, delta: delta, limit: limit)
        let deltaPct: Double = limit > 0 ? (delta / limit * 100.0) : 0
        return JumpEvent(
            tier: tier,
            deltaCanonical: delta,
            deltaPct: deltaPct,
            mode: mode,
            displayDelta: formatJumpDelta(delta, mode: mode),
            timestamp: timestamp
        )
    }

    /// Per-mode absolute thresholds in canonical units. A delta meeting either the
    /// percent-of-limit or the absolute threshold is enough to escalate a tier.
    /// Rationale: a single Max-mode query is roughly +0.30 USD or +15 requests
    /// regardless of plan size, so absolute thresholds keep large-plan users from
    /// silently missing those jumps.
    private nonisolated static func absoluteThresholds(
        for mode: JumpEvent.Mode
    ) -> (t1: Double, t2: Double) {
        switch mode {
        case .credit:   return (5, 30)   // cents — $0.05 / $0.30
        case .onDemand: return (5, 30)   // cents — same scale as credit
        case .request:  return (5, 15)   // request count
        case .percent:  return (5, 15)   // %-points (mirrors percent-of-limit)
        }
    }

    /// Tier classification. Tier is the OR of percent-of-limit (5/15%) and per-mode
    /// absolute thresholds. When `limit ≤ 0` only the absolute thresholds apply.
    nonisolated static func classifyTier(
        mode: JumpEvent.Mode,
        delta: Double,
        limit: Double
    ) -> JumpEvent.Tier {
        guard delta > 0 else { return .zero }

        let (t1Abs, t2Abs) = absoluteThresholds(for: mode)

        if limit > 0 {
            let pct = delta / limit * 100.0
            if pct >= 15 || delta >= t2Abs { return .two }
            if pct >= 5  || delta >= t1Abs { return .one }
            return .zero
        }

        // Fallback when plan_limit ≤ 0 (unlimited / unknown) — absolute only.
        if delta >= t2Abs { return .two }
        if delta >= t1Abs { return .one }
        return .zero
    }

    /// Formats a positive delta as a signed user-facing string for the active display mode.
    nonisolated static func formatJumpDelta(_ delta: Double, mode: JumpEvent.Mode) -> String {
        switch mode {
        case .credit, .onDemand:
            return String(format: "+$%.2f", delta / 100.0)
        case .request:
            return "+\(Int(delta.rounded()))"
        case .percent:
            return String(format: "+%.1f%%", delta)
        }
    }

    private var networkRetryTask: Task<Void, Never>?

    private func scheduleNetworkRetry() {
        guard networkRetryTask == nil else { return }
        networkRetryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self, !Task.isCancelled else { return }
            self.networkRetryTask = nil
            await self.refresh()
        }
    }

    private func startAutoRefresh() {
        stopAutoRefresh()
        refreshTask = Task { [weak self] in
            while let self {
                do {
                    try await Task.sleep(for: .seconds(self.refreshInterval.rawValue))
                } catch { return }
                await self.refresh()
            }
        }
    }

    private func stopAutoRefresh() {
        refreshTask?.cancel()
        refreshTask = nil
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
