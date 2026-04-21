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

        // C1 — degraded-mode fallback instead of fatalError.
        // If Config.apiBaseURL is missing/invalid we still construct a valid
        // (but unreachable) LiveAPIClient so the rest of the app type-checks,
        // and we surface a configuration-error screen via AppState.
        var startupError: String?
        let liveClient: LiveAPIClient
        if let configured = LiveAPIClient(config: resolvedConfig, tokenProvider: authSession, appCheckProvider: authSession) {
            liveClient = configured
        } else {
            startupError = "Unable to load configuration. Please reinstall the app or contact support."
            // RFC 2606 reserved TLD `invalid` — NXDOMAIN, guaranteed non-routable.
            // IMPORTANT: must NOT be `.local` (mDNS/Bonjour); any device on a
            // hostile Wi-Fi could claim that name and intercept the Authorization
            // bearer token. Parsing this URL literal is infallible — the force
            // unwrap can never trap.
            let fallbackURL = URL(string: "https://invalid/")!
            liveClient = LiveAPIClient(baseURL: fallbackURL, tokenProvider: authSession, appCheckProvider: authSession)
        }

        // C2 — never crash at @main on SwiftData failure.
        // Try on-disk first, then in-memory with JournalEntry, then an empty-schema
        // in-memory container as a last resort. In the last-resort branch the
        // Journal feature is gracefully disabled — writes will no-op — and the
        // user sees ConfigurationErrorView via `startupError`.
        let container: ModelContainer = {
            do {
                return try ModelContainer(for: JournalEntry.self)
            } catch {
                #if DEBUG
                print("[WalkWorthyApp] ModelContainer init failed, trying in-memory fallback: \(error)")
                #endif
            }

            do {
                let fallback = try ModelContainer(
                    for: JournalEntry.self,
                    configurations: ModelConfiguration(isStoredInMemoryOnly: true)
                )
                startupError = startupError ?? "Journal storage unavailable — please reinstall."
                return fallback
            } catch {
                #if DEBUG
                print("[WalkWorthyApp] In-memory ModelContainer also failed: \(error)")
                #endif
            }

            startupError = "Journal storage unavailable — please reinstall."
            // Final fallback: empty-schema in-memory container. Minimal and
            // well-formed — if SwiftData still fails here, the device is in an
            // unrecoverable state and a crash at @main is unavoidable.
            // swiftlint:disable:next force_try
            return try! ModelContainer(
                for: Schema([] as [any PersistentModel.Type]),
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        }()

        self.authSession = authSession
        self.config = resolvedConfig
        self.container = container
        let state = AppState(
            config: resolvedConfig,
            apiClient: liveClient,
            authSession: authSession,
            modelContainer: container
        )
        state.markConfigurationError(startupError)
        _appState = StateObject(wrappedValue: state)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .modelContainer(container)
                .preferredColorScheme(.dark)
                .task {
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

/// Custom App Check provider factory that uses Apple's App Attest service.
/// Firebase doesn't ship a built-in App Attest factory, so we implement
/// `AppCheckProviderFactory` ourselves and return an `AppAttestProvider`.
final class AppAttestProviderFactory: NSObject, AppCheckProviderFactory {
    func createProvider(with app: FirebaseApp) -> AppCheckProvider? {
        return AppAttestProvider(app: app)
    }
}
