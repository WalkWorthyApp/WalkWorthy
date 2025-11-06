//
//  BackgroundTasksManager.swift
//  WalkWorthy
//
//  Registers and schedules BGTask refresh jobs for the live API.
//

import Foundation
import BackgroundTasks

final class BackgroundTasksManager {
    static let shared = BackgroundTasksManager()

    private let identifier = "com.walkworthy.refresh"
    private var apiClient: (any EncouragementAPI)?

    private init() {}

    func configure(apiClient: any EncouragementAPI) {
        self.apiClient = apiClient
    }

    func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleAppRefresh(task: refreshTask)
        }
    }

    func scheduleNextRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60 * 30) // 30 minutes
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("[BackgroundTasksManager] Failed to schedule refresh: \(error)")
        }
    }

    private func handleAppRefresh(task: BGAppRefreshTask) {
        scheduleNextRefresh()

        let operation = Task {
            guard let apiClient else {
                task.setTaskCompleted(success: false)
                return
            }
            do {
                let response = try await apiClient.fetchNext()
                if response.shouldNotify {
                    NotificationScheduler.shared.scheduleEncouragementNotification(response.payload)
                }
                task.setTaskCompleted(success: true)
            } catch {
                print("[BackgroundTasksManager] Refresh task failed: \(error)")
                task.setTaskCompleted(success: false)
            }
        }

        task.expirationHandler = {
            operation.cancel()
        }
    }
}
