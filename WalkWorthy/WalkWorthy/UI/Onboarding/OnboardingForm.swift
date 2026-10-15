//
//  OnboardingForm.swift
//  WalkWorthy
//
//  Collects lightweight profile preferences and saves them to the user's account.
//

import SwiftUI

struct OnboardingForm: View {
    /// Minimum age to use WalkWorthy. Enforced in `validateProfile()` to
    /// WalkWorthy is an adults-only service. Serving minors would pull in the
    /// US app-store age-verification laws (Texas SB 2420, Utah S.B. 142), state
    /// age-appropriate design codes, and COPPA/teen-privacy duties, none of
    /// which a self-declared checkbox satisfies. If that changes, a real age
    /// signal and a minor-specific safety posture are prerequisites, not
    /// follow-ups. Legacy note: if GDPR-EU 16+ localization is ever
    /// needed, bump this constant (or make it locale-aware).
    static let minimumAge: Int = 18

    /// Oldest birthday the wheels offer.
    private static let earliestBirthDate = BirthDate(year: 1900, month: 1, day: 1)?.date ?? .distantPast

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var firstName: String = ""
    @State private var birthDateSelection = Date()
    /// The wheels always show some date, so this records whether the user
    /// actually picked one. The default (today) is deliberately not an
    /// eligible age: a neutral age screen doesn't pre-fill a passing answer.
    @State private var hasChosenBirthDate = false
    @State private var birthDateError: String?
    @State private var saveError: String?
    @State private var isSaving = false
    @State private var isEditingExistingProfile = false
    @FocusState private var focusedField: Field?

    enum Field {
        case firstName
    }

    var body: some View {
        Group {
            if appState.onboardingCompleted {
                formContent
            } else {
                NavigationStack {
                    formContent
                }
            }
        }
    }

    private var formContent: some View {
        ZStack {
            TimeOfDayTheme.current.backdrop
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: scaled(24)) {
                    header
                    firstNameSection
                    birthDateSection
                    primaryButton
                    if !appState.onboardingCompleted {
                        OnboardingAccountActions()
                    }
                }
                .padding(.vertical, scaled(32))
                .padding(.horizontal, scaled(12))
            }
            .scrollContentBackground(.hidden)
        }
        .onAppear(perform: loadProfile)
        .navigationTitle("Let's personalize")
        .toolbarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: scaled(12)) {
            Text("Welcome to WalkWorthy")
                .font(.newsreaderSemiBoldItalic(size: scaled(32)))
            Text("Two quick details. Kept private, never sent to AI.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var firstNameSection: some View {
        VStack(alignment: .leading, spacing: scaled(8)) {
            HStack(spacing: scaled(6)) {
                Text("Display name")
                    .font(.newsreaderSemiBoldItalic(size: scaled(20)))
                Text("(optional)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            TextField("Your display name", text: $firstName)
                .textContentType(.givenName)
                .textInputAutocapitalization(.words)
                .disableAutocorrection(true)
                .padding()
                .glassCard()
                .focused($focusedField, equals: .firstName)
                .accessibilityLabel("Display name (optional)")
        }
    }

    private var birthDateSection: some View {
        VStack(alignment: .leading, spacing: scaled(8)) {
            Text("Birthday")
                .font(.newsreaderSemiBoldItalic(size: scaled(20)))
            // Month, day and year wheels (in the order the user's locale writes dates).
            DatePicker(
                "Birthday",
                selection: Binding(
                    get: { birthDateSelection },
                    set: { newValue in
                        birthDateSelection = newValue
                        hasChosenBirthDate = true
                        birthDateError = nil
                    }
                ),
                in: Self.earliestBirthDate...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.wheel)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .glassCard()
            if let birthDateError {
                Text(birthDateError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private var primaryButton: some View {
        VStack(alignment: .leading, spacing: scaled(8)) {
            if let saveError {
                Text(saveError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            saveButton
        }
        .padding(.top, scaled(16))
    }

    private var saveButton: some View {
        Button(action: saveProfile) {
            Label(isSaving ? "Saving…" : "Save and continue", systemImage: "arrow.forward.circle.fill")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding()
                .background(LinearGradient(colors: [Color.accentColor.opacity(0.85), Color.accentColor], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: scaled(16), style: .continuous))
                .foregroundStyle(Color.white)
        }
        .buttonStyle(.plain)
        .disabled(isSaving)
        .accessibilityHint("Saves your profile to your WalkWorthy account and continues to the app.")
    }

    private func loadProfile() {
        isEditingExistingProfile = appState.onboardingCompleted

        let profile = appState.loadProfile()
        firstName = profile.firstName
        if let birthDate = profile.birthDate {
            birthDateSelection = birthDate.date
            hasChosenBirthDate = true
        } else {
            hasChosenBirthDate = false
        }
        resetValidationMessages()
    }

    private func saveProfile() {
        guard !isSaving, validateProfile() else { return }

        focusedField = nil
        let trimmedFirstName = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        firstName = trimmedFirstName
        isSaving = true
        Task {
            // The server is the record of the birthday (and the 18+ check), so
            // onboarding only completes once it has stored the profile.
            let saved = await appState.updateProfile(firstName: trimmedFirstName, birthDate: chosenBirthDate)
            isSaving = false
            guard saved else {
                saveError = "Couldn't save. Check your connection and birthday, then try again."
                return
            }
            appState.markOnboardingComplete()
            if isEditingExistingProfile {
                dismiss()
            }
        }
    }

    private func validateProfile() -> Bool {
        resetValidationMessages()

        guard let birthDate = chosenBirthDate else {
            birthDateError = "Please choose your birthday."
            return false
        }

        guard birthDate.age() >= Self.minimumAge else {
            birthDateError = "WalkWorthy is available to ages \(Self.minimumAge) and up."
            return false
        }

        return true
    }

    private func resetValidationMessages() {
        birthDateError = nil
        saveError = nil
    }

    /// The picked birthday, or nil until the user has moved the wheels.
    private var chosenBirthDate: BirthDate? {
        hasChosenBirthDate ? BirthDate(date: birthDateSelection) : nil
    }
}

/// Sign-out and deletion for the first-run onboarding gate. Account deletion
/// must be reachable without entering more personal data (App Store Guideline
/// 5.1.1(v)), and Settings is behind this gate. Only built while onboarding is
/// incomplete — RootView then shows this form under `AccountDeletionPresentation`,
/// which supplies `deletionFlow`; the Settings/Home profile editors never
/// instantiate it.
private struct OnboardingAccountActions: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var deletionFlow: AccountDeletionFlow

    var body: some View {
        // Stacked with generous spacing so a tap meant for one can't land on
        // the other; deletion sits last, furthest from the primary button.
        VStack(spacing: scaled(36)) {
            Button("Sign out") {
                appState.signOut()
            }
            .foregroundStyle(.secondary)
            .disabled(deletionFlow.isWorking)

            Button("Delete account") {
                deletionFlow.begin(using: appState)
            }
            .foregroundStyle(.red.opacity(0.9))
            .disabled(deletionFlow.isWorking)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity)
        .padding(.top, scaled(32))
    }
}
