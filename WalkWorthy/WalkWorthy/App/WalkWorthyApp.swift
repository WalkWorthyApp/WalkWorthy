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
    @Environment(\.scenePhase) private var scenePhase
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
        // Delegates to `makeHardenedModelContainer()` which:
        //   • Places the store at a hardened explicit URL under Application
        //     Support and applies `FileProtectionType.complete` +
        //     `isExcludedFromBackupKey` to the on-disk file and its -wal/-shm
        //     SQLite sidecars (keeps mental-health PII out of unencrypted
        //     iTunes/iCloud backups).
        //   • Falls back to an in-memory JournalEntry container, then finally
        //     to an empty-schema in-memory container if on-disk fails. In a
        //     fallback branch the Journal feature is gracefully disabled —
        //     writes will no-op — and the user sees ConfigurationErrorView
        //     via `startupError`.
        let containerResult = Self.makeHardenedModelContainer()
        let container = containerResult.container
        if let fallbackMessage = containerResult.fallbackMessage {
            startupError = startupError ?? fallbackMessage
        }

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
                // Re-fetch mood status on foreground so a user who returns at
                // 5pm sees the evening check-in prompt instead of whatever the
                // morning fetch cached. AppState itself throttles redundant
                // fetches within a 60s window.
                .onChange(of: scenePhase) { _, newPhase in
                    guard newPhase == .active, appState.isAuthenticated else { return }
                    Task {
                        await appState.loadMoodStatus()
                    }
                }
        }
    }
}

extension WalkWorthyApp {
    /// Result of building the SwiftData container. When `fallbackMessage` is
    /// non-nil the on-disk store was unavailable and the caller should surface
    /// the message via `ConfigurationErrorView` (journal writes will no-op or
    /// live in-memory only).
    struct ContainerBuildResult {
        let container: ModelContainer
        let fallbackMessage: String?
    }

    /// Builds the SwiftData container at an explicit, hardened URL.
    ///
    /// Security hardening applied here:
    ///   1. **Explicit URL** under `Application Support/WalkWorthy/Journal/default.store`
    ///      instead of SwiftData's `default.store`, so we control the file.
    ///   2. **`FileProtectionType.complete`** on the journal directory and all
    ///      store files (primary + `-wal` + `-shm` SQLite sidecars) so their
    ///      bytes are unreadable whenever the device is locked. Without this,
    ///      the store is readable from an unencrypted iTunes backup while the
    ///      device is unlocked.
    ///   3. **`isExcludedFromBackupKey = true`** on each store file so journal
    ///      content — which can include free-text mental-health PII — never
    ///      ends up in iTunes / iCloud device backups.
    ///
    /// Falls back through the same three tiers as the pre-existing C2 logic:
    /// on-disk hardened → in-memory JournalEntry → empty-schema in-memory. Any
    /// fallback surfaces a user-facing message via `ContainerBuildResult`.
    static func makeHardenedModelContainer() -> ContainerBuildResult {
        let fileManager = FileManager.default

        // Tier 1: hardened on-disk store under Application Support.
        if let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            let journalDir = appSupport.appendingPathComponent("WalkWorthy/Journal", isDirectory: true)
            do {
                try fileManager.createDirectory(
                    at: journalDir,
                    withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.complete]
                )
                // Re-assert protection on the directory in case it already
                // existed with a weaker attribute — idempotent and cheap.
                try fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.complete],
                    ofItemAtPath: journalDir.path
                )

                let storeURL = journalDir.appendingPathComponent("default.store", isDirectory: false)
                let config = ModelConfiguration(url: storeURL)
                let container = try ModelContainer(for: JournalEntry.self, configurations: config)

                // Post-creation hardening: SwiftData may create the store file
                // and its SQLite sidecars (-wal, -shm) with the directory's
                // inherited attributes on some OS versions but not others.
                // Apply explicitly to every known sidecar that exists.
                applyDataProtection(to: storeURL, fileManager: fileManager)

                return ContainerBuildResult(container: container, fallbackMessage: nil)
            } catch {
                #if DEBUG
                print("[WalkWorthyApp] Hardened on-disk container failed: \(error); trying in-memory fallback")
                #endif
            }
        } else {
            #if DEBUG
            print("[WalkWorthyApp] Could not resolve Application Support; trying in-memory fallback")
            #endif
        }

        // Tier 2: in-memory JournalEntry container.
        do {
            let fallback = try ModelContainer(
                for: JournalEntry.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
            return ContainerBuildResult(
                container: fallback,
                fallbackMessage: "Journal storage unavailable — please reinstall."
            )
        } catch {
            #if DEBUG
            print("[WalkWorthyApp] In-memory ModelContainer also failed: \(error)")
            #endif
        }

        // Tier 3: empty-schema in-memory last resort. Minimal and well-formed —
        // if SwiftData still fails here, the device is in an unrecoverable
        // state and a crash at @main is unavoidable.
        // swiftlint:disable:next force_try
        let emptyContainer = try! ModelContainer(
            for: Schema([] as [any PersistentModel.Type]),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        return ContainerBuildResult(
            container: emptyContainer,
            fallbackMessage: "Journal storage unavailable — please reinstall."
        )
    }

    /// Applies `FileProtectionType.complete` + `isExcludedFromBackupKey = true`
    /// to the SwiftData store file and its `-wal`/`-shm` SQLite sidecars.
    private static func applyDataProtection(to storeURL: URL, fileManager: FileManager) {
        // SQLite WAL mode names sidecars <store>-wal / <store>-shm (dash,
        // not dot).
        let urls: [URL] = [
            storeURL,
            URL(fileURLWithPath: storeURL.path + "-wal"),
            URL(fileURLWithPath: storeURL.path + "-shm"),
        ]

        for url in urls {
            guard fileManager.fileExists(atPath: url.path) else { continue }

            do {
                try fileManager.setAttributes(
                    [.protectionKey: FileProtectionType.complete],
                    ofItemAtPath: url.path
                )
            } catch {
                #if DEBUG
                print("[WalkWorthyApp] setAttributes(protection) failed for \(url.lastPathComponent): \(error)")
                #endif
            }

            var mutableURL = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            do {
                try mutableURL.setResourceValues(values)
            } catch {
                #if DEBUG
                print("[WalkWorthyApp] setResourceValues(noBackup) failed for \(url.lastPathComponent): \(error)")
                #endif
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
