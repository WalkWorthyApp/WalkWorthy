//
//  OnboardingForm.swift
//  WalkWorthy
//
//  Collects lightweight profile preferences and stores them locally.
//

import SwiftUI

struct OnboardingForm: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var firstName: String = ""
    @State private var ageText: String = ""
    @State private var occupation: String = ""
    @State private var major: String = ""
    @State private var gender: Gender = .male
    @State private var selectedHobbies: Set<String> = []
    @State private var customHobby: String = ""
    @State private var optIn: Bool = true
    @State private var ageError: String?
    @State private var contextError: String?
    @State private var hobbiesError: String?
    @State private var isEditingExistingProfile = false
    @FocusState private var focusedField: Field?

    enum Field {
        case firstName
        case age
        case occupation
        case major
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
                    contextSection
                    genderSection
                    hobbiesSection
                    optInSection
                    privacyCopy
                    primaryButton
                }
                .padding(.vertical, scaled(32))
                .padding(.horizontal, scaled(24))
            }
            .scrollContentBackground(.hidden)
        }
        .onAppear(perform: loadProfile)
        .onChange(of: ageText) {
            if ageError != nil { ageError = nil }
        }
        .onChange(of: occupation) {
            if contextError != nil { contextError = nil }
        }
        .onChange(of: major) {
            if contextError != nil { contextError = nil }
        }
        .onChange(of: selectedHobbies) {
            if hobbiesError != nil { hobbiesError = nil }
        }
        .navigationTitle("Let's personalize")
        .toolbarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: scaled(12)) {
            Text("Welcome to WalkWorthy")
                .font(.largeTitle.bold())
            Text("Help us tailor encouragements to your rhythms. Your information stays private and secure.")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var firstNameSection: some View {
        VStack(alignment: .leading, spacing: scaled(8)) {
            HStack(spacing: scaled(6)) {
                Text("First name")
                    .font(.headline)
                Text("(optional)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            TextField("Your first name", text: $firstName)
                .textContentType(.givenName)
                .textInputAutocapitalization(.words)
                .disableAutocorrection(true)
                .padding()
                .glassCard()
                .focused($focusedField, equals: .firstName)
                .accessibilityLabel("First name (optional)")
            Text("Used only for your greeting on the Home screen.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var ageSection: some View {
        VStack(alignment: .leading, spacing: scaled(8)) {
            Text("Age")
                .font(.headline)
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

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: scaled(16)) {
            VStack(alignment: .leading, spacing: scaled(8)) {
                Text("What do you do?")
                    .font(.headline)
                Text("Fill in whichever applies to you, or both.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // Occupation field
            VStack(alignment: .leading, spacing: scaled(6)) {
                Label("Occupation", systemImage: "briefcase")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Software Engineer, Teacher, etc.", text: $occupation)
                    .textContentType(.jobTitle)
                    .padding()
                    .glassCard()
                    .focused($focusedField, equals: .occupation)
                    .accessibilityLabel("Occupation")
            }

            // Major field
            VStack(alignment: .leading, spacing: scaled(6)) {
                Label("Major / Field of Study", systemImage: "graduationcap")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("Computer Science, Nursing, etc.", text: $major)
                    .textContentType(.jobTitle)
                    .padding()
                    .glassCard()
                    .focused($focusedField, equals: .major)
                    .accessibilityLabel("Major")
            }

            if let contextError {
                Text(contextError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private var genderSection: some View {
        VStack(alignment: .leading, spacing: scaled(8)) {
            Text("Gender")
                .font(.headline)
            Picker("Gender", selection: $gender) {
                ForEach(Gender.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var hobbiesSection: some View {
        VStack(alignment: .leading, spacing: scaled(12)) {
            Text("Hobbies")
                .font(.headline)
            Text("Pick a few that spark joy, or add your own.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: scaled(110)), spacing: scaled(12))], spacing: scaled(12)) {
                ForEach(Hobby.allCases, id: \.rawValue) { hobby in
                    TagChip(label: hobby.label, isSelected: selectedHobbies.contains(hobby.label)) {
                        toggleHobby(hobby.label)
                    }
                }
                ForEach(customHobbyChips, id: \.self) { hobby in
                    TagChip(label: hobby, isSelected: selectedHobbies.contains(hobby)) {
                        toggleHobby(hobby)
                    }
                }
            }
            VStack(alignment: .leading, spacing: scaled(8)) {
                Text("Don't see yours? Add it below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                HStack(spacing: scaled(12)) {
                    TextField("Add another hobby", text: $customHobby)
                        .textInputAutocapitalization(.words)
                        .disableAutocorrection(true)
                        .padding()
                        .glassCard()
                        .onSubmit(addCustomHobby)
                    Button("Add", action: addCustomHobby)
                        .buttonStyle(.borderedProminent)
                        .disabled(!canAddCustomHobby)
                }
            }
        }
        if let hobbiesError {
            Text(hobbiesError)
                .font(.footnote)
                .foregroundStyle(.red)
        }
    }

    private var optInSection: some View {
        Toggle(isOn: $optIn) {
            VStack(alignment: .leading, spacing: scaled(4)) {
                Text("Receive encouragement nudges")
                    .font(.headline)
                Text("We'll keep them gentle and focused on Scripture.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
        .padding(.top, scaled(12))
    }

    private var privacyCopy: some View {
        Text("Your data is encrypted and never shared. We use it only to personalize your encouragement experience.")
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
            .accessibilityHint("Saves your preferences locally and continues to the app.")
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
        occupation = profile.occupation
        major = profile.major
        gender = profile.gender
        selectedHobbies = profile.hobbies
        optIn = profile.optIn
        resetValidationMessages()

        if !appState.onboardingCompleted {
            DispatchQueue.main.async {
                if profile.age == nil {
                    focusedField = .age
                } else if profile.occupation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                          profile.major.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    focusedField = .occupation
                }
            }
        }
    }

    private func toggleHobby(_ label: String) {
        if selectedHobbies.contains(label) {
            selectedHobbies.remove(label)
        } else {
            selectedHobbies.insert(label)
        }
    }

    private func addCustomHobby() {
        let trimmed = customHobby.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !selectedHobbies.contains(trimmed) else {
            customHobby = ""
            return
        }
        selectedHobbies.insert(trimmed)
        customHobby = ""
    }

    private var customHobbyChips: [String] {
        let suggested = Set(Hobby.allCases.map(\.label))
        return selectedHobbies
            .filter { !suggested.contains($0) }
            .sorted()
    }

    private var canAddCustomHobby: Bool {
        let trimmed = customHobby.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !selectedHobbies.contains(trimmed)
    }

    private func saveProfile() {
        guard validateProfile() else { return }

        focusedField = nil
        let age = Int(ageText)
        let trimmedFirstName = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOccupation = occupation.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMajor = major.trimmingCharacters(in: .whitespacesAndNewlines)
        firstName = trimmedFirstName
        occupation = trimmedOccupation
        major = trimmedMajor
        appState.updateProfile(firstName: trimmedFirstName, age: age, occupation: trimmedOccupation, major: trimmedMajor, gender: gender, hobbies: selectedHobbies, optIn: optIn)
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

        // Require at least one of occupation or major
        let trimmedOccupation = occupation.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMajor = major.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOccupation.isEmpty || !trimmedMajor.isEmpty else {
            contextError = "Please share your occupation or field of study."
            focusedField = .occupation
            return false
        }

        guard !selectedHobbies.isEmpty else {
            hobbiesError = "Pick at least one hobby."
            return false
        }

        return true
    }

    private func resetValidationMessages() {
        ageError = nil
        contextError = nil
        hobbiesError = nil
    }

    private var shouldShowIncompleteHint: Bool {
        !appState.onboardingCompleted && !formIsComplete
    }

    private var formIsComplete: Bool {
        guard let age = Int(ageText), age > 0 else { return false }
        let trimmedOccupation = occupation.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMajor = major.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedOccupation.isEmpty || !trimmedMajor.isEmpty else { return false }
        return !selectedHobbies.isEmpty
    }
}
