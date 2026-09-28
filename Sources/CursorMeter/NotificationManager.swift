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

    func thresholdBody(level: ThresholdLevel, at percent: Int) -> String {
        if let fraction { return "\(fraction) · alert at \(percent)%" }
        return "Your \(level == .critical ? "critical" : "warning") level is \(percent)%."
    }

    var fraction: String? {
        switch self {
        case let .requestQuota(used, limit):
            return limit > 0 ? "\(used) of \(limit) requests" : nil
        case let .creditPlan(used, limit), let .onDemand(used, limit):
            return limit > 0 ? "\(Self.formatUSD(used)) of \(Self.formatUSD(limit))" : nil
        case .percentOnly: return nil
        }
    }

    var scopeLabel: String {
        switch self {
        case .requestQuota: return "Request quota"
        case .creditPlan, .percentOnly: return "Included usage"
        case .onDemand: return "Paid budget"
        }
    }
}

/// Values from one completed refresh, retained across notification permission waits.
struct LegacyUsageJumpSnapshot: Sendable, Equatable {
    let mode: JumpEvent.Mode
    let reference: Double
    let current: Double
    let limit: Double

    var title: String {
        switch mode {
        case .credit, .percent: "Included usage increased"
        case .onDemand: "Paid spending increased"
        case .request: "Request usage increased"
        }
    }

    var changeBody: String {
        let delta = current - reference
        switch mode {
        case .credit, .onDemand:
            return String(format: "+$%.2f since last refresh", delta / 100)
        case .request:
            return "\(Int(delta.rounded())) more requests since last refresh"
        case .percent:
            return "Last refresh \(UsagePercentFormatter.percent(reference)) → now \(UsagePercentFormatter.percent(current))"
        }
    }

