//
//  AppState.swift
//  WalkWorthy
//
//  Central application state for the live WalkWorthy experience.
//

import Foundation
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var selectedTranslation: Translation
    @Published var onboardingCompleted: Bool
    @Published var useProfilePersonalization: Bool
    @Published private(set) var authenticatedUserSub: String?
    @Published var isAuthenticated: Bool {
        didSet {
            if !isAuthenticated {
                clearMoodState()
            }
        }
    }
    @Published var authenticationNotice: String?

    // MARK: - Mood Tracking State
    @Published var currentMoodStatus: MoodStatusResponse?
    @Published var latestMoodResponse: MoodCheckInResponse?

    private(set) var apiClient: any EncouragementAPI
    private let notificationScheduler: NotificationScheduler
    private let defaults: UserDefaults
    private let config: Config
    private let authSession: FirebaseAuthSession
    private static let userScopedKeys: Set<String> = [
        StorageKey.onboardingCompleted,
        StorageKey.useProfilePersonalization,
        StorageKey.translation,
        StorageKey.profileAge,
        StorageKey.profileMajor,
        StorageKey.profileOccupation,
        StorageKey.profileGender,
        StorageKey.profileHobbies,
        StorageKey.profileOptIn,
    ]

    init(
        config: Config? = nil,
        apiClient: any EncouragementAPI,
        authSession: FirebaseAuthSession,
        notificationScheduler: NotificationScheduler? = nil,
        defaults: UserDefaults = .standard
    ) {
        let resolvedConfig = config ?? Config.shared
        let resolvedScheduler = notificationScheduler ?? NotificationScheduler.shared

        self.config = resolvedConfig
        self.apiClient = apiClient
        self.authSession = authSession
        self.notificationScheduler = resolvedScheduler
        self.defaults = defaults
        self.isAuthenticated = false
        self.selectedTranslation = resolvedConfig.defaultTranslation
        self.authenticatedUserSub = nil
        self.useProfilePersonalization = true
        self.onboardingCompleted = false

        reloadUserScopedPreferences()

        if !onboardingCompleted {
            isAuthenticated = false
            Task {
                try? await authSession.signOut()
            }
        }
    }

    func markOnboardingComplete() {
        onboardingCompleted = true
        defaults.set(true, forKey: storageKey(StorageKey.onboardingCompleted))
    }

    /// Updates user profile data in both local storage and Firebase backend.
    ///
    /// Security Note: Profile data (age, occupation, major, gender, hobbies) is stored in UserDefaults
    /// as a local cache. This data is protected by iOS Data Protection, which encrypts UserDefaults
    /// when the device is locked. The authoritative copy is synced to Firebase with proper security rules.
    /// Authentication tokens use Keychain storage with kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly.
    func updateProfile(age: Int?, occupation: String, major: String, gender: Gender, hobbies: Set<String>, optIn: Bool) {
        let trimmedOccupation = occupation.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMajor = major.trimmingCharacters(in: .whitespacesAndNewlines)
        if let age {
            defaults.set(age, forKey: storageKey(StorageKey.profileAge))
        } else {
            defaults.removeObject(forKey: storageKey(StorageKey.profileAge))
        }
        defaults.set(trimmedOccupation, forKey: storageKey(StorageKey.profileOccupation))
        defaults.set(trimmedMajor, forKey: storageKey(StorageKey.profileMajor))
        defaults.set(gender.rawValue, forKey: storageKey(StorageKey.profileGender))
        defaults.set(Array(hobbies), forKey: storageKey(StorageKey.profileHobbies))
        defaults.set(optIn, forKey: storageKey(StorageKey.profileOptIn))

        syncProfile(age: age, occupation: trimmedOccupation, major: trimmedMajor, gender: gender, hobbies: hobbies, optIn: optIn)
    }

    func loadProfile() -> OnboardingProfile {
        if authenticatedUserSub == nil {
            return OnboardingProfile(age: nil, occupation: "", major: "", gender: .male, hobbies: [], optIn: true)
        }

        let age = defaults.value(forKey: storageKey(StorageKey.profileAge)) as? Int
        let occupation = defaults.string(forKey: storageKey(StorageKey.profileOccupation)) ?? ""
        let major = defaults.string(forKey: storageKey(StorageKey.profileMajor)) ?? ""
        let gender = Gender(rawValue: defaults.string(forKey: storageKey(StorageKey.profileGender)) ?? "") ?? .male
        let hobbies = Set(defaults.stringArray(forKey: storageKey(StorageKey.profileHobbies)) ?? [])
        let optIn = defaults.object(forKey: storageKey(StorageKey.profileOptIn)) as? Bool ?? true
        return OnboardingProfile(age: age, occupation: occupation, major: major, gender: gender, hobbies: hobbies, optIn: optIn)
    }

    func setUseProfilePersonalization(_ isOn: Bool) {
        useProfilePersonalization = isOn
        defaults.set(isOn, forKey: storageKey(StorageKey.useProfilePersonalization))
    }

    func setTranslation(_ translation: Translation) {
        selectedTranslation = translation
        defaults.set(translation.rawValue, forKey: storageKey(StorageKey.translation))
        syncStoredProfile()
    }

    func scheduleTestNotification() {
        notificationScheduler.scheduleTestNotification()
    }

    func evaluateAuthentication() async {
        do {
            _ = try await authSession.validBearerToken()
            isAuthenticated = true
            authenticationNotice = nil
            await refreshAuthenticatedUser()
        } catch {
            isAuthenticated = false
            authenticationNotice = "Your session has expired. Please sign in again."
            setAuthenticatedUserSub(nil)
        }
    }

    func startSignIn(email: String, password: String) async throws {
        do {
            try await authSession.signIn(email: email, password: password)
            isAuthenticated = true
            authenticationNotice = nil
            await refreshAuthenticatedUser()
        } catch {
            isAuthenticated = false
            setAuthenticatedUserSub(nil)
            throw error
        }
    }

    func createAccount(email: String, password: String) async throws {
        do {
            try await authSession.createAccount(email: email, password: password)
            isAuthenticated = true
            authenticationNotice = nil
            await refreshAuthenticatedUser()
        } catch {
            isAuthenticated = false
            setAuthenticatedUserSub(nil)
            throw error
        }
    }

    func signOut() {
        Task {
            try? await authSession.signOut()

            await MainActor.run { [self] in
                isAuthenticated = false
                authenticationNotice = "You have been signed out. Please sign in again."
                setAuthenticatedUserSub(nil)
            }
        }
    }

    var requiresAuthenticationGate: Bool {
        !isAuthenticated
    }

    private func setAuthenticatedUserSub(_ sub: String?) {
        if authenticatedUserSub == sub {
            return
        }

        authenticatedUserSub = sub

        if let sub {
            defaults.set(sub, forKey: StorageKey.lastAuthenticatedUser)
        } else {
            defaults.removeObject(forKey: StorageKey.lastAuthenticatedUser)
        }

        reloadUserScopedPreferences()
    }

    func refreshAuthenticatedUser() async {
        do {
            let sub = try await authSession.currentUserSub()
            setAuthenticatedUserSub(sub)
        } catch {
            setAuthenticatedUserSub(nil)
        }
    }

    private func storageKey(_ key: String) -> String {
        guard let userSub = authenticatedUserSub,
              Self.userScopedKeys.contains(key) else {
            return key
        }
        return "\(key)::\(userSub)"
    }

    private func reloadUserScopedPreferences() {
        if authenticatedUserSub == nil {
            onboardingCompleted = false
            useProfilePersonalization = true
            selectedTranslation = config.defaultTranslation
            return
        }

        let onboardingKey = storageKey(StorageKey.onboardingCompleted)
        var storedOnboardingCompleted = defaults.bool(forKey: onboardingKey)
        if storedOnboardingCompleted && !hasStoredProfile() {
            defaults.set(false, forKey: onboardingKey)
            storedOnboardingCompleted = false
        }
        onboardingCompleted = storedOnboardingCompleted

        useProfilePersonalization = defaults.object(forKey: storageKey(StorageKey.useProfilePersonalization)) as? Bool ?? true

        selectedTranslation = Translation(rawValue: defaults.string(forKey: storageKey(StorageKey.translation)) ?? "") ?? config.defaultTranslation
    }

    private func hasStoredProfile() -> Bool {
        if authenticatedUserSub == nil {
            return false
        }

        if defaults.object(forKey: storageKey(StorageKey.profileAge)) != nil { return true }
        if defaults.object(forKey: storageKey(StorageKey.profileOccupation)) != nil { return true }
        if defaults.object(forKey: storageKey(StorageKey.profileMajor)) != nil { return true }
        if defaults.object(forKey: storageKey(StorageKey.profileGender)) != nil { return true }
        if defaults.object(forKey: storageKey(StorageKey.profileHobbies)) != nil { return true }
        if defaults.object(forKey: storageKey(StorageKey.profileOptIn)) != nil { return true }
        return false
    }

    private func syncProfile(age: Int?, occupation: String, major: String, gender: Gender, hobbies: Set<String>, optIn: Bool) {
        guard isAuthenticated else { return }
        let profile = OnboardingProfile(age: age, occupation: occupation, major: major, gender: gender, hobbies: hobbies, optIn: optIn)
        Task {
            await sendProfileUpdate(profile)
        }
    }

    private func syncStoredProfile() {
        guard isAuthenticated else { return }
        let profile = loadProfile()
        Task {
            await sendProfileUpdate(profile)
        }
    }

    private func sendProfileUpdate(_ profile: OnboardingProfile) async {
        guard isAuthenticated else { return }
        let trimmedOccupation = profile.occupation.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMajor = profile.major.trimmingCharacters(in: .whitespacesAndNewlines)
        let hobbies = profile.hobbies.sorted()

        // Get user's timezone
        let timezone = TimeZone.current.identifier

        let payload = RemoteUserProfileRequest(
            ageRange: ageRangeString(for: profile.age),
            occupation: trimmedOccupation.isEmpty ? nil : trimmedOccupation,
            major: trimmedMajor.isEmpty ? nil : trimmedMajor,
            gender: profile.gender.rawValue.lowercased(),
            hobbies: hobbies.isEmpty ? nil : hobbies,
            optInTailored: profile.optIn,
            translationPreference: selectedTranslation.rawValue,
            checkInTimes: nil,  // TODO: Add UI for custom check-in times
            timezone: timezone
        )

        do {
            try await apiClient.updateUserProfile(payload)
        } catch {
            #if DEBUG
            print("[AppState] Failed to sync profile: \(error)")
            #endif
        }
    }

    private func ageRangeString(for age: Int?) -> String? {
        guard let age else { return nil }
        switch age {
        case ..<18: return nil // Under 18 not supported
        case 18...24: return "18-24"
        case 25...34: return "25-34"
        case 35...44: return "35-44"
        case 45...54: return "45-54"
        case 55...64: return "55-64"
        default: return "65+"
        }
    }
    // MARK: - Mood Tracking Methods

    var currentCheckInType: CheckInType? {
        guard let pending = currentMoodStatus?.pendingCheckIn else { return nil }
        // Trust the backend's check-in type determination. The backend computes
        // the correct type based on the user's timezone and custom check-in times,
        // so no client-side time-window filtering is needed.
        return CheckInType(rawValue: pending.checkInType)
    }

    func loadMoodStatus() async {
        guard isAuthenticated else { return }

        do {
            let status = try await apiClient.fetchMoodStatus()
            await MainActor.run {
                currentMoodStatus = status
            }
        } catch {
            #if DEBUG
            print("[AppState] Failed to load mood status: \(error)")
            #endif
        }
    }

    func submitMoodCheckIn(_ request: MoodCheckInRequest) async throws -> MoodCheckInResponse {
        guard isAuthenticated else {
            throw MoodError.notAuthenticated
        }

        let response = try await apiClient.submitMoodCheckIn(request)
        await MainActor.run {
            latestMoodResponse = response
            Task {
                await loadMoodStatus()
            }
        }
        return response
    }

    func loadMoodHistory(days: Int = 7) async throws -> MoodHistoryResponse {
        guard isAuthenticated else { throw MoodError.notAuthenticated }

        return try await apiClient.fetchMoodHistory(days: days)
    }

    func clearMoodState() {
        currentMoodStatus = nil
        latestMoodResponse = nil
    }

    enum MoodError: LocalizedError {
        case notAuthenticated

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "Please sign in to track your mood."
            }
        }
    }
}

extension AppState {
    enum StorageKey {
        static let onboardingCompleted = "walkworthy.onboardingCompleted"
        static let useProfilePersonalization = "walkworthy.settings.useProfilePersonalization"
        static let translation = "walkworthy.settings.translation"
        static let profileAge = "walkworthy.profile.age"
        static let profileMajor = "walkworthy.profile.major"
        static let profileOccupation = "walkworthy.profile.occupation"
        static let profileGender = "walkworthy.profile.gender"
        static let profileHobbies = "walkworthy.profile.hobbies"
        static let profileOptIn = "walkworthy.profile.optIn"
        static let lastAuthenticatedUser = "walkworthy.auth.lastUser"
    }
}
