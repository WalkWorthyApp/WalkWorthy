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
            if appState.requiresAuthenticationGate {
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
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: appState.onboardingCompleted)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: appState.requiresAuthenticationGate)
    }
}

private struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack {
                HomeView()
            }
            .tabItem {
                Label("Home", systemImage: "house.fill")
            }

            NavigationStack {
                MoodHistoryView()
            }
            .tabItem {
                Label("History", systemImage: "chart.line.uptrend.xyaxis")
            }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
    }
}
