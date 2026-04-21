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
    private let authorizationKey = "walkworthy.notifications.authorized"

    private override init() {
        super.init()
    }

    @MainActor
    func requestAuthorizationIfNeeded() async {
        let defaults = UserDefaults.standard
        center.delegate = self

        do {
            let settings = await center.notificationSettings()
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                defaults.set(true, forKey: authorizationKey)
                return
            case .notDetermined:
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                defaults.set(granted, forKey: authorizationKey)
            default:
                defaults.set(false, forKey: authorizationKey)
            }
        } catch {
            defaults.set(false, forKey: authorizationKey)
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
