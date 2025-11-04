//
//  WalkWorthyApp.swift
//  WalkWorthy
//
//  Created by Nathan Jones on 10/4/25.
//  Updated by Codex on 10/5/25.
//

import SwiftUI
import UIKit
import UserNotifications
import BackgroundTasks

@main
struct WalkWorthyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState: AppState
    private let authSession: AuthSession?
    private let config: Config

    init() {
        let resolvedConfig = Config.shared
        print("Cognito domain:", Config.shared.cognitoDomain as Any)
        print("Cognito client ID:", Config.shared.cognitoClientId as Any)
        print("Cognito redirect URI:", Config.shared.cognitoRedirectURI as Any)
        print("BGTask identifiers:", Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") ?? "missing")
        print("BGTask identifiers:",Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") ?? "missing")

        let session = AuthSession(config: resolvedConfig)
        let apiClient: any EncouragementAPI

        if resolvedConfig.apiMode == "live", let session, let liveClient = LiveAPIClient(config: resolvedConfig, tokenProvider: session) {
            apiClient = liveClient
        } else {
            apiClient = MockAPIClient()
        }

        self.config = resolvedConfig
        self.authSession = session
        _appState = StateObject(wrappedValue: AppState(config: resolvedConfig, apiClient: apiClient, authSession: session))

        BackgroundTasksManager.shared.configure(apiClient: apiClient)
        BackgroundTasksManager.shared.register()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .task {
                    await NotificationScheduler.shared.requestAuthorizationIfNeeded()
                    if config.apiMode == "live" {
                        await appState.evaluateAuthentication()
                        if appState.isAuthenticated {
                            await appState.refreshCalendarLinkStatus(force: false)
                            BackgroundTasksManager.shared.scheduleNextRefresh()
                        }
                    }
                    appState.refreshEncouragementDeck()
                    if appState.isCanvasLinked {
                        appState.refreshCanvasSummary()
                    }
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = NotificationScheduler.shared
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        BackgroundTasksManager.shared.scheduleNextRefresh()
    }
}
