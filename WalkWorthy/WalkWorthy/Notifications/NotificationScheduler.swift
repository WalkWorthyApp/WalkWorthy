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

    @MainActor
    func requestAuthorizationIfNeeded() async {
        center.delegate = self

        // `UNUserNotificationCenter.notificationSettings()` is the authoritative
        // source for authorization state. Mirroring the answer into UserDefaults
        // only invited drift (e.g. user revokes permission in Settings while the
        // app is backgrounded, our flag stays stale). If we ever need this
        // synchronously elsewhere, query the center directly.
        do {
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                return
            case .notDetermined:
                _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            default:
                return
            }
        } catch {
            #if DEBUG
            print("[NotificationScheduler] Authorization error: \(error)")
            #endif
        }
    }

    private var isAuthorized: Bool {
        get async {
            let settings = await center.notificationSettings()
            return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        }
    }

    enum NotificationCategory: String {
        case encouragement = "walkworthy.encouragement"
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
