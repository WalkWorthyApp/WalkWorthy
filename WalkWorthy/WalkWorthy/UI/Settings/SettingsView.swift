//
//  SettingsView.swift
//  WalkWorthy
//
//  Settings and account management.
//

import SwiftUI
import UserNotifications

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
                        Text("Use profile for encouragements")
                    }

                    Picker("Bible translation", selection: Binding(
                        get: { appState.selectedTranslation },
                        set: { appState.setTranslation($0) }
                    )) {
                        ForEach(Translation.allCases) { translation in
                            Text(translation.displayName).tag(translation)
                        }
                    }
                }

                Section("Notifications") {
                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        Label("Check-in reminders", systemImage: "bell.badge")
                    }

                    Button {
                        appState.scheduleTestNotification()
                    } label: {
                        Label("Send test notification", systemImage: "bell")
                    }
                }

                Section("Data") {
                    NavigationLink {
                        MoodHistoryView()
                    } label: {
                        Label("Mood history", systemImage: "chart.line.uptrend.xyaxis")
                    }

                    Button(role: .destructive) {
                        appState.clearHistory()
                    } label: {
                        Label("Clear verse history", systemImage: "trash")
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
                    LabeledContent("Build", value: Bundle.main.versionString)
                }
            }
            .navigationTitle("Settings")
        }
    }
}

enum ReminderType {
    case morning
    case midday
    case evening
}

struct NotificationSettingsView: View {
    @State private var morningTime = defaultTime(hour: 7, minute: 0)
    @State private var middayTime = defaultTime(hour: 12, minute: 0)
    @State private var eveningTime = defaultTime(hour: 19, minute: 0)
    @State private var morningEnabled = true
    @State private var middayEnabled = true
    @State private var eveningEnabled = true
    @State private var showNotificationDeniedAlert = false
    @State private var pendingAuthorizationFor: ReminderType?

    private let defaults = UserDefaults.standard

