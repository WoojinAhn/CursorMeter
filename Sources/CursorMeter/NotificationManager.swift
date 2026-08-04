@preconcurrency import UserNotifications

// MARK: - Threshold Evaluation

enum ThresholdLevel: Sendable, Equatable {
    case none
    case warning
    case critical
}

// MARK: - Notification Mode

enum NotificationMode: Sendable, Equatable {
    case requestQuota(used: Int, limit: Int)
    case creditPlan(usedCents: Int, limitCents: Int)
    case onDemand(usedCents: Int, limitCents: Int)
    /// Percent-only plans (e.g. free): the API exposes no usable used/limit
    /// pair, so the body carries no fraction — a "(0 / 0)" suffix would be
    /// meaningless (#104).
    case percentOnly
}

extension NotificationMode {
    static func formatUSD(_ cents: Int) -> String {
        String(format: "$%.2f", Double(cents) / 100.0)
    }

    func body(forPercent percent: Int) -> String {
        switch self {
        case let .requestQuota(used, limit):
            return "월 요청 한도의 \(percent)%를 초과했습니다 (\(used) / \(limit))"
        case let .creditPlan(used, limit):
            return "월 플랜의 \(percent)%를 사용했습니다 (\(Self.formatUSD(used)) / \(Self.formatUSD(limit)))"
        case let .onDemand(used, limit):
            return "On-demand 청구의 \(percent)%를 사용했습니다 (\(Self.formatUSD(used)) / \(Self.formatUSD(limit)))"
        case .percentOnly:
            return "월 플랜의 \(percent)%를 사용했습니다"
        }
    }

    var titleSuffix: String {
        switch self {
        case .requestQuota: return "Request Quota"
        case .creditPlan:   return "Plan"
        case .onDemand:     return "On-demand"
        case .percentOnly:  return "Plan"
        }
    }
}

// MARK: - Notification Click Action

/// What the app should do when the user clicks a delivered notification.
enum NotificationClickAction: Sendable, Equatable {
    case openLoginWindow
    case openReleaseURL(URL)
    case openPopover
    case none
}

// MARK: - Notification Manager

@MainActor
final class NotificationManager {
    private(set) var notifiedThresholds: Set<Int> = []

    nonisolated static func evaluateThreshold(
        percentUsed: Double,
        warningThreshold: Int,
        criticalThreshold: Int,
        notifiedThresholds: Set<Int>
    ) -> ThresholdLevel {
        if percentUsed >= Double(criticalThreshold)
            && !notifiedThresholds.contains(criticalThreshold)
        {
            return .critical
        }
        if percentUsed >= Double(warningThreshold)
            && !notifiedThresholds.contains(warningThreshold)
        {
            return .warning
        }
        return .none
    }

    func checkAndNotify(
        percentUsed: Double,
        warningThreshold: Int,
        criticalThreshold: Int,
        enabled: Bool,
        mode: NotificationMode
    ) async {
        guard enabled else { return }

        let level = Self.evaluateThreshold(
            percentUsed: percentUsed,
            warningThreshold: warningThreshold,
            criticalThreshold: criticalThreshold,
            notifiedThresholds: notifiedThresholds
        )

        switch level {
        case .none:
            break
        case .warning:
            await sendNotification(
                title: "Cursor \(mode.titleSuffix) Warning",
                body: mode.body(forPercent: warningThreshold)
            )
            notifiedThresholds.insert(warningThreshold)
        case .critical:
            await sendNotification(
                title: "Cursor \(mode.titleSuffix) Critical",
                body: mode.body(forPercent: criticalThreshold)
            )
            notifiedThresholds.insert(criticalThreshold)
        }
    }

    func resetNotifications() {
        notifiedThresholds.removeAll()
    }

    /// Test-only — overwrites the dedup set so oscillation/rollover tests can
    /// simulate post-notification state.
    internal func testHook_seed(_ set: Set<Int>) {
        notifiedThresholds = set
    }

    // MARK: - Usage Jump Notification

    /// Identifier prefix used for usage-jump notification requests, kept distinct
    /// from threshold notifications so callers/tests can disambiguate.
    nonisolated static let usageJumpIdentifierPrefix = "usage-jump"

    /// Formats the body string for a usage-jump notification. Pure function so the
    /// exact wording can be unit-tested without invoking UNUserNotificationCenter.
    nonisolated static func makeUsageJumpBody(displayDelta: String, currentUsage: String) -> String {
        "Used \(displayDelta) since last refresh — possible Max mode query. Now at \(currentUsage)."
    }

