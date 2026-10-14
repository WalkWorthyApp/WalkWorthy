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

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var firstName: String = ""
    @State private var ageText: String = ""
    @State private var ageError: String?
    @State private var isEditingExistingProfile = false
    @FocusState private var focusedField: Field?

    enum Field {
        case firstName
        case age
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
                    ageSection
                    privacyCopy
                    primaryButton
                }
                .padding(.vertical, scaled(32))
                .padding(.horizontal, scaled(12))
            }
            .scrollContentBackground(.hidden)
        }
        .onAppear(perform: loadProfile)
        .onChange(of: ageText) {
            if ageError != nil { ageError = nil }
        }
        .navigationTitle("Let's personalize")
        .toolbarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: scaled(12)) {
            Text("Welcome to WalkWorthy")
                .font(.newsreaderSemiBoldItalic(size: scaled(32)))
            Text("Just two quick details to get started. Your information stays private and secure.")
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
            Text("Used only for your greeting on the Home screen.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var ageSection: some View {
        VStack(alignment: .leading, spacing: scaled(8)) {
            Text("Age")
                .font(.newsreaderSemiBoldItalic(size: scaled(20)))
            TextField("18", text: $ageText)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .padding()
                .glassCard()
                .focused($focusedField, equals: .age)
                .accessibilityLabel("Age")
            if let ageError {
                Text(ageError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private var privacyCopy: some View {
        Text("Your name and age are stored in your WalkWorthy account and are never sent to OpenAI.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .padding(.top, scaled(8))
    }

    private var primaryButton: some View {
        VStack(alignment: .leading, spacing: scaled(12)) {
            if shouldShowIncompleteHint {
                Text("Tell us a little about you to continue.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            Button(action: saveProfile) {
                Label("Save and continue", systemImage: "arrow.forward.circle.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(LinearGradient(colors: [Color.accentColor.opacity(0.85), Color.accentColor], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: scaled(16), style: .continuous))
                    .foregroundStyle(Color.white)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Saves your profile to your WalkWorthy account and continues to the app.")
        }
        .padding(.top, scaled(16))
    }

    private func loadProfile() {
        isEditingExistingProfile = appState.onboardingCompleted

        let profile = appState.loadProfile()
        firstName = profile.firstName
        if let age = profile.age {
            ageText = String(age)
        } else {
            ageText = ""
        }
        resetValidationMessages()

        if !appState.onboardingCompleted {
            DispatchQueue.main.async {
                if profile.age == nil {
                    focusedField = .age
                }
            }
        }
    }

    private func saveProfile() {
        guard validateProfile() else { return }

        focusedField = nil
        let age = Int(ageText)
        let trimmedFirstName = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        firstName = trimmedFirstName
        appState.updateProfile(firstName: trimmedFirstName, age: age)
        appState.markOnboardingComplete()

        if isEditingExistingProfile {
            dismiss()
        }
    }

    private func validateProfile() -> Bool {
        resetValidationMessages()

        guard let age = Int(ageText), age > 0 else {
            ageError = "Please enter your age."
            focusedField = .age
            return false
        }

        guard age >= Self.minimumAge else {
            ageError = "WalkWorthy is available to ages \(Self.minimumAge) and up. Please enter an age of \(Self.minimumAge) or older to continue."
            focusedField = .age
            return false
        }

        return true
    }

    private func resetValidationMessages() {
        ageError = nil
    }

    private var shouldShowIncompleteHint: Bool {
        !appState.onboardingCompleted && !formIsComplete
    }

    private var formIsComplete: Bool {
        guard let age = Int(ageText), age > 0 else { return false }
        return age >= Self.minimumAge
    }
}