    var body: some View {
        Form {
            Section {
                Text("Choose when you'd like to receive check-in reminders. We'll send a gentle nudge at each time you enable.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Morning") {
                Toggle("Enable morning reminder", isOn: Binding(
                    get: { morningEnabled },
                    set: { handleMorningToggle(newValue: $0) }
                ))
                if morningEnabled {
                    DatePicker("Time", selection: $morningTime, displayedComponents: .hourAndMinute)
                }
            }

            Section("Midday") {
                Toggle("Enable midday reminder", isOn: Binding(
                    get: { middayEnabled },
                    set: { handleMiddayToggle(newValue: $0) }
                ))
                if middayEnabled {
                    DatePicker("Time", selection: $middayTime, displayedComponents: .hourAndMinute)
                }
            }

            Section("Evening") {
                Toggle("Enable evening reminder", isOn: Binding(
                    get: { eveningEnabled },
                    set: { handleEveningToggle(newValue: $0) }
                ))
                if eveningEnabled {
                    DatePicker("Time", selection: $eveningTime, displayedComponents: .hourAndMinute)
                }
            }

            Section {
                Text("Notification times are stored on your device. Actual reminder delivery depends on your notification permissions.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Check-in Reminders")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadSavedSettings()
        }
        .onChange(of: morningTime) { _, newValue in
            saveAndSchedule()
        }
        .onChange(of: middayTime) { _, newValue in
            saveAndSchedule()
        }
        .onChange(of: eveningTime) { _, newValue in
            saveAndSchedule()
        }
        .alert("Notifications Disabled", isPresented: $showNotificationDeniedAlert) {
            Button("Open Settings") {
                openAppSettings()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Check-in reminders require notification permissions. Please enable notifications in Settings to receive reminders.")
        }
    }

    private func handleMorningToggle(newValue: Bool) {
        if !newValue {
            morningEnabled = false
            saveAndSchedule()
            return
        }
        morningEnabled = true
        pendingAuthorizationFor = .morning
        checkAuthorizationAndSchedule()
    }

    private func handleMiddayToggle(newValue: Bool) {
        if !newValue {
            middayEnabled = false
            saveAndSchedule()
            return
        }
        middayEnabled = true
        pendingAuthorizationFor = .midday
        checkAuthorizationAndSchedule()
    }

    private func handleEveningToggle(newValue: Bool) {
        if !newValue {
            eveningEnabled = false
            saveAndSchedule()
            return
        }
        eveningEnabled = true
        pendingAuthorizationFor = .evening
        checkAuthorizationAndSchedule()
    }

    private func checkAuthorizationAndSchedule() {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()

            // If already authorized or provisional, just schedule
            if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
                await MainActor.run {
                    self.saveAndSchedule()
                }
                return
            }

            // If denied, show alert (unless it's notDetermined, in which we'll request)
            if settings.authorizationStatus == .denied {
                await MainActor.run {
                    if let reminderType = self.pendingAuthorizationFor {
                        self.disableToggle(for: reminderType)
                    }
                    self.showNotificationDeniedAlert = true
                }
                return
            }

            // For notDetermined, request authorization
            let granted = try? await center.requestAuthorization(options: [.alert, .badge, .sound])
            await MainActor.run {
                if granted == true {
                    self.saveAndSchedule()
                } else {
                    if let reminderType = self.pendingAuthorizationFor {
                        self.disableToggle(for: reminderType)
                    }
                    self.showNotificationDeniedAlert = true
                }
            }
        }
    }

    private func disableToggle(for reminderType: ReminderType) {
        // Disable the specific toggle that triggered authorization
        switch reminderType {
        case .morning:
            morningEnabled = false
        case .midday:
            middayEnabled = false
        case .evening:
            eveningEnabled = false
        }
        // Clear the pending authorization tracker
        pendingAuthorizationFor = nil
    }

    private func openAppSettings() {
        guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else {
            return
        }
        UIApplication.shared.open(settingsUrl)
    }

    private func loadSavedSettings() {
        // Load enabled states
        if defaults.object(forKey: StorageKeys.morningEnabled) != nil {
            morningEnabled = defaults.bool(forKey: StorageKeys.morningEnabled)
        }
        if defaults.object(forKey: StorageKeys.middayEnabled) != nil {
            middayEnabled = defaults.bool(forKey: StorageKeys.middayEnabled)
        }
        if defaults.object(forKey: StorageKeys.eveningEnabled) != nil {
            eveningEnabled = defaults.bool(forKey: StorageKeys.eveningEnabled)
        }

        // Load times
        if let morningHour = defaults.object(forKey: StorageKeys.morningHour) as? Int,
           let morningMinute = defaults.object(forKey: StorageKeys.morningMinute) as? Int {
            morningTime = Self.defaultTime(hour: morningHour, minute: morningMinute)
        }
        if let middayHour = defaults.object(forKey: StorageKeys.middayHour) as? Int,
           let middayMinute = defaults.object(forKey: StorageKeys.middayMinute) as? Int {
            middayTime = Self.defaultTime(hour: middayHour, minute: middayMinute)
        }
        if let eveningHour = defaults.object(forKey: StorageKeys.eveningHour) as? Int,
           let eveningMinute = defaults.object(forKey: StorageKeys.eveningMinute) as? Int {
            eveningTime = Self.defaultTime(hour: eveningHour, minute: eveningMinute)
        }
    }

    private func saveAndSchedule() {
        // Save enabled states
        defaults.set(morningEnabled, forKey: StorageKeys.morningEnabled)
        defaults.set(middayEnabled, forKey: StorageKeys.middayEnabled)
        defaults.set(eveningEnabled, forKey: StorageKeys.eveningEnabled)

        // Save times
        let calendar = Calendar.current
        let morningComponents = calendar.dateComponents([.hour, .minute], from: morningTime)
        let middayComponents = calendar.dateComponents([.hour, .minute], from: middayTime)
        let eveningComponents = calendar.dateComponents([.hour, .minute], from: eveningTime)

        defaults.set(morningComponents.hour, forKey: StorageKeys.morningHour)
        defaults.set(morningComponents.minute, forKey: StorageKeys.morningMinute)
        defaults.set(middayComponents.hour, forKey: StorageKeys.middayHour)
        defaults.set(middayComponents.minute, forKey: StorageKeys.middayMinute)
        defaults.set(eveningComponents.hour, forKey: StorageKeys.eveningHour)
        defaults.set(eveningComponents.minute, forKey: StorageKeys.eveningMinute)

        // Schedule notifications
        Task {
            await scheduleReminders()
        }
    }

    private func scheduleReminders() async {
        let center = UNUserNotificationCenter.current()

        // Remove existing reminder notifications
        center.removePendingNotificationRequests(withIdentifiers: [
            StorageKeys.morningNotificationId,
            StorageKeys.middayNotificationId,
            StorageKeys.eveningNotificationId
        ])

        // Request authorization if needed
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
            return
        }

        let calendar = Calendar.current

        // Schedule morning reminder
        if morningEnabled {
            let components = calendar.dateComponents([.hour, .minute], from: morningTime)
            await scheduleDaily(
                id: StorageKeys.morningNotificationId,
                title: "Morning Check-in",
                body: "How are you feeling about today?",
                hour: components.hour ?? 7,
                minute: components.minute ?? 0
            )
        }

        // Schedule midday reminder
        if middayEnabled {
            let components = calendar.dateComponents([.hour, .minute], from: middayTime)
            await scheduleDaily(
                id: StorageKeys.middayNotificationId,
                title: "Midday Check-in",
                body: "How is your day going so far?",
                hour: components.hour ?? 12,
                minute: components.minute ?? 0
            )
        }

        // Schedule evening reminder
        if eveningEnabled {
            let components = calendar.dateComponents([.hour, .minute], from: eveningTime)
            await scheduleDaily(
                id: StorageKeys.eveningNotificationId,
                title: "Evening Check-in",
                body: "How was your day?",
                hour: components.hour ?? 19,
                minute: components.minute ?? 0
            )
        }
    }

    private func scheduleDaily(id: String, title: String, body: String, hour: Int, minute: Int) async {
        let center = UNUserNotificationCenter.current()

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        var dateComponents = DateComponents()
        dateComponents.hour = hour
        dateComponents.minute = minute

        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)

        do {
            try await center.add(request)
        } catch {
            print("[NotificationSettingsView] Failed to schedule notification: \(error)")
        }
    }

    private static func defaultTime(hour: Int, minute: Int) -> Date {
        var components = DateComponents()
        components.hour = hour
        components.minute = minute
        return Calendar.current.date(from: components) ?? Date()
    }

    private enum StorageKeys {
        static let morningEnabled = "walkworthy.reminders.morningEnabled"
        static let middayEnabled = "walkworthy.reminders.middayEnabled"
        static let eveningEnabled = "walkworthy.reminders.eveningEnabled"
        static let morningHour = "walkworthy.reminders.morningHour"
        static let morningMinute = "walkworthy.reminders.morningMinute"
        static let middayHour = "walkworthy.reminders.middayHour"
        static let middayMinute = "walkworthy.reminders.middayMinute"
        static let eveningHour = "walkworthy.reminders.eveningHour"
        static let eveningMinute = "walkworthy.reminders.eveningMinute"
        static let morningNotificationId = "walkworthy.reminder.morning"
        static let middayNotificationId = "walkworthy.reminder.midday"
        static let eveningNotificationId = "walkworthy.reminder.evening"
    }
}

private extension Bundle {
    var versionString: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "v\(version) (\(build))"
    }
}
