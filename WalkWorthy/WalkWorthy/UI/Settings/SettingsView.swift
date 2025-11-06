//
//  SettingsView.swift
//  WalkWorthy
//
//  Feature flags and local notification controls.
//

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    private let config = Config.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("Personalization") {
                    NavigationLink {
                        OnboardingForm()
                    } label: {
                        Label("Edit personal details", systemImage: "person.crop.circle")
                    }

                    Toggle(isOn: Binding(
                        get: { appState.useProfilePersonalization },
                        set: { appState.setUseProfilePersonalization($0) }
                    )) {
                        Text("Use onboarding profile")
                    }

                    Picker("Default translation", selection: Binding(
                        get: { appState.selectedTranslation },
                        set: { appState.setTranslation($0) }
                    )) {
                        ForEach(Translation.allCases) { translation in
                            Text(translation.displayName).tag(translation)
                        }
                    }
                }

                Section("Notifications") {
                    Button {
                        appState.scheduleTestNotification()
                    } label: {
                        Label("Send test notification (10s)", systemImage: "bell.badge")
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Schedule background refresh") {
                        BackgroundTasksManager.shared.scheduleNextRefresh()
                    }
                }

                Section("Account") {
                    Button(role: .destructive) {
                        appState.signOut()
                    } label: {
                        Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .disabled(!appState.isAuthenticated)
                }

                Section("About") {
                    LabeledContent("Notifications", value: config.notificationMode)
                    LabeledContent("Build", value: Bundle.main.versionString)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

private extension Bundle {
    var versionString: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "v\(version) (\(build))"
    }
}
