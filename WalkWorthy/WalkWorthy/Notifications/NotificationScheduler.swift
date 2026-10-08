////  NotificationScheduler.swift
//  WalkWorthy
//
//  Handles opting into and scheduling local notifications.
//

import Foundation
import UserNotifications

@MainActor
final class NotificationScheduler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationScheduler()

    private let center = UNUserNotificationCenter.current()
    struct Session {
        let userSub: String
        fileprivate let epoch: UUID
    }
    private var activeSession: Session?
    private var scheduleGeneration: UInt64 = 0

    func beginSession(for userSub: String) {
        guard activeSession?.userSub != userSub else { return }
        scheduleGeneration &+= 1
        activeSession = Session(userSub: userSub, epoch: UUID())
    }

    func session(for userSub: String) -> Session? {
        guard activeSession?.userSub == userSub else { return nil }
        return activeSession
    }

    func isCurrent(_ session: Session) -> Bool {
        activeSession?.userSub == session.userSub && activeSession?.epoch == session.epoch
    }

    /// Synchronous invalidation happens before deletion/sign-out can suspend.
    func invalidateSession(for userSub: String) {
        guard activeSession?.userSub == userSub else { return }
        scheduleGeneration &+= 1
        activeSession = nil
    }

    private func accountPrefix(_ userSub: String) -> String {
        "walkworthy.reminder.\(Data(userSub.utf8).base64EncodedString())."
    }

    private func sessionPrefix(_ session: Session) -> String {
        "\(accountPrefix(session.userSub))\(session.epoch.uuidString)."
    }

    private let legacyIdentifiers = [
        "walkworthy.reminder.morning", "walkworthy.reminder.midday", "walkworthy.reminder.evening"
    ]

    /// Late adds remove their own unique IDs; this sweep handles requests that
    /// were already pending/delivered, including requests from a previous launch.
    func removeReminders(for userSub: String, includingLegacy: Bool) async {
        let pending = await center.pendingNotificationRequests()
        let pendingIDs = pending.map(\.identifier).filter {
            shouldRemove($0, for: userSub, includingLegacy: includingLegacy)
        }
        center.removePendingNotificationRequests(withIdentifiers: pendingIDs)
        let delivered = await center.deliveredNotifications()
        let deliveredIDs = delivered.map { $0.request.identifier }.filter {
            shouldRemove($0, for: userSub, includingLegacy: includingLegacy)
        }
        center.removeDeliveredNotifications(withIdentifiers: deliveredIDs)
    }

    private func shouldRemove(_ identifier: String, for userSub: String, includingLegacy: Bool) -> Bool {
        // A cleanup begun before a rapid re-sign-in cannot clear the new session.
        if let activeSession, identifier.hasPrefix(sessionPrefix(activeSession)) { return false }
        return identifier.hasPrefix(accountPrefix(userSub)) ||
            (includingLegacy && legacyIdentifiers.contains(identifier))
    }

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

    /// Each schedule owns unique request IDs. If it becomes stale during add(),
    /// compensation removes only that request, never a newer session's reminder.
    func replaceDailyReminders(_ reminders: [DailyReminder], session: Session) async {
        guard isCurrent(session), !Task.isCancelled else { return }
        scheduleGeneration &+= 1
        let generation = scheduleGeneration
        let operationID = UUID().uuidString
        let pending = await center.pendingNotificationRequests()
        guard isCurrent(session), scheduleGeneration == generation, !Task.isCancelled else { return }
        center.removePendingNotificationRequests(withIdentifiers: pending.map(\.identifier).filter {
            $0.hasPrefix(accountPrefix(session.userSub)) || legacyIdentifiers.contains($0)
        })
        guard await isAuthorized else { return }

        for reminder in reminders {
            guard isCurrent(session), scheduleGeneration == generation, !Task.isCancelled else { return }
            let content = UNMutableNotificationContent()
            content.title = reminder.title
            content.body = reminder.body
            content.sound = .default
            var dateComponents = DateComponents()
            dateComponents.hour = reminder.hour
            dateComponents.minute = reminder.minute
            let identifier = "\(sessionPrefix(session))\(operationID).\(reminder.id)"
            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
            let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
            do {
                try await center.add(request)
                if !isCurrent(session) || scheduleGeneration != generation || Task.isCancelled {
                    center.removePendingNotificationRequests(withIdentifiers: [identifier])
                    center.removeDeliveredNotifications(withIdentifiers: [identifier])
                    return
                }
            } catch {
                // add() can fail after the OS has accepted a request; keep cleanup
                // conservative, using an ID no other operation can own.
                center.removePendingNotificationRequests(withIdentifiers: [identifier])
                center.removeDeliveredNotifications(withIdentifiers: [identifier])
                #if DEBUG
                print("[NotificationScheduler] Failed to schedule notification")
                #endif
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
