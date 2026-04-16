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
import FirebaseAppCheck
import SwiftData

@main
struct WalkWorthyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var appState: AppState
    private let authSession: FirebaseAuthSession
    private let config: Config
    private let container: ModelContainer

    init() {
        #if DEBUG
        AppCheck.setAppCheckProviderFactory(AppCheckDebugProviderFactory())
        #else
        AppCheck.setAppCheckProviderFactory(AppAttestProviderFactory())
        #endif

        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }

        let resolvedConfig = Config.shared

        #if DEBUG
        print("API Base URL:", resolvedConfig.apiBaseURL as Any)
        #endif

        let authSession = FirebaseAuthSession()
        guard let liveClient = LiveAPIClient(config: resolvedConfig, tokenProvider: authSession, appCheckProvider: authSession) else {
            fatalError("API_BASE_URL is not configured")
        }

        let container: ModelContainer
        do {
            container = try ModelContainer(for: JournalEntry.self)
        } catch {
            #if DEBUG
            print("[WalkWorthyApp] ModelContainer init failed, using in-memory fallback: \(error)")
            #endif
            container = try! ModelContainer(for: JournalEntry.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        }

        self.authSession = authSession
        self.config = resolvedConfig
        self.container = container
        _appState = StateObject(wrappedValue: AppState(
            config: resolvedConfig,
            apiClient: liveClient,
            authSession: authSession,
            modelContainer: container
        ))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .modelContainer(container)
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
        if FirebaseApp.app() == nil {
            FirebaseApp.configure()
        }
        UNUserNotificationCenter.current().delegate = NotificationScheduler.shared
        return true
    }
}
