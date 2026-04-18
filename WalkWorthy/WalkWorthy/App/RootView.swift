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
            if appState.isCheckingAuth {
                Color(.systemBackground)
                    .ignoresSafeArea()
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
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: appState.isCheckingAuth)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: appState.onboardingCompleted)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: appState.requiresAuthenticationGate)
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
