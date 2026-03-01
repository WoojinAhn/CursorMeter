import UserNotifications

// MARK: - Threshold Evaluation

enum ThresholdLevel: Sendable, Equatable {
    case none
    case warning
    case critical
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
        enabled: Bool
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
                title: "Cursor Usage Warning",
                body: "Usage has reached \(Int(percentUsed))% of your limit."
            )
            notifiedThresholds.insert(warningThreshold)
        case .critical:
            await sendNotification(
                title: "Cursor Usage Critical",
                body: "Usage has reached \(Int(percentUsed))% of your limit."
            )
            notifiedThresholds.insert(criticalThreshold)
        }
    }

    func resetNotifications() {
        notifiedThresholds.removeAll()
    }

    private func sendNotification(title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )
            try await center.add(request)
            Log.info("Notification sent: \(title)")
        } catch {
            Log.error("Notification failed: \(error)")
        }
    }
}
