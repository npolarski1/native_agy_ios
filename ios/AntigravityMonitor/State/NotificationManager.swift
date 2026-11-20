import Foundation
import Observation
import UserNotifications

public enum NotificationConstants {
    public static let approvalCategory = "APPROVAL_CATEGORY"
    public static let allowAction = "ALLOW_ACTION"
    public static let denyAction = "DENY_ACTION"
    public static let approvalIdKey = "approval_id"
    public static let sessionIdKey = "session_id"
}

@Observable
@MainActor
public final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    public private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    public var notifyOnApprovals: Bool {
        didSet { UserDefaults.standard.set(notifyOnApprovals, forKey: Keys.notifyApprovals) }
    }
    public var notifyOnCompletion: Bool {
        didSet { UserDefaults.standard.set(notifyOnCompletion, forKey: Keys.notifyCompletion) }
    }
    public var notifyOnErrors: Bool {
        didSet { UserDefaults.standard.set(notifyOnErrors, forKey: Keys.notifyErrors) }
    }

    /// Invoked when the user taps Allow or Deny directly on a notification banner.
    public var onApprovalAction: (@MainActor (_ approvalId: String, _ allow: Bool) -> Void)?
    /// Invoked when the user taps a notification to jump to a session or approvals tab.
    public var onSelectRoute: (@MainActor (_ approvalId: String?, _ sessionId: String?) -> Void)?

    private enum Keys {
        static let notifyApprovals = "agymon.notify.approvals"
        static let notifyCompletion = "agymon.notify.completion"
        static let notifyErrors = "agymon.notify.errors"
    }

    private let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Keys.notifyApprovals) == nil {
            self.notifyOnApprovals = true
        } else {
            self.notifyOnApprovals = defaults.bool(forKey: Keys.notifyApprovals)
        }
        if defaults.object(forKey: Keys.notifyCompletion) == nil {
            self.notifyOnCompletion = true
        } else {
            self.notifyOnCompletion = defaults.bool(forKey: Keys.notifyCompletion)
        }
        if defaults.object(forKey: Keys.notifyErrors) == nil {
            self.notifyOnErrors = true
        } else {
            self.notifyOnErrors = defaults.bool(forKey: Keys.notifyErrors)
        }
        super.init()
        configureCategories()
        center.delegate = self
    }

    public func refreshAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    @discardableResult
    public func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorizationStatus()
            return granted
        } catch {
            await refreshAuthorizationStatus()
            return false
        }
    }

    public func updateBadgeCount(_ count: Int) {
        Task {
            try? await center.setBadgeCount(max(0, count))
        }
    }

    public func scheduleApprovalNotification(
        approvalId: String,
        toolName: String,
        summary: String,
        sessionId: String?
    ) {
        guard notifyOnApprovals else { return }

        let content = UNMutableNotificationContent()
        content.title = "Tool Approval Required"
        content.subtitle = toolName
        content.body = summary.isEmpty ? "Approve or deny \(toolName) execution." : summary
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        content.categoryIdentifier = NotificationConstants.approvalCategory

        var userInfo: [AnyHashable: Any] = [NotificationConstants.approvalIdKey: approvalId]
        if let sessionId {
            userInfo[NotificationConstants.sessionIdKey] = sessionId
        }
        content.userInfo = userInfo

        let request = UNNotificationRequest(
            identifier: "approval-\(approvalId)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    public func removeApprovalNotification(approvalId: String) {
        let id = "approval-\(approvalId)"
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.removePendingNotificationRequests(withIdentifiers: [id])
    }

    public func scheduleSessionCompletedNotification(sessionId: String, title: String, detail: String?) {
        guard notifyOnCompletion else { return }

        let content = UNMutableNotificationContent()
        content.title = "Agent Turn Completed"
        content.subtitle = title
        content.body = detail?.isEmpty == false ? (detail ?? "") : "Your Antigravity session finished its turn."
        content.sound = .default
        content.userInfo = [NotificationConstants.sessionIdKey: sessionId]

        let request = UNNotificationRequest(
            identifier: "completed-\(sessionId)-\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    public func scheduleErrorNotification(sessionId: String?, title: String, message: String) {
        guard notifyOnErrors else { return }

        let content = UNMutableNotificationContent()
        content.title = "Antigravity Error"
        content.subtitle = title
        content.body = message
        content.sound = .default
        if let sessionId {
            content.userInfo = [NotificationConstants.sessionIdKey: sessionId]
        }

        let request = UNNotificationRequest(
            identifier: "error-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        center.add(request)
    }

    private func configureCategories() {
        let allowAction = UNNotificationAction(
            identifier: NotificationConstants.allowAction,
            title: "Allow",
            options: [.authenticationRequired]
        )
        let denyAction = UNNotificationAction(
            identifier: NotificationConstants.denyAction,
            title: "Deny",
            options: [.destructive]
        )
        let approvalCategory = UNNotificationCategory(
            identifier: NotificationConstants.approvalCategory,
            actions: [allowAction, denyAction],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        center.setNotificationCategories([approvalCategory])
    }

    private func handleNotificationAction(actionId: String, approvalId: String?, sessionId: String?) {
        switch actionId {
        case NotificationConstants.allowAction:
            if let approvalId {
                onApprovalAction?(approvalId, true)
            }
        case NotificationConstants.denyAction:
            if let approvalId {
                onApprovalAction?(approvalId, false)
            }
        case UNNotificationDefaultActionIdentifier:
            onSelectRoute?(approvalId, sessionId)
        default:
            break
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound, .badge]
    }

    nonisolated public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let actionId = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo
        let approvalId = userInfo[NotificationConstants.approvalIdKey] as? String
        let sessionId = userInfo[NotificationConstants.sessionIdKey] as? String

        await MainActor.run {
            self.handleNotificationAction(
                actionId: actionId,
                approvalId: approvalId,
                sessionId: sessionId
            )
        }
    }
}