    var currentBody: String? {
        guard limit > 0 else { return nil }
        switch mode {
        case .credit, .onDemand:
            let fraction = String(format: "$%.2f of $%.2f", current / 100, limit / 100)
            return "\(fraction)\(mode == .onDemand ? " budget" : "") used"
        case .request:
            return "\(Int(current)) of \(Int(limit)) requests used"
        case .percent: return nil
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

enum NotificationPermissionState: Sendable, Equatable {
    case unknown, notDetermined, denied, authorized, provisional
}

// MARK: - Notification Manager

@MainActor
final class NotificationManager {
    private struct PendingLegacyBold {
        let content: UsageNotificationContent
        let revision: UInt64
    }
    private(set) var notifiedThresholds: Set<Int> = []
    private var notificationRevision: UInt64 = 0
    private var pendingLegacyBold: PendingLegacyBold?
    private var legacyBoldWorker: Task<Void, Never>?
    private let requestAuthorization: @MainActor () async throws -> Bool
    private let deliver: @MainActor (UNNotificationRequest) async throws -> Void
    private let permissionStateProvider: @MainActor () async -> NotificationPermissionState

    init(
        requestAuthorization: @escaping @MainActor () async throws -> Bool = {
            try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        },
        deliver: @escaping @MainActor (UNNotificationRequest) async throws -> Void = {
            try await UNUserNotificationCenter.current().add($0)
        },
        permissionStateProvider: @escaping @MainActor () async -> NotificationPermissionState = { .unknown }
    ) {
        self.requestAuthorization = requestAuthorization
        self.deliver = deliver
        self.permissionStateProvider = permissionStateProvider
    }

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
        mode: NotificationMode,
        jump: LegacyUsageJumpSnapshot? = nil
    ) async {
        guard !Task.isCancelled else { return }
        let revision = notificationRevision

        let level = enabled ? Self.evaluateThreshold(
            percentUsed: percentUsed,
            warningThreshold: warningThreshold,
            criticalThreshold: criticalThreshold,
            notifiedThresholds: notifiedThresholds
        ) : .none

        let threshold = level == .critical ? criticalThreshold : warningThreshold
        guard let content = Self.legacyUsageContent(percentUsed: percentUsed, level: level,
                                                    threshold: threshold, mode: mode, jump: jump) else { return }
        if level == .none {
            scheduleLegacyBold(content, revision: revision)
            return
        }
        await sendNotification(title: content.title, body: content.body,
                               identifier: "usage-threshold-\(UUID().uuidString)", revision: revision)
        guard revision == notificationRevision, !Task.isCancelled else { return }
        // Keep the legacy acknowledgement contract, including authorization denial
        // and delivery failure; the persistent split ledger has a different policy.
        if level != .none { notifiedThresholds.insert(threshold) }
    }

    nonisolated static func legacyUsageContent(
        percentUsed: Double, level: ThresholdLevel, threshold: Int,
        mode: NotificationMode, jump: LegacyUsageJumpSnapshot?
    ) -> UsageNotificationContent? {
        if level != .none {
            let label = level == .critical ? "Critical" : "Warning"
            let rows = [mode.thresholdBody(level: level, at: threshold)] + (jump.map { [$0.changeBody] } ?? [])
            return UsageNotificationContent(title: "\(mode.scopeLabel) \(UsagePercentFormatter.percent(percentUsed)) · \(label)",
                                            body: rows.joined(separator: "\n"))
        }
        guard let jump else { return nil }
        return UsageNotificationContent(title: jump.title,
            body: ([jump.changeBody] + (jump.currentBody.map { [$0] } ?? [])).joined(separator: "\n"))
    }

    func resetNotifications() {
        notificationRevision += 1
        notifiedThresholds.removeAll()
        pendingLegacyBold = nil
    }

    private func scheduleLegacyBold(_ content: UsageNotificationContent, revision: UInt64) {
        // Keep at most the active send and the newest pending observation while
        // macOS authorization waits; later refreshes must remain free to finish.
        pendingLegacyBold = PendingLegacyBold(content: content, revision: revision)
        if legacyBoldWorker == nil {
            legacyBoldWorker = Task { await drainLegacyBold() }
        }
    }

    private func drainLegacyBold() async {
        while let pending = pendingLegacyBold {
            pendingLegacyBold = nil
            guard pending.revision == notificationRevision else { continue }
            await sendNotification(title: pending.content.title, body: pending.content.body,
                identifier: "\(Self.usageJumpIdentifierPrefix)-\(UUID().uuidString)", revision: pending.revision)
        }
        legacyBoldWorker = nil
    }

    func waitUntilUsageIdle() async { await legacyBoldWorker?.value }

    /// Test-only — overwrites the dedup set so oscillation/rollover tests can
    /// simulate post-notification state.
    internal func testHook_seed(_ set: Set<Int>) {
        notifiedThresholds = set
    }

    // MARK: - Usage Jump Notification

    /// Identifier prefix used for usage-jump notification requests, kept distinct
    /// from threshold notifications so callers/tests can disambiguate.
    nonisolated static let usageJumpIdentifierPrefix = "usage-jump"

    func permissionState() async -> NotificationPermissionState { await permissionStateProvider() }

    static func systemPermissionState() async -> NotificationPermissionState {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        default: .unknown
        }
    }

    func authorizeUsageNotifications() async -> Bool {
        do { return try await requestAuthorization() }
        catch { return false }
    }

    func submitUsageNotification(title: String, body: String, identifier: String) async -> Bool {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        do {
            try await deliver(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
            return true
        } catch { return false }
    }

    private func sendNotification(
        title: String,
        body: String,
        identifier: String = UUID().uuidString,
        userInfo: [AnyHashable: Any]? = nil,
        revision: UInt64? = nil
    ) async {
        do {
            let granted = try await requestAuthorization()
            guard granted, !Task.isCancelled,
                  revision == nil || revision == notificationRevision else { return }

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
            try await deliver(request)
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
    nonisolated static let sessionExpiredBody = "Reconnect to resume usage updates."

    func notifySessionExpired() async {
        await sendNotification(
            title: Self.sessionExpiredTitle,
            body: Self.sessionExpiredBody,
            identifier: Self.sessionExpiredIdentifier,
            revision: notificationRevision
        )
    }

    // MARK: - App Status Notifications (#83)

    /// Fixed identifiers so a re-fire replaces the previous banner instead of
    /// stacking duplicates in Notification Center.
    nonisolated static let updateAvailableIdentifier = "update-available"
    nonisolated static let refreshFailingIdentifier = "refresh-failing"
    /// userInfo key carrying the GitHub release page URL as a String.
    nonisolated static let releaseURLUserInfoKey = "releaseURL"

    nonisolated static let updateAvailableBody = "See what’s new on GitHub."

    func notifyUpdateAvailable(version: String, releaseURL: String) async {
        await sendNotification(
            title: "Update available: v\(version)",
            body: Self.updateAvailableBody,
            identifier: Self.updateAvailableIdentifier,
            userInfo: [Self.releaseURLUserInfoKey: releaseURL]
        )
    }

    func notifyRefreshFailing() async {
        await sendNotification(
            title: "Can’t refresh Cursor usage",
            body: "\(UsageViewModel.staleThreshold) refreshes failed in a row.\nData may be out of date.",
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
    /// parsing so malformed payloads are unit-testable. Usage notifications open
    /// the current popover without carrying a historical account snapshot.
    nonisolated static func clickAction(
        forNotificationIdentifier id: String,
        userInfo: [AnyHashable: Any]
    ) -> NotificationClickAction {
        if ["usage-jump-", "usage-threshold-", "usage-split-"].contains(where: id.hasPrefix) {
            return .openPopover
        }
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
