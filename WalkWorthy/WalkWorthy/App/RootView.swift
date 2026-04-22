//
//  RootView.swift
//  WalkWorthy
//
//  Coordinates onboarding and the main tab experience.
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState

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
            } else if appState.onboardingCompleted {
                MainTabView()
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .opacity))
            } else {
                OnboardingForm()
                    .transition(.asymmetric(insertion: .move(edge: .leading), removal: .opacity))
            }
        }
        // Adaptive during the cold-start splash so the SplashView picks the
        // LaunchSplash asset variant matching the device's system setting;
        // forced dark once auth resolves. SplashView locks its own scheme at
        // first render so the nil → .dark flip at transition-out doesn't
        // re-render the splash in the wrong variant before it fades.
        .preferredColorScheme((appState.isCheckingAuth || appState.configurationError != nil) ? nil : .dark)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: appState.isCheckingAuth)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: appState.onboardingCompleted)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: appState.requiresAuthenticationGate)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: appState.configurationError)
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
