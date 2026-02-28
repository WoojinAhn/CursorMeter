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
    var authState: AuthState = .loggedOut
    var usageData: UsageDisplayData?
    var errorMessage: String?
    var isLoading = false
    private var isRefreshing = false
    var refreshInterval: RefreshInterval = .fiveMinutes

    private let apiClient = CursorAPIClient()
    private var refreshTask: Task<Void, Never>?
    private var cachedCookieHeader: String?

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
            async let usageResult = apiClient.fetchUsage(cookieHeader: cookieHeader)
            async let userInfoResult = apiClient.fetchUserInfo(cookieHeader: cookieHeader)

            let usage = try await usageResult
            let userInfo = try await userInfoResult

            usageData = UsageDisplayData.from(usage: usage, userInfo: userInfo)
            Log.info("Usage data refreshed")
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
            errorMessage = error.localizedDescription
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
        Log.info("Logged out")
    }

    func setRefreshInterval(_ interval: RefreshInterval) {
        refreshInterval = interval
        if authState == .loggedIn {
            startAutoRefresh()
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