    /// Surfaces a system notification when a tier-2 usage jump is detected on Bold
    /// intensity. Callers (the JumpEffectCoordinator) are responsible for gating
    /// on intensity == .bold && tier == .two; this method is intensity-agnostic.
    ///
    /// On the first call with `.notDetermined` status (user has never seen a
    /// threshold notification yet), we prompt for authorization here so that
    /// opting into Bold intensity actually surfaces something. If denied or
    /// already-denied, this is a silent no-op.
    func notifyUsageJump(displayDelta: String, currentUsage: String) async {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            break
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard granted else {
                    Log.info("Usage jump notification skipped: user denied authorization")
                    return
                }
            } catch {
                Log.error("Usage jump notification authorization failed: \(error)")
                return
            }
        default:
            Log.info("Usage jump notification skipped: not authorized")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = "Usage jumped"
        content.body = Self.makeUsageJumpBody(
            displayDelta: displayDelta,
            currentUsage: currentUsage
        )
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "\(Self.usageJumpIdentifierPrefix)-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        do {
            try await center.add(request)
            Log.info("Usage jump notification sent")
        } catch {
            Log.error("Usage jump notification failed: \(error)")
        }
    }

    private func sendNotification(
        title: String,
        body: String,
        identifier: String = UUID().uuidString,
        userInfo: [AnyHashable: Any]? = nil
    ) async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if let userInfo {
                content.userInfo = userInfo
            }

            let request = UNNotificationRequest(
                identifier: identifier,
                content: content,
                trigger: nil
            )
            try await center.add(request)
            Log.info("Notification sent: \(title)")
        } catch {
            Log.error("Notification failed: \(error)")
        }
    }

    // MARK: - Session Expiry Notification (#76)

    /// Fixed identifier (not UUID-suffixed) so a re-fire replaces any previous
    /// banner instead of stacking duplicates in Notification Center.
    nonisolated static let sessionExpiredIdentifier = "session-expired"
    nonisolated static let sessionExpiredTitle = "Cursor session expired"
    // #90: routing-neutral copy — the click may open the popover guidance
    // instead of a login window depending on the browser-login opt-in.
    nonisolated static let sessionExpiredBody = "Reconnect to keep monitoring your Cursor usage."

    func notifySessionExpired() async {
        await sendNotification(
            title: Self.sessionExpiredTitle,
            body: Self.sessionExpiredBody,
            identifier: Self.sessionExpiredIdentifier
        )
    }

    // MARK: - App Status Notifications (#83)

    /// Fixed identifiers so a re-fire replaces the previous banner instead of
    /// stacking duplicates in Notification Center.
    nonisolated static let updateAvailableIdentifier = "update-available"
    nonisolated static let refreshFailingIdentifier = "refresh-failing"
    /// userInfo key carrying the GitHub release page URL as a String.
    nonisolated static let releaseURLUserInfoKey = "releaseURL"

    /// Pure body formatter, unit-tested without UNUserNotificationCenter.
    nonisolated static func makeUpdateAvailableBody(version: String) -> String {
        "v\(version) is out — click to see what's new."
    }

    func notifyUpdateAvailable(version: String, releaseURL: String) async {
        await sendNotification(
            title: "CursorMeter update available",
            body: Self.makeUpdateAvailableBody(version: version),
            identifier: Self.updateAvailableIdentifier,
            userInfo: [Self.releaseURLUserInfoKey: releaseURL]
        )
    }

    func notifyRefreshFailing() async {
        await sendNotification(
            title: "Cursor connection trouble",
            body: "Usage refresh has failed \(UsageViewModel.staleThreshold) times in a row. Data may be stale.",
            identifier: Self.refreshFailingIdentifier
        )
    }

    /// Removes a delivered refresh-failing banner once refresh recovers
    /// (#112) — otherwise a banner delivered during sleep lingers in
    /// Notification Center long after the data is fresh again. Idempotent.
    func withdrawRefreshFailing() {
        UNUserNotificationCenter.current()
            .removeDeliveredNotifications(withIdentifiers: [Self.refreshFailingIdentifier])
    }

    // MARK: - Notification Click Routing (#79, #83)

    /// Pure routing decision for a clicked notification, including userInfo
    /// parsing so malformed payloads are unit-testable. Threshold and
    /// usage-jump notifications keep the default (no-op) click behavior.
    nonisolated static func clickAction(
        forNotificationIdentifier id: String,
        userInfo: [AnyHashable: Any]
    ) -> NotificationClickAction {
        switch id {
        case sessionExpiredIdentifier:
            return .openLoginWindow
        case updateAvailableIdentifier:
            guard let urlString = userInfo[releaseURLUserInfoKey] as? String,
                  let url = URL(string: urlString)
            else { return .none }
            return .openReleaseURL(url)
        case refreshFailingIdentifier:
            return .openPopover
        default:
            return .none
        }
    }
}
