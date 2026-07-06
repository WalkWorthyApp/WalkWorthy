////  NotificationScheduler.swift
//  WalkWorthy
//
//  Handles opting into and scheduling local notifications.
//

import Foundation
import UserNotifications

final class NotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationScheduler()

    private let center = UNUserNotificationCenter.current()

    private override init() {
        super.init()
    }

    // MARK: - Authorization

    enum AuthorizationOutcome {
        case authorized
        case denied
    }

    /// Resolves the current authorization state, prompting the user when
    /// permission has not been determined yet. `.denied` covers both a prior
    /// explicit denial and the user declining the prompt.
    ///
    /// `UNUserNotificationCenter.notificationSettings()` is the authoritative
    /// source for authorization state. Mirroring the answer into UserDefaults
    /// only invited drift (e.g. user revokes permission in Settings while the
    /// app is backgrounded, our flag stays stale). If we ever need this
    /// synchronously elsewhere, query the center directly.
    func resolveAuthorization() async -> AuthorizationOutcome {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return .authorized
        case .denied:
            return .denied
        default:
            // Not determined yet — ask the user now.
            let granted = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
            return granted == true ? .authorized : .denied
        }
    }

    private var isAuthorized: Bool {
        get async {
            let settings = await center.notificationSettings()
            return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        }
    }

    // MARK: - Daily Reminders

    /// A repeating local notification fired at the same time every day.
    struct DailyReminder {
        let id: String
        let title: String
        let body: String
        let hour: Int
        let minute: Int
    }

    /// Replaces the pending requests for `identifiers` with the given
    /// reminders. Removal always runs so disabled reminders are cleaned up;
    /// scheduling is skipped entirely when notifications are not authorized.
    func replaceDailyReminders(_ reminders: [DailyReminder], clearing identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)

        guard await isAuthorized else { return }

        for reminder in reminders {
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default

            var dateComponents = DateComponents()
            dateComponents.hour = reminder.hour
            dateComponents.minute = reminder.minute

            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
            let request = UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger)

            do {
                try await center.add(request)
            } catch {
                #if DEBUG
                print("[NotificationScheduler] Failed to schedule notification: \(error)")
                #endif
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
