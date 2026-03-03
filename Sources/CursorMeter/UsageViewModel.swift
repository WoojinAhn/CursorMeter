import Foundation
import SwiftUI

enum AuthState {
    case loggedOut
    case loggedIn
    case loginRequired
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

@Observable
@MainActor
final class UsageViewModel {
    // MARK: - Auth & Data

    var authState: AuthState = .loggedOut
    var usageData: UsageDisplayData?
    var errorMessage: String?
    var isLoading = false
    var availableUpdate: UpdateChecker.Release?
    var isCheckingUpdate = false

    // MARK: - Settings

    var refreshInterval: RefreshInterval = .fiveMinutes
    var notificationEnabled: Bool = true
    var warningThreshold: Int = 80
    var criticalThreshold: Int = 90
    var showMenuBarText: Bool = false

    // MARK: - Private

    private var isRefreshing = false
    private let apiClient = CursorAPIClient()
    private var refreshTask: Task<Void, Never>?
    private var cachedCookieHeader: String?
    private let notificationManager = NotificationManager()

    // MARK: - Init

    init() {
        loadSettings()
        Task { availableUpdate = await UpdateChecker.shared.check() }
    }

    // MARK: - Session

    func checkExistingSession() {
        do {
            if let header = try KeychainStore.loadCookieHeader() {
                cachedCookieHeader = header
                startSession()
            }
        } catch {
            Log.error("Failed to load keychain: \(error)")
        }
    }

    func onLoginSuccess(cookieHeader: String) {
        cachedCookieHeader = cookieHeader
        do {
            try KeychainStore.saveCookieHeader(cookieHeader)
            Log.info("Cookie header saved to Keychain")
        } catch {
            Log.error("Failed to save cookie: \(error)")
        }
        startSession()
    }

    private func startSession() {
        authState = .loggedIn
        Task { await refresh() }
        startAutoRefresh()
    }

    func refresh() async {
        guard !isRefreshing else { return }
        guard let cookieHeader = cachedCookieHeader else {
            authState = .loginRequired
            return
        }

        isRefreshing = true
        isLoading = true
        errorMessage = nil

        do {
            async let summaryResult = apiClient.fetchUsageSummary(cookieHeader: cookieHeader)
            async let usageResult = apiClient.fetchUsage(cookieHeader: cookieHeader)
            async let userInfoResult = apiClient.fetchUserInfo(cookieHeader: cookieHeader)

            let userInfo = try await userInfoResult

            let summary = try? await summaryResult
            let usage = try? await usageResult

            if let summary {
                usageData = UsageDisplayData.from(summary: summary, usage: usage, userInfo: userInfo)
            } else if let usage {
                usageData = UsageDisplayData.from(usage: usage, userInfo: userInfo)
            } else {
                throw APIError.httpError(statusCode: 0)
            }
            Log.info("Usage data refreshed")

            // Check notification thresholds
            if let data = usageData {
                await notificationManager.checkAndNotify(
                    percentUsed: data.percentUsed,
                    warningThreshold: warningThreshold,
                    criticalThreshold: criticalThreshold,
                    enabled: notificationEnabled
                )
            }
        } catch APIError.unauthorized {
            Log.info("Session expired, clearing keychain")
            cachedCookieHeader = nil
            try? KeychainStore.deleteCookieHeader()
            authState = .loginRequired
            usageData = nil
            stopAutoRefresh()
        } catch APIError.forbidden {
            errorMessage = "Access denied (subscription may be inactive)"
            Log.error("API returned 403 Forbidden")
        } catch {
            if usageData == nil {
                errorMessage = error.localizedDescription
            }
            Log.error("Refresh failed: \(error)")
        }

        isLoading = false
        isRefreshing = false
    }

    func logout() {
        cachedCookieHeader = nil
        try? KeychainStore.deleteCookieHeader()
        authState = .loggedOut
        usageData = nil
        errorMessage = nil
        stopAutoRefresh()
        notificationManager.resetNotifications()
        Log.info("Logged out")
    }

    // MARK: - Settings Setters

    func setRefreshInterval(_ interval: RefreshInterval) {
        refreshInterval = interval
        UserDefaults.standard.set(interval.rawValue, forKey: "refreshIntervalSeconds")
        if authState == .loggedIn {
            startAutoRefresh()
        }
    }

    func setNotificationEnabled(_ enabled: Bool) {
        notificationEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "notificationEnabled")
    }

    func setWarningThreshold(_ value: Int) {
        warningThreshold = value
        UserDefaults.standard.set(value, forKey: "warningThreshold")
    }

    func setCriticalThreshold(_ value: Int) {
        criticalThreshold = value
        UserDefaults.standard.set(value, forKey: "criticalThreshold")
    }

    func setShowMenuBarText(_ show: Bool) {
        showMenuBarText = show
        UserDefaults.standard.set(show, forKey: "showMenuBarText")
    }

    func checkForUpdate() async {
        isCheckingUpdate = true
        async let result = UpdateChecker.shared.check()
        let start = ContinuousClock.now
        availableUpdate = await result
        let elapsed = ContinuousClock.now - start
        if elapsed < .milliseconds(1200) {
            try? await Task.sleep(for: .milliseconds(1200) - elapsed)
        }
        isCheckingUpdate = false
    }

    // MARK: - Private

    private func loadSettings() {
        let defaults = UserDefaults.standard
        if let raw = defaults.object(forKey: "refreshIntervalSeconds") as? Int,
           let interval = RefreshInterval(rawValue: raw)
        {
            refreshInterval = interval
        }
        if let val = defaults.object(forKey: "notificationEnabled") as? Bool {
            notificationEnabled = val
        }
        if let val = defaults.object(forKey: "warningThreshold") as? Int {
            warningThreshold = min(val, 90)
        }
        if let val = defaults.object(forKey: "criticalThreshold") as? Int {
            criticalThreshold = max(min(val, 100), warningThreshold + 5)
        }
        if let val = defaults.object(forKey: "showMenuBarText") as? Bool {
            showMenuBarText = val
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
