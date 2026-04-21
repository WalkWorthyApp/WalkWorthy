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
            ZStack {
                TimeOfDayTheme.current.backdrop
                    .ignoresSafeArea()

                Form {
                    Section("Personalization") {
                        NavigationLink {
                            OnboardingForm()
                        } label: {
                            Label("Edit personal details", systemImage: "person.crop.circle")
                        }
                        .listRowBackground(Color.wwCardBackground)

                        Toggle(isOn: Binding(
                            get: { appState.useProfilePersonalization },
                            set: { appState.setUseProfilePersonalization($0) }
                        )) {
                            Text("Use profile for encouragements")
                        }
                        .listRowBackground(Color.wwCardBackground)

                        // Bible translation picker removed until multi-translation
                        // content is actually shipped. Today the app uses ESV
                        // everywhere (Verse of the Day, AI encouragements), so a
                        // 7-option picker would be misleading. AppState still tracks
                        // selectedTranslation (default ESV) and the backend schema
                        // accepts all 7 values, so re-adding the picker is a small
                        // diff — restore this Picker, setTranslation, and
                        // syncStoredProfile when real translation content lands.
                    }

                    Section("Notifications") {
                        NavigationLink {
                            NotificationSettingsView()
                        } label: {
                            Label("Check-in reminders", systemImage: "bell.badge")
                        }
                        .listRowBackground(Color.wwCardBackground)
                    }

                    Section("Data") {
                        NavigationLink {
                            MoodLogView()
                        } label: {
                            Label("Check-in log", systemImage: "list.bullet.rectangle")
                        }
                        .listRowBackground(Color.wwCardBackground)
                    }

                    Section("Account") {
                        Button(role: .destructive) {
                            appState.signOut()
                        } label: {
                            Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .disabled(!appState.isAuthenticated)
                        .listRowBackground(Color.wwCardBackground)
                    }

                    Section("About") {
                        LabeledContent("Build", value: Bundle.main.versionString)
                            .listRowBackground(Color.wwCardBackground)
                    }
                }
                .scrollContentBackground(.hidden)
                .navigationTitle("Settings")
            }
        }
    }
}

enum ReminderType {
    case morning
    case midday
    case evening
}

