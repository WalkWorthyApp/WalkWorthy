//
//  AppState.swift
//  WalkWorthy
//
//  Central application state for the live WalkWorthy experience.
//

import Foundation
import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var verseDeck: [Verse]
    @Published private(set) var history: [Verse]
    @Published private(set) var currentVerseIndex: Int
    @Published var selectedTranslation: Translation
    @Published var showPopups: Bool
    @Published var onboardingCompleted: Bool
    @Published var useProfilePersonalization: Bool
    @Published private(set) var authenticatedUserSub: String?
    @Published var isAuthenticated: Bool {
        didSet {
            if !isAuthenticated {
                latestScanSummary = nil
                encouragementStatusMessage = nil
                latestScanError = nil
                hasFreshEncouragement = true
                clearMoodState()
            }
        }
    }
    @Published var isScanning: Bool
    @Published var latestScanSummary: ScanLogSummary?
    @Published var latestScanError: String?
    @Published var encouragementStatusMessage: String?
    @Published var hasFreshEncouragement: Bool
    @Published var authenticationNotice: String?

    // MARK: - Mood Tracking State
    @Published var currentMoodStatus: MoodStatusResponse?
    @Published var moodHistory: [DailyMoodSummary] = []
    @Published var latestMoodResponse: MoodCheckInResponse?
    @Published var isSubmittingMood: Bool = false
    @Published var moodError: String?

    private(set) var apiClient: any EncouragementAPI
    private let notificationScheduler: NotificationScheduler
    private let defaults: UserDefaults
    private let config: Config
    private let authSession: FirebaseAuthSession
    private static let userScopedKeys: Set<String> = [
        StorageKey.onboardingCompleted,
        StorageKey.useProfilePersonalization,
        StorageKey.translation,
        StorageKey.currentVerseIndex,
        StorageKey.history,
        StorageKey.verseDeck,
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
        self.verseDeck = []
        self.history = []
        self.currentVerseIndex = 0
        self.selectedTranslation = resolvedConfig.defaultTranslation
        self.showPopups = false
        self.authenticatedUserSub = nil
        self.useProfilePersonalization = true
        self.onboardingCompleted = false
        self.isScanning = false
        self.latestScanSummary = nil
        self.latestScanError = nil
        self.encouragementStatusMessage = nil
        self.hasFreshEncouragement = true

        reloadUserScopedPreferences()
        ensurePlaceholderIfNeeded()
        persistVerseDeck()

        if !onboardingCompleted {
            isAuthenticated = false
            Task {
                try? await authSession.signOut()
            }
        }
    }

    var currentVerse: Verse {
        verseDeck[safe: currentVerseIndex] ?? verseDeck.first ?? Verse.placeholder
    }

    var encouragementCarousel: [Verse] {
        var seen = Set<Verse>()
        var ordered: [Verse] = []

        if let current = verseDeck[safe: currentVerseIndex] {
            if seen.insert(current).inserted {
                ordered.append(current)
            }
        }

        for verse in history where seen.insert(verse).inserted {
            ordered.append(verse)
        }

        for verse in verseDeck where seen.insert(verse).inserted {
            ordered.append(verse)
        }

        return ordered.isEmpty ? [Verse.placeholder] : ordered
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

    func presentPopups() {
        showPopups = true
    }

    func dismissPopups() {
        showPopups = false
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
            // Delegate to injected authSession for dependency injection and testability
            try await authSession.signIn(email: email, password: password)
            isAuthenticated = true
            authenticationNotice = nil
            await refreshAuthenticatedUser()
        } catch {
            isAuthenticated = false
            authenticationNotice = error.localizedDescription
            setAuthenticatedUserSub(nil)
            throw error
        }
    }

    func createAccount(email: String, password: String) async throws {
        do {
            // Delegate to injected authSession for dependency injection and testability
            try await authSession.createAccount(email: email, password: password)
            isAuthenticated = true
            authenticationNotice = nil
            await refreshAuthenticatedUser()
        } catch {
            isAuthenticated = false
            authenticationNotice = error.localizedDescription
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
                latestScanSummary = nil
                encouragementStatusMessage = nil
                latestScanError = nil
                setAuthenticatedUserSub(nil)
            }
        }
    }

    var requiresAuthenticationGate: Bool {
        !isAuthenticated
    }

    func clearHistory() {
        history.removeAll()
        defaults.removeObject(forKey: storageKey(StorageKey.history))
        persistVerseDeck()
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
            currentVerseIndex = 0
            history = []
            verseDeck = [Verse.placeholder]
            persistVerseDeck()
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
        currentVerseIndex = defaults.integer(forKey: storageKey(StorageKey.currentVerseIndex))
        history = (try? defaults.decode([Verse].self, forKey: storageKey(StorageKey.history))) ?? []
        verseDeck = loadStoredVerseDeck()
        clampCurrentIndex()
        ensurePlaceholderIfNeeded()
        persistVerseDeck()
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

    private func historyUpsert(_ verse: Verse) {
        if let existingIndex = history.firstIndex(of: verse) {
            history.remove(at: existingIndex)
        }
        history.insert(verse, at: 0)
        try? defaults.encode(history, forKey: storageKey(StorageKey.history))
    }

    private func sanitizeVerseDeck(_ deck: [Verse]) -> [Verse] {
        var seen = Set<String>()
        var ordered: [Verse] = []
        for verse in deck {
            if seen.insert(verse.id).inserted {
                ordered.append(verse)
            }
        }
        if ordered.count > 1 {
            ordered.removeAll { $0.id == Verse.placeholder.id }
        }
        return ordered.isEmpty ? [Verse.placeholder] : ordered
    }

    private func loadStoredVerseDeck() -> [Verse] {
        if let stored = try? defaults.decode([Verse].self, forKey: storageKey(StorageKey.verseDeck)), !stored.isEmpty {
            return sanitizeVerseDeck(stored)
        }
        if !history.isEmpty {
            return sanitizeVerseDeck(history)
        }
        return [Verse.placeholder]
    }

    private func upsertVerse(_ verse: Verse) {
        if let existing = verseDeck.firstIndex(of: verse) {
            verseDeck.remove(at: existing)
        }
        verseDeck.insert(verse, at: 0)
        if verseDeck.count > 1 {
            verseDeck.removeAll { $0.id == Verse.placeholder.id }
        }
        currentVerseIndex = 0
        historyUpsert(verse)
        persistVerseDeck()
    }

    private func ensurePlaceholderIfNeeded() {
        if verseDeck.isEmpty {
            verseDeck = [Verse.placeholder]
        }
        if verseDeck.count > 1 {
            verseDeck.removeAll { $0.id == Verse.placeholder.id }
        }
    }

    private func ensureDeckBackedByHistory() {
        if verseDeck.count <= 1 && !history.isEmpty {
            var combined: [Verse] = []
            if let current = verseDeck[safe: currentVerseIndex] {
                combined.append(current)
            }
            combined.append(contentsOf: history)
            verseDeck = sanitizeVerseDeck(combined)
            clampCurrentIndex()
        }
    }

    private func persistVerseDeck() {
        ensurePlaceholderIfNeeded()
        clampCurrentIndex()
        defaults.set(currentVerseIndex, forKey: storageKey(StorageKey.currentVerseIndex))
        try? defaults.encode(verseDeck, forKey: storageKey(StorageKey.verseDeck))
    }

    private func clampCurrentIndex() {
        guard !verseDeck.isEmpty else {
            currentVerseIndex = 0
            return
        }
        currentVerseIndex = currentVerseIndex.clamped(to: 0..<(verseDeck.count))
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
            print("[AppState] Failed to sync profile: \(error)")
        }
    }

    private func statusMessage(forMetadata metadata: ScanLogSummary?) -> String? {
        guard let metadata else {
            return "Fresh encouragement delivered."
        }
        switch metadata.status {
        case .success:
            return "Fresh encouragement delivered from today's scan."
        case .fallback:
            if let reason = metadata.errorMessage, !reason.isEmpty {
                return "Fallback encouragement delivered: \(reason)"
            }
            return "Fallback encouragement delivered from your backup verses."
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
        // Determine if there's a pending check-in for this time window
        if let pending = currentMoodStatus?.pendingCheckIn {
            let checkInType = CheckInType(rawValue: pending.checkInType) ?? .morning
            let hour = Calendar.current.component(.hour, from: Date())

            switch checkInType {
            case .morning where (5..<12).contains(hour):
                return .morning
            case .midday where (12..<17).contains(hour):
                return .midday
            case .evening where (17..<22).contains(hour):
                return .evening
            default:
                return nil
            }
        }

        return nil
    }

    var hasAvailableCheckIn: Bool {
        currentCheckInType != nil
    }

    func loadMoodStatus() async {
        guard isAuthenticated else { return }

        do {
            let status = try await apiClient.fetchMoodStatus()
            await MainActor.run {
                currentMoodStatus = status
            }
        } catch {
            print("[AppState] Failed to load mood status: \(error)")
        }
    }

    func submitMoodCheckIn(_ request: MoodCheckInRequest) async throws -> MoodCheckInResponse {
        guard isAuthenticated else {
            throw MoodError.notAuthenticated
        }

        await MainActor.run {
            isSubmittingMood = true
            moodError = nil
        }

        do {
            let response = try await apiClient.submitMoodCheckIn(request)
            await MainActor.run {
                latestMoodResponse = response
                isSubmittingMood = false
                // Refresh mood status to get the updated check-in
                Task {
                    await loadMoodStatus()
                }
            }
            return response
        } catch {
            await MainActor.run {
                isSubmittingMood = false
                moodError = error.localizedDescription
            }
            throw error
        }
    }

    func loadMoodHistory(days: Int = 7) async {
        guard isAuthenticated else { return }

        do {
            let response = try await apiClient.fetchMoodHistory(days: days)
            await MainActor.run {
                moodHistory = response.summaries
            }
        } catch {
            print("[AppState] Failed to load mood history: \(error)")
        }
    }

    func clearMoodState() {
        currentMoodStatus = nil
        moodHistory = []
        latestMoodResponse = nil
        moodError = nil
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
        static let currentVerseIndex = "walkworthy.home.currentVerseIndex"
        static let history = "walkworthy.history.verses"
        static let verseDeck = "walkworthy.home.verseDeck"
        static let profileAge = "walkworthy.profile.age"
        static let profileMajor = "walkworthy.profile.major"
        static let profileOccupation = "walkworthy.profile.occupation"
        static let profileGender = "walkworthy.profile.gender"
        static let profileHobbies = "walkworthy.profile.hobbies"
        static let profileOptIn = "walkworthy.profile.optIn"
        static let lastAuthenticatedUser = "walkworthy.auth.lastUser"
    }
}

private extension UserDefaults {
    func encode<T: Encodable>(_ value: T, forKey key: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        set(data, forKey: key)
    }

    func decode<T: Decodable>(_ type: T.Type = T.self, forKey key: String) throws -> T {
        guard let data = data(forKey: key) else {
            throw DecodingError.valueNotFound(type, .init(codingPath: [], debugDescription: "No data for key \(key)"))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}

private extension Int {
    func clamped(to range: Range<Int>) -> Int {
        guard !range.isEmpty else { return 0 }
        if self < range.lowerBound { return range.lowerBound }
        if self >= range.upperBound { return range.upperBound - 1 }
        return self
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
