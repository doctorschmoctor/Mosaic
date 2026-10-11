import Foundation
import AppKit
import UserNotifications
#if SWIFT_PACKAGE
import MosaicCore
#endif

/// What a notification shows of a message.
enum NotificationPreview: String, CaseIterable, Identifiable {
    /// Who wrote, and what they wrote.
    case full
    /// Who wrote only ("New message").
    case nameOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .full: return "Name and message"
        case .nameOnly: return "Name only"
        }
    }
}

/// Whether Mosaic may show notifications, as macOS says.
enum NotificationPermission: Equatable {
    case notDetermined, denied, allowed
}

/// One notification for a new message.
struct MessageNotification: Equatable {
    /// One per message: posting the same one again replaces it rather than adding another.
    let identifier: String
    let conversationID: String
    let title: String
    let body: String
}

/// Where Mosaic's notifications go: the system's notification center in the installed app, a
/// recording in fixture runs (which never ask for permission or show anything).
@MainActor protocol MessageNotifier: AnyObject {
    /// Called with a conversation's id when the reader clicks one of its notifications.
    var onOpen: ((String) -> Void)? { get set }
    func permission() async -> NotificationPermission
    /// Asks macOS (shows its prompt the first time). Only ever called when the reader turns notifications on.
    func requestPermission() async -> Bool
    func post(_ notification: MessageNotification)
    /// Takes a conversation's notifications away (it was opened, or muted).
    func withdraw(conversationID: String)
}

/// The system's notification center. Clicking a notification opens its conversation through
/// the usual opening path.
@MainActor final class SystemNotifier: NSObject, MessageNotifier, UNUserNotificationCenterDelegate {
    var onOpen: ((String) -> Void)?
    private var center: UNUserNotificationCenter { UNUserNotificationCenter.current() }

    override init() {
        super.init()
        center.delegate = self
    }
    func permission() async -> NotificationPermission {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        default: return .allowed
        }
    }
    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }
    func post(_ notification: MessageNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        content.sound = .default
        content.threadIdentifier = notification.conversationID
        content.userInfo = ["conversation": notification.conversationID]
        center.add(UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil))
    }
    func withdraw(conversationID: String) {
        center.getDeliveredNotifications { delivered in
            let ids = delivered.filter { ($0.request.content.userInfo["conversation"] as? String) == conversationID }.map(\.request.identifier)
            guard !ids.isEmpty else { return }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["conversation"] as? String
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if let id { self.onOpen?(id) }
                completionHandler()
            }
        }
    }
    /// While Mosaic is in front, a notification still shows (the store only posts for a
    /// conversation the reader can't see).
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }
}

/// A fixture run's notifications: recorded, never shown; permission is whatever the test says.
@MainActor final class RecordingNotifier: MessageNotifier {
    var onOpen: ((String) -> Void)?
    var granted: NotificationPermission = .notDetermined
    /// What the prompt would answer.
    var grants = true
    private(set) var posted: [MessageNotification] = []
    private(set) var withdrawn: [String] = []
    private(set) var permissionRequests = 0
    func permission() async -> NotificationPermission { granted }
    func requestPermission() async -> Bool {
        permissionRequests += 1
        granted = grants ? .allowed : .denied
        return grants
    }
    func post(_ notification: MessageNotification) {
        posted.removeAll { $0.identifier == notification.identifier }
        posted.append(notification)
    }
    func withdraw(conversationID: String) {
        withdrawn.append(conversationID)
        posted.removeAll { $0.conversationID == conversationID }
    }
    /// The reader clicked a notification.
    func click(_ notification: MessageNotification) { onOpen?(notification.conversationID) }
}
