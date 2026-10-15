//
//  SettingsView.swift
//  WalkWorthy
//
//  Settings and account management.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var appState: AppState
    private let config = Config.shared

    /// Account deletion (App Store Guideline 5.1.1(v)) runs in RootView's
    /// session-bound ceremony; this screen only starts it.
    @EnvironmentObject private var deletionFlow: AccountDeletionFlow
    @State private var showAIConsent = false
    @State private var didCopySupportAddress = false
    @State private var showSuggestionBox = false

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

                        // No Bible translation picker: the app is ESV-only.
                        // Every quotation ships from a reviewed server-side
                        // catalog (functions/src/lib/scripture-catalog.ts) and
                        // the Verse of the Day list, both ESV. Supporting
                        // another translation is a licensing task, not a UI
                        // one — NIV, NASB, CSB, NLT and NKJV each require their
                        // own permission from their publisher before their text
                        // can ship. Add the picker back only alongside licensed
                        // catalog text for whatever translations are added.
                    }

                    // Withdrawal control for the AIConsentView permission
                    // (App Review Guideline 5.1.2(i)); the footer is a short
                    // summary, the full disclosure is the consent screen.
                    Section {
                        Toggle(isOn: Binding(
                            get: { appState.aiConsentGiven },
                            set: { enabled in
                                if enabled { showAIConsent = true }
                                else { appState.withdrawAIConsent() }
                            }
                        )) {
                            Text("Share check-ins with OpenAI")
                        }
                        .listRowBackground(Color.wwCardBackground)

                        if let error = appState.aiConsentError {
                            Text(error).font(.footnote)
                            Button("Retry privacy request") { appState.retryAIConsent() }
                                .disabled(appState.aiConsentBusy)
                        }
                        if appState.aiConsentBusy { ProgressView("Updating permission…") }
                    } header: {
                        Text("AI & Your Data")
                    } footer: {
                        Text("When on, check-ins are sent to OpenAI to write your encouragement and reflections and to screen for safety. Turning this off stops future requests but doesn't erase past ones. WalkWorthy isn't medical or mental-health care; in the U.S., call or text 988.")
                    }

                    Section("Notifications") {
                        NavigationLink {
                            NotificationSettingsView()
                        } label: {
                            Label("Reminders", systemImage: "bell.badge")
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
                        .disabled(!appState.isAuthenticated || deletionFlow.isWorking)
                        .listRowBackground(Color.wwCardBackground)

                        Button(role: .destructive) {
                            deletionFlow.begin(using: appState)
                        } label: {
                            HStack {
                                Label("Delete account", systemImage: "trash")
                                if deletionFlow.isWorking {
                                    Spacer()
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .disabled(!appState.isAuthenticated || deletionFlow.isWorking)
                        .listRowBackground(Color.wwCardBackground)
                    }

                    Section("About") {
                        LabeledContent("Build", value: Bundle.main.versionString)
                            .listRowBackground(Color.wwCardBackground)
                        Link(destination: URL(string: "https://walkworthy-app.web.app/privacy")!) {
                            HStack {
                                Text("Privacy Policy")
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .listRowBackground(Color.wwCardBackground)
                        Link(destination: URL(string: "https://walkworthy-app.web.app/health-data")!) {
                            HStack {
                                Text("Consumer Health Data Policy")
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .listRowBackground(Color.wwCardBackground)
                        Link(destination: URL(string: "https://walkworthy-app.web.app/ai-safety")!) {
                            HStack {
                                Text("AI Safety Information")
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .listRowBackground(Color.wwCardBackground)
                        Link(destination: URL(string: "https://walkworthy-app.web.app/terms")!) {
                            HStack {
                                Text("Terms of Use")
                                Spacer()
                                Image(systemName: "arrow.up.right.square")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .listRowBackground(Color.wwCardBackground)
                        Button {
                            showSuggestionBox = true
                        } label: {
                            HStack {
                                Text("Send a Suggestion")
                                Spacer()
                                Image(systemName: "lightbulb")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .disabled(!appState.isAuthenticated)
                        .listRowBackground(Color.wwCardBackground)
                        // Not a Link: `mailto:` is inert with no mail client
                        // (Simulator, or Mail removed / no account), and a dead
                        // tap is unacceptable for the only rights-request and
                        // support channel. Fall back to copying the address.
                        Button {
                            SupportContact.compose(
                                subject: "WalkWorthy support",
                                openURL: openURL
                            ) { opened in didCopySupportAddress = !opened }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Contact Support")
                                    Text(SupportContact.address)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .textSelection(.enabled)
                                }
                                Spacer()
                                Image(systemName: "envelope")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .listRowBackground(Color.wwCardBackground)
                        if didCopySupportAddress {
                            Text("No mail app is available on this device. The address was copied to your clipboard.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .listRowBackground(Color.wwCardBackground)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .navigationTitle("Settings")
                .sheet(isPresented: $showAIConsent) {
                    AIConsentView(onContinue: { showAIConsent = false }, onDecline: { showAIConsent = false })
                        .interactiveDismissDisabled(appState.aiConsentBusy)
                }
                .sheet(isPresented: $showSuggestionBox) {
                    SuggestionBoxView()
                }
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
    @State private var birthdayEnabled = false
    @State private var showNotificationDeniedAlert = false
    @State private var pendingAuthorizationFor: ReminderType?
    @State private var reminderSession: NotificationScheduler.Session?

    private let defaults = UserDefaults.standard

    /// Scopes reminder preference keys to the signed-in user so shared
    /// devices don't leak one account's notification schedule to another.
    /// Falls back to the bare key only for pre-auth reads — those should
    /// never occur in practice because this view requires authentication.
    private func scopedKey(_ baseKey: String) -> String {
        guard let userSub = reminderSession?.userSub else { return baseKey }
        return "\(baseKey)::\(userSub)"
    }

    var body: some View {
        ZStack {
            TimeOfDayTheme.current.backdrop
                .ignoresSafeArea()

            Form {
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

                Section("Birthday") {
                    Toggle("Send a birthday message", isOn: Binding(
                        get: { birthdayEnabled },
                        set: { handleBirthdayToggle(newValue: $0) }
                    ))
                    .listRowBackground(Color.wwCardBackground)
                }
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Reminders")
            .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard let sub = appState.authenticatedUserSub, !appState.accountDeletionPending else { return }
            reminderSession = NotificationScheduler.shared.session(for: sub)
            loadSavedSettings()
            showActualReminderState()
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
            Text("Turn on notifications for WalkWorthy in Settings to get reminders.")
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

    /// Toggles must reflect what will actually be delivered: without
    /// notification permission nothing can fire, so show them off; with it,
    /// book what is shown (reminders are cleared on sign-out and otherwise
    /// only rebooked when a setting changes).
    private func showActualReminderState() {
        Task {
            if await NotificationScheduler.shared.isAuthorized {
                saveAndSchedule()
            } else {
                morningEnabled = false
                middayEnabled = false
                eveningEnabled = false
                birthdayEnabled = false
            }
        }
    }

    private func handleBirthdayToggle(newValue: Bool) {
        guard let session = reminderSession, NotificationScheduler.shared.isCurrent(session),
              !appState.accountDeletionPending else { return }
        birthdayEnabled = newValue
        ReminderPreferences.setBirthdayEnabled(newValue, for: session.userSub)
        Task {
            if newValue, await NotificationScheduler.shared.resolveAuthorization() == .denied {
                guard NotificationScheduler.shared.isCurrent(session) else { return }
                birthdayEnabled = false
                ReminderPreferences.setBirthdayEnabled(false, for: session.userSub)
                showNotificationDeniedAlert = true
                return
            }
            await NotificationScheduler.shared.syncBirthdayReminder(using: appState)
        }
    }

    private func checkAuthorizationAndSchedule() {
        guard let session = reminderSession, NotificationScheduler.shared.isCurrent(session) else { return }
        Task {
            // Resolves the current permission state, prompting the user if it
            // hasn't been determined yet.
            let outcome = await NotificationScheduler.shared.resolveAuthorization()
            await MainActor.run {
                guard NotificationScheduler.shared.isCurrent(session), !appState.accountDeletionPending else { return }
                switch outcome {
                case .authorized:
                    self.saveAndSchedule()
                case .denied:
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
        // Legacy bare values have no owner provenance. Read only this account's
        // scoped settings; auth transitions discard ambiguous upgrade residue.
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
        if let userSub = reminderSession?.userSub {
            birthdayEnabled = ReminderPreferences.birthdayEnabled(for: userSub)
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
        guard let session = reminderSession, NotificationScheduler.shared.isCurrent(session),
              !appState.accountDeletionPending else { return }
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
            await scheduleReminders(session: session)
        }
    }

    private func scheduleReminders(session: NotificationScheduler.Session) async {
        guard NotificationScheduler.shared.isCurrent(session), !appState.accountDeletionPending else { return }
        let calendar = Calendar.current
        var reminders: [NotificationScheduler.DailyReminder] = []

        if morningEnabled {
            let components = calendar.dateComponents([.hour, .minute], from: morningTime)
            reminders.append(NotificationScheduler.DailyReminder(
                id: StorageKeys.morningNotificationId,
                title: "Morning Check-in",
                body: "How are you feeling about today?",
                hour: components.hour ?? 7,
                minute: components.minute ?? 0
            ))
        }

        if middayEnabled {
            let components = calendar.dateComponents([.hour, .minute], from: middayTime)
            reminders.append(NotificationScheduler.DailyReminder(
                id: StorageKeys.middayNotificationId,
                title: "Midday Check-in",
                body: "How is your day going so far?",
                hour: components.hour ?? 12,
                minute: components.minute ?? 0
            ))
        }

        if eveningEnabled {
            let components = calendar.dateComponents([.hour, .minute], from: eveningTime)
            reminders.append(NotificationScheduler.DailyReminder(
                id: StorageKeys.eveningNotificationId,
                title: "Evening Check-in",
                body: "How was your day?",
                hour: components.hour ?? 19,
                minute: components.minute ?? 0
            ))
        }

        // The scheduler always clears the old requests first so disabled
        // reminders are removed even when nothing new is scheduled.
        await NotificationScheduler.shared.replaceDailyReminders(reminders, session: session)
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

extension Bundle {
    var versionString: String {
        let version = object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "v\(version) (\(build))"
    }
}
