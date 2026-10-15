//
//  RootView.swift
//  WalkWorthy
//
//  Coordinates onboarding and the main tab experience.
//

import DeclaredAgeRange
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.requestAgeRange) private var requestAgeRange

    var body: some View {
        Group {
            if let configError = appState.configurationError {
                // Blocking error screen — shown ahead of everything so a broken
                // build (missing API URL, SwiftData failure, etc.) surfaces to
                // the user instead of crashing at launch.
                ConfigurationErrorView(message: configError)
                    .transition(.opacity)
            } else if appState.isCheckingAuth {
                // Branded splash while Firebase auth resolves on cold start.
                // Matches the UILaunchScreen (same AppBackground color + logo),
                // so the hand-off from system launch → Swift is seamless and
                // the user never sees a bare black screen during auth check.
                SplashView()
                    .transition(.opacity)
            } else if appState.requiresAuthenticationGate {
                TitleScreenView()
                    .transition(.opacity)
            } else if appState.accountDeletionPending {
                PendingAccountDeletionView()
            } else if appState.accountIsUnderage {
                UnderageAccountView()
            } else if appState.needsEmailVerification {
                // Email/password accounts must verify before entering the app
                // (the backend also rejects unverified tokens with 403).
                EmailVerificationView()
                    .transition(.opacity)
            } else if appState.onboardingCompleted {
                MainTabView()
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .opacity))
            } else {
                OnboardingForm()
                    .transition(.asymmetric(insertion: .move(edge: .leading), removal: .opacity))
            }
        }
        // A restored session never passes the sign-in age toggle, so check the
        // App Store age signal (Texas SB 2420 and similar laws) once per launch
        // for it too. RegulatoryAgeCheck skips this after a passing sign-in.
        .task(id: appState.authenticatedUserSub) {
            guard appState.authenticatedUserSub != nil, !appState.accountDeletionPending,
                  !RegulatoryAgeCheck.confirmedThisLaunch else { return }
            let outcome = await RegulatoryAgeCheck.run(requestAgeRange)
            guard !Task.isCancelled else { return }
            if outcome == .underage {
                // A clear under-18 answer: block the app and delete the account.
                appState.markAccountUnderage()
            } else if let message = outcome.message {
                // Unconfirmed isn't proof of age; sign out until it can be checked.
                appState.signOut(notice: message)
            }
        }
        // Owns the deletion ceremony so it survives Settings or email
        // verification being replaced by the pending-cleanup screen.
        .modifier(AccountDeletionPresentation())
        // Adaptive during the cold-start splash so the SplashView picks the
        // LaunchSplash asset variant matching the device's system setting;
        // forced dark once auth resolves. SplashView locks its own scheme at
        // first render so the nil → .dark flip at transition-out doesn't
        // re-render the splash in the wrong variant before it fades.
        .preferredColorScheme((appState.isCheckingAuth || appState.configurationError != nil) ? nil : .dark)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: appState.isCheckingAuth)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: appState.onboardingCompleted)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: appState.needsEmailVerification)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: appState.requiresAuthenticationGate)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: appState.configurationError)
    }
}

private struct PendingAccountDeletionView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var deletionFlow: AccountDeletionFlow

    var body: some View {
        VStack(spacing: 24) {
            Text("Account deletion").font(.title)
            Text("Your device data is being removed. Retry to finish deleting your account, or sign out if it's already gone.")
            if let error = appState.accountDeletionError {
                Text(error).foregroundStyle(.secondary)
            }
            if appState.accountDeletionBusy || deletionFlow.isWorking { ProgressView() }
            // Preparation re-authenticates only while server deletion remains
            // unconfirmed; completed cloud work needs only local recovery.
            Button("Retry Deletion", role: .destructive) {
                deletionFlow.begin(using: appState, requireConfirmation: false)
            }
            .disabled(appState.accountDeletionBusy || deletionFlow.isWorking)
            Button("Sign Out") { appState.signOut() }
                .disabled(appState.accountDeletionBusy || deletionFlow.isWorking)
            Text("Support: walkworthyofficial@gmail.com")
                .font(.footnote)
                .textSelection(.enabled)
        }
        .multilineTextAlignment(.center)
        .padding(32)
    }
}

/// Shown when the App Store reports the signed-in account as under 18. Starts
/// deletion right away; the backend requires a fresh sign-in, so the existing
/// ceremony asks for the password (or Apple sign-in) first. Backing out keeps
/// the app blocked; signing out leaves deletion to an emailed request.
private struct UnderageAccountView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var deletionFlow: AccountDeletionFlow

    var body: some View {
        VStack(spacing: 24) {
            Text("WalkWorthy is for adults").font(.title)
            Text("Your App Store account shows you're under 18, so this account will be deleted.")
            if deletionFlow.isWorking { ProgressView() }
            Button("Delete Account", role: .destructive) { startDeletion() }
                .disabled(deletionFlow.isWorking)
            Button("Sign Out") { appState.signOut() }
                .disabled(deletionFlow.isWorking)
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .onAppear(perform: startDeletion)
    }

    private func startDeletion() {
        deletionFlow.begin(using: appState, requireConfirmation: false)
    }
}

private struct MainTabView: View {
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                HomeView(selectedTab: $selectedTab)
            }
            .tabItem {
                Label("Home", systemImage: "house.fill")
            }
            .tag(0)

            NavigationStack {
                MoodHistoryView()
            }
            .tabItem {
                Label("History", systemImage: "chart.line.uptrend.xyaxis")
            }
            .tag(1)

            NavigationStack {
                JournalListView()
            }
            .tabItem {
                Label("Journal", systemImage: "book.closed.fill")
            }
            .tag(2)

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
            .tag(3)
        }
    }
}