struct NotificationSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var morningTime = defaultTime(hour: 7, minute: 0)
    @State private var middayTime = defaultTime(hour: 12, minute: 0)
    @State private var eveningTime = defaultTime(hour: 19, minute: 0)
    @State private var morningEnabled = true
    @State private var middayEnabled = true
    @State private var eveningEnabled = true
    @State private var showNotificationDeniedAlert = false
    @State private var pendingAuthorizationFor: ReminderType?

    private let defaults = UserDefaults.standard

    /// Scopes reminder preference keys to the signed-in user so shared
    /// devices don't leak one account's notification schedule to another.
    /// Falls back to the bare key only for pre-auth reads — those should
    /// never occur in practice because this view requires authentication.
    private func scopedKey(_ baseKey: String) -> String {
        guard let userSub = appState.authenticatedUserSub else { return baseKey }
        return "\(baseKey)::\(userSub)"
    }

    var body: some View {
        ZStack {
            TimeOfDayTheme.current.backdrop
                .ignoresSafeArea()

            Form {
                Section {
                    Text("Choose when you'd like to receive check-in reminders. We'll send a gentle nudge at each time you enable.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.wwCardBackground)
                }

                Section("Morning") {
                    Toggle("Enable morning reminder", isOn: Binding(
                        get: { morningEnabled },
                        set: { handleMorningToggle(newValue: $0) }
                    ))
                    .listRowBackground(Color.wwCardBackground)
                    if morningEnabled {
                        DatePicker("Time", selection: $morningTime, displayedComponents: .hourAndMinute)
                            .listRowBackground(Color.wwCardBackground)
                    }
                }

                Section("Midday") {
                    Toggle("Enable midday reminder", isOn: Binding(
                        get: { middayEnabled },
                        set: { handleMiddayToggle(newValue: $0) }
                    ))
                    .listRowBackground(Color.wwCardBackground)
                    if middayEnabled {
                        DatePicker("Time", selection: $middayTime, displayedComponents: .hourAndMinute)
                            .listRowBackground(Color.wwCardBackground)
                    }
                }

                Section("Evening") {
                    Toggle("Enable evening reminder", isOn: Binding(
                        get: { eveningEnabled },
                        set: { handleEveningToggle(newValue: $0) }
                    ))
                    .listRowBackground(Color.wwCardBackground)
                    if eveningEnabled {
                        DatePicker("Time", selection: $eveningTime, displayedComponents: .hourAndMinute)
                            .listRowBackground(Color.wwCardBackground)
                    }
                }

                Section {
                    Text("Notification times are stored on your device. Actual reminder delivery depends on your notification permissions.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .listRowBackground(Color.wwCardBackground)
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Check-in Reminders")
            .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadSavedSettings()
        }
        .onChange(of: morningTime) { _, _ in
            saveAndSchedule()
        }
        .onChange(of: middayTime) { _, _ in
            saveAndSchedule()
        }
        .onChange(of: eveningTime) { _, _ in
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

    /// One-shot migration: older TestFlight builds wrote reminder preferences
    /// under the bare (unscoped) key. When we introduced per-user scoping, any
    /// existing value stopped being read — which looked like "reminders silently
    /// reset" to those users. This copies the bare value to the scoped slot on
    /// first read and removes the bare key so we don't migrate twice.
    /// Idempotent: once the scoped slot exists the helper is a no-op.
    private func migrateReminderKeyIfNeeded(bare: String) {
        guard let userSub = appState.authenticatedUserSub else { return }
        let scoped = "\(bare)::\(userSub)"
        if defaults.object(forKey: scoped) == nil,
           let value = defaults.object(forKey: bare) {
            defaults.set(value, forKey: scoped)
            defaults.removeObject(forKey: bare)
        }
    }

    private func loadSavedSettings() {
        // Migrate any legacy unscoped reminder keys into the per-user scope so
        // existing TestFlight users retain their reminder times and toggles.
        let legacyKeys = [
            StorageKeys.morningEnabled,
            StorageKeys.middayEnabled,
            StorageKeys.eveningEnabled,
            StorageKeys.morningHour,
            StorageKeys.morningMinute,
            StorageKeys.middayHour,
            StorageKeys.middayMinute,
            StorageKeys.eveningHour,
            StorageKeys.eveningMinute,
        ]
        for key in legacyKeys {
            migrateReminderKeyIfNeeded(bare: key)
        }

        let morningEnabledKey = scopedKey(StorageKeys.morningEnabled)
        let middayEnabledKey = scopedKey(StorageKeys.middayEnabled)
        let eveningEnabledKey = scopedKey(StorageKeys.eveningEnabled)
        let morningHourKey = scopedKey(StorageKeys.morningHour)
        let morningMinuteKey = scopedKey(StorageKeys.morningMinute)
        let middayHourKey = scopedKey(StorageKeys.middayHour)
        let middayMinuteKey = scopedKey(StorageKeys.middayMinute)
        let eveningHourKey = scopedKey(StorageKeys.eveningHour)
        let eveningMinuteKey = scopedKey(StorageKeys.eveningMinute)

        // Load enabled states
        if defaults.object(forKey: morningEnabledKey) != nil {
            morningEnabled = defaults.bool(forKey: morningEnabledKey)
        }
        if defaults.object(forKey: middayEnabledKey) != nil {
            middayEnabled = defaults.bool(forKey: middayEnabledKey)
        }
        if defaults.object(forKey: eveningEnabledKey) != nil {
            eveningEnabled = defaults.bool(forKey: eveningEnabledKey)
        }

        // Load times
        if let morningHour = defaults.object(forKey: morningHourKey) as? Int,
           let morningMinute = defaults.object(forKey: morningMinuteKey) as? Int {
            morningTime = Self.defaultTime(hour: morningHour, minute: morningMinute)
        }
        if let middayHour = defaults.object(forKey: middayHourKey) as? Int,
           let middayMinute = defaults.object(forKey: middayMinuteKey) as? Int {
            middayTime = Self.defaultTime(hour: middayHour, minute: middayMinute)
        }
        if let eveningHour = defaults.object(forKey: eveningHourKey) as? Int,
           let eveningMinute = defaults.object(forKey: eveningMinuteKey) as? Int {
            eveningTime = Self.defaultTime(hour: eveningHour, minute: eveningMinute)
        }
    }

    private func saveAndSchedule() {
        // Save enabled states
        defaults.set(morningEnabled, forKey: scopedKey(StorageKeys.morningEnabled))
        defaults.set(middayEnabled, forKey: scopedKey(StorageKeys.middayEnabled))
        defaults.set(eveningEnabled, forKey: scopedKey(StorageKeys.eveningEnabled))

        // Save times
        let calendar = Calendar.current
        let morningComponents = calendar.dateComponents([.hour, .minute], from: morningTime)
        let middayComponents = calendar.dateComponents([.hour, .minute], from: middayTime)
        let eveningComponents = calendar.dateComponents([.hour, .minute], from: eveningTime)

        defaults.set(morningComponents.hour, forKey: scopedKey(StorageKeys.morningHour))
        defaults.set(morningComponents.minute, forKey: scopedKey(StorageKeys.morningMinute))
        defaults.set(middayComponents.hour, forKey: scopedKey(StorageKeys.middayHour))
        defaults.set(middayComponents.minute, forKey: scopedKey(StorageKeys.middayMinute))
        defaults.set(eveningComponents.hour, forKey: scopedKey(StorageKeys.eveningHour))
        defaults.set(eveningComponents.minute, forKey: scopedKey(StorageKeys.eveningMinute))

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
            #if DEBUG
            print("[NotificationSettingsView] Failed to schedule notification: \(error)")
            #endif
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
