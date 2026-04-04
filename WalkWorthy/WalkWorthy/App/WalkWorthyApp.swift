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
import FirebaseCore

@main
struct WalkWorthyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState: AppState
    private let authSession: FirebaseAuthSession
    private let config: Config

    init() {
        // Initialize Firebase synchronously before creating FirebaseAuthSession
        // This ensures Firebase is configured before any Firebase APIs are accessed
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }

        let resolvedConfig = Config.shared

        #if DEBUG
        print("API Base URL:", resolvedConfig.apiBaseURL as Any)
        #endif

        let authSession = FirebaseAuthSession()
        guard let liveClient = LiveAPIClient(config: resolvedConfig, tokenProvider: authSession) else {
            fatalError("API_BASE_URL is not configured")
        }

        self.authSession = authSession
        self.config = resolvedConfig
        _appState = StateObject(wrappedValue: AppState(config: resolvedConfig, apiClient: liveClient, authSession: authSession))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .task {
                    await NotificationScheduler.shared.requestAuthorizationIfNeeded()
                    await appState.startObservingAuthState()
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Firebase is already configured in WalkWorthyApp.init
        // This guard is a safety net in case init hasn't run yet (though it should have)
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        UNUserNotificationCenter.current().delegate = NotificationScheduler.shared
        return true
    }
}
