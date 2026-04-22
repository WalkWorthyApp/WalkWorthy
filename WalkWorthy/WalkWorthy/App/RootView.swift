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
        // Force dark mode for every branch (splash, title, onboarding, main).
        // The app is dark-only after auth resolves; forcing dark during the
        // splash too prevents a visible variant-swap on light-mode devices
        // where the splash would flash from light → dark at transition-out.
        .preferredColorScheme(.dark)
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
