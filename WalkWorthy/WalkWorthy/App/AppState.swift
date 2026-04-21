//
//  AppState.swift
//  WalkWorthy
//
//  Central application state for the live WalkWorthy experience.
//

import Foundation
import SwiftUI
import Combine
import SwiftData

@MainActor
final class AppState: ObservableObject {
    @Published var selectedTranslation: Translation
    @Published var onboardingCompleted: Bool
    @Published var useProfilePersonalization: Bool
    /// Mirrors the UserDefaults-backed profile for SwiftUI-observable access
    /// (HomeView greeting + tone-aware subtitle). Nil before sign-in / after sign-out.
    @Published private(set) var currentProfile: OnboardingProfile?
    /// User has dismissed the "add your first name" prompt on Home. Scoped per user.
    @Published private(set) var nameBackfillDismissed: Bool = false
    @Published private(set) var authenticatedUserSub: String?
    @Published var isAuthenticated: Bool {
        didSet {
            if !isAuthenticated {
                clearMoodState()
                clearJournalState()
            }
        }
    }
    @Published var authenticationNotice: String?
    @Published var isCheckingAuth: Bool = true
    /// Non-nil when app startup failed to load a valid configuration
    /// (e.g. missing API base URL, SwiftData store creation failed).
    /// When set, `RootView` shows `ConfigurationErrorView` and blocks all other UI.
    ///
    /// `private(set)` so only `markConfigurationError(_:)` (called at startup from
    /// `WalkWorthyApp.init`) can assign it — prevents unrelated code from
    /// accidentally blanking the app UI later.
    @Published private(set) var configurationError: String?

    // MARK: - Mood Tracking State
    @Published var currentMoodStatus: MoodStatusResponse?
    @Published var latestMoodResponse: MoodCheckInResponse?
    @Published var dailyReflection: DailyReflection?

    // MARK: - Journal State
    @Published var journalEntries: [JournalEntry] = []

    private let apiClient: any EncouragementAPI
    private let notificationScheduler: NotificationScheduler
    private let defaults: UserDefaults
    private let config: Config
    private let authSession: FirebaseAuthSession
    private var isObservingAuth = false
    private var reflectionFetchTask: Task<Void, Never>?
    private let modelContainer: ModelContainer
    private var modelContext: ModelContext { modelContainer.mainContext }
    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let reflectionDecoder = JSONDecoder()
    private static let reflectionEncoder = JSONEncoder()
    private static let userScopedKeys: Set<String> = [
        StorageKey.onboardingCompleted,
        StorageKey.useProfilePersonalization,
        StorageKey.translation,
        StorageKey.profileFirstName,
        StorageKey.profileAge,
        StorageKey.profileMajor,
        StorageKey.profileOccupation,
        StorageKey.profileGender,
        StorageKey.profileHobbies,
        StorageKey.profileOptIn,
        StorageKey.dismissedNameBackfill,
    ]

    init(
        config: Config? = nil,
        apiClient: any EncouragementAPI,
        authSession: FirebaseAuthSession,
        notificationScheduler: NotificationScheduler? = nil,
        defaults: UserDefaults = .standard,
        modelContainer: ModelContainer
    ) {
        let resolvedConfig = config ?? Config.shared
        let resolvedScheduler = notificationScheduler ?? NotificationScheduler.shared

        self.config = resolvedConfig
        self.apiClient = apiClient
        self.authSession = authSession
        self.notificationScheduler = resolvedScheduler
        self.defaults = defaults
        self.modelContainer = modelContainer
        self.isAuthenticated = false
        self.selectedTranslation = resolvedConfig.defaultTranslation
        self.authenticatedUserSub = nil
        self.useProfilePersonalization = true
        self.onboardingCompleted = false

        reloadUserScopedPreferences()
    }

    func markOnboardingComplete() {
        onboardingCompleted = true
        defaults.set(true, forKey: storageKey(StorageKey.onboardingCompleted))
    }

    /// Sole setter for `configurationError`. Called once from `WalkWorthyApp.init`
    /// when startup fails to load a valid configuration (missing API base URL,
    /// SwiftData store creation failed, etc.). Keep this path narrow — the UI is
    /// fully blocked when this is set, so accidental assignments elsewhere would
    /// blank the entire app.
    func markConfigurationError(_ message: String?) {
        configurationError = message
    }

    /// Updates user profile data in both local storage and Firebase backend.
    ///
    /// Security Note: Profile data (age, occupation, major, gender, hobbies) is stored in UserDefaults
    /// as a local cache. This data is protected by iOS Data Protection, which encrypts UserDefaults
    /// when the device is locked. The authoritative copy is synced to Firebase with proper security rules.
    /// Authentication tokens use Keychain storage with kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly.
    func updateProfile(firstName: String, age: Int?, occupation: String, major: String, gender: Gender, hobbies: Set<String>, optIn: Bool) {
        let trimmedFirstName = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOccupation = occupation.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMajor = major.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedFirstName.isEmpty {
            defaults.removeObject(forKey: storageKey(StorageKey.profileFirstName))
        } else {
            defaults.set(trimmedFirstName, forKey: storageKey(StorageKey.profileFirstName))
        }
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

        // Refresh observable profile so Home greeting updates without a relaunch.
        currentProfile = OnboardingProfile(
            firstName: trimmedFirstName,
            age: age,
            occupation: trimmedOccupation,
            major: trimmedMajor,
            gender: gender,
            hobbies: hobbies,
            optIn: optIn
        )

        syncProfile(firstName: trimmedFirstName, age: age, occupation: trimmedOccupation, major: trimmedMajor, gender: gender, hobbies: hobbies, optIn: optIn)
    }

    func loadProfile() -> OnboardingProfile {
        if authenticatedUserSub == nil {
            return OnboardingProfile(firstName: "", age: nil, occupation: "", major: "", gender: .male, hobbies: [], optIn: true)
        }

        let firstName = defaults.string(forKey: storageKey(StorageKey.profileFirstName)) ?? ""
        let age = defaults.value(forKey: storageKey(StorageKey.profileAge)) as? Int
        let occupation = defaults.string(forKey: storageKey(StorageKey.profileOccupation)) ?? ""
        let major = defaults.string(forKey: storageKey(StorageKey.profileMajor)) ?? ""
        let gender = Gender(rawValue: defaults.string(forKey: storageKey(StorageKey.profileGender)) ?? "") ?? .male
        let hobbies = Set(defaults.stringArray(forKey: storageKey(StorageKey.profileHobbies)) ?? [])
        let optIn = defaults.object(forKey: storageKey(StorageKey.profileOptIn)) as? Bool ?? true
        return OnboardingProfile(firstName: firstName, age: age, occupation: occupation, major: major, gender: gender, hobbies: hobbies, optIn: optIn)
    }

    func setUseProfilePersonalization(_ isOn: Bool) {
        useProfilePersonalization = isOn
        defaults.set(isOn, forKey: storageKey(StorageKey.useProfilePersonalization))
    }

    /// Record the user's dismissal of the "add your first name" banner on Home.
    /// Scoped per-user; persists across app launches.
    func setNameBackfillDismissed(_ isDismissed: Bool) {
        nameBackfillDismissed = isDismissed
        defaults.set(isDismissed, forKey: storageKey(StorageKey.dismissedNameBackfill))
    }

    func startObservingAuthState() async {
        guard !isObservingAuth else { return }
        isObservingAuth = true
        await authSession.observeAuthState { [weak self] isSignedIn in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if isSignedIn {
                    self.isAuthenticated = true
                    self.authenticationNotice = nil
                    await self.refreshAuthenticatedUser()
                    self.checkAndFetchDailyReflection()
                } else {
                    self.isAuthenticated = false
                    self.setAuthenticatedUserSub(nil)
                }
                self.isCheckingAuth = false
            }
        }
        // Fallback: unblock UI if Firebase hasn't responded within 10 seconds.
        // Higher than Firebase's typical cold-start auth check to avoid a
        // TitleScreen flash on slow networks before the auth listener fires.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.isCheckingAuth else { return }
            self.isCheckingAuth = false
        }
    }

    func startSignIn(email: String, password: String) async throws {
        do {
            try await authSession.signIn(email: email, password: password)
            isAuthenticated = true
            authenticationNotice = nil
            await refreshAuthenticatedUser()
            checkAndFetchDailyReflection()
        } catch {
            isAuthenticated = false
            authenticationNotice = nil
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
            checkAndFetchDailyReflection()
        } catch {
            isAuthenticated = false
            authenticationNotice = nil
            setAuthenticatedUserSub(nil)
            throw error
        }
    }

    func signOut() {
        authenticationNotice = "You have been signed out. Please sign in again."
        Task {
            try? await authSession.signOut()
            // Listener fires and sets isAuthenticated = false, clears userSub
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
            currentProfile = nil
            nameBackfillDismissed = false
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

        // Hydrate observable profile mirror + banner-dismissed flag for this user
        currentProfile = hasStoredProfile() ? loadProfile() : nil
        nameBackfillDismissed = defaults.bool(forKey: storageKey(StorageKey.dismissedNameBackfill))
    }

    private func hasStoredProfile() -> Bool {
        if authenticatedUserSub == nil {
            return false
        }

        if defaults.object(forKey: storageKey(StorageKey.profileFirstName)) != nil { return true }
        if defaults.object(forKey: storageKey(StorageKey.profileAge)) != nil { return true }
        if defaults.object(forKey: storageKey(StorageKey.profileOccupation)) != nil { return true }
        if defaults.object(forKey: storageKey(StorageKey.profileMajor)) != nil { return true }
        if defaults.object(forKey: storageKey(StorageKey.profileGender)) != nil { return true }
        if defaults.object(forKey: storageKey(StorageKey.profileHobbies)) != nil { return true }
        if defaults.object(forKey: storageKey(StorageKey.profileOptIn)) != nil { return true }
        return false
    }

    private func syncProfile(firstName: String, age: Int?, occupation: String, major: String, gender: Gender, hobbies: Set<String>, optIn: Bool) {
        guard isAuthenticated else { return }
        let profile = OnboardingProfile(firstName: firstName, age: age, occupation: occupation, major: major, gender: gender, hobbies: hobbies, optIn: optIn)
        Task {
            await sendProfileUpdate(profile)
        }
    }

    private func sendProfileUpdate(_ profile: OnboardingProfile) async {
        guard isAuthenticated else { return }
        let trimmedFirstName = profile.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOccupation = profile.occupation.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMajor = profile.major.trimmingCharacters(in: .whitespacesAndNewlines)
        let hobbies = profile.hobbies.sorted()

        // Get user's timezone
        let timezone = TimeZone.current.identifier

        let payload = RemoteUserProfileRequest(
            ageRange: ageRangeString(for: profile.age),
            firstName: trimmedFirstName.isEmpty ? nil : trimmedFirstName,
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
        guard currentMoodStatus == nil else { return }

        do {
            let status = try await apiClient.fetchMoodStatus()
            currentMoodStatus = status
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
        latestMoodResponse = response
        currentMoodStatus = nil
        Task {
            await loadMoodStatus()
        }
        return response
    }

    func loadMoodHistory(days: Int = 7, startDate: String? = nil, endDate: String? = nil) async throws -> MoodHistoryResponse {
        guard isAuthenticated else { throw MoodError.notAuthenticated }

        return try await apiClient.fetchMoodHistory(days: days, startDate: startDate, endDate: endDate)
    }

    /// Fetch the full-fidelity mood check-in log (with moodSpectrumData + aiResponse)
    /// for the past `days` days. Powers the Settings → Check-in Log deep-dive.
    /// Pass `endDate` (YYYY-MM-DD) to page further back in time.
    func loadMoodLog(days: Int = 14, endDate: String? = nil) async throws -> MoodLogResponse {
        guard isAuthenticated else { throw MoodError.notAuthenticated }

        return try await apiClient.fetchMoodLogFullHistory(days: days, endDate: endDate)
    }

    func clearMoodState() {
        currentMoodStatus = nil
        latestMoodResponse = nil
        dailyReflection = nil
    }

    // MARK: - Journal

    func loadJournalEntries(date: String? = nil) {
        var descriptor = FetchDescriptor<JournalEntry>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        if let date {
            descriptor.predicate = #Predicate { $0.date == date }
        }
        journalEntries = (try? modelContext.fetch(descriptor)) ?? [] // silent failure: show empty list on store error
    }

    @discardableResult
    func createJournalEntry(
        text: String,
        linkedCheckInId: String? = nil,
        moodLevelRaw: String? = nil,
        moodScore: Int? = nil,
        emotionTags: [String] = []
    ) throws -> JournalEntry {
        let today = Self.isoDateFormatter.string(from: Date())
        let entry = JournalEntry(
            id: UUID().uuidString,
            text: text,
            date: today,
            linkedCheckInId: linkedCheckInId,
            createdAt: Date(),
            updatedAt: Date(),
            isPinned: false,
            moodLevelRaw: moodLevelRaw,
            moodScore: moodScore,
            emotionTags: emotionTags
        )
        modelContext.insert(entry)
        try modelContext.save()
        journalEntries.insert(entry, at: 0)
        return entry
    }

    func updateJournalEntry(id: String, text: String) throws {
        let descriptor = FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.id == id })
        guard let entry = try modelContext.fetch(descriptor).first else { return }
        entry.text = text
        entry.updatedAt = Date()
        try modelContext.save()
        if let index = journalEntries.firstIndex(where: { $0.id == id }) {
            journalEntries[index] = entry
        }
    }

    func deleteJournalEntry(id: String) throws {
        let descriptor = FetchDescriptor<JournalEntry>(predicate: #Predicate { $0.id == id })
        if let entry = try modelContext.fetch(descriptor).first {
            modelContext.delete(entry)
            try modelContext.save()
        }
        journalEntries.removeAll { $0.id == id }
    }

    func togglePin(_ entry: JournalEntry) {
        entry.isPinned.toggle()
        entry.updatedAt = Date()
        do {
            try modelContext.save()
        } catch {
            // Non-blocking: revert on failure so UI state matches persisted state
            entry.isPinned.toggle()
        }
    }

    func clearJournalState() {
        // Clears the in-memory list only — SwiftData store is device-local and persists across sign-outs.
        // Journal entries are not user-scoped; a fresh loadJournalEntries() after sign-in restores them.
        journalEntries = []
    }

    private func dailyReflectionCacheKey(for date: String) -> String {
        guard let userSub = authenticatedUserSub else { return "" }
        return "\(StorageKey.dailyReflectionPrefix)::\(userSub)::\(date)"
    }

    private func loadCachedReflection(for date: String) -> DailyReflection? {
        let key = dailyReflectionCacheKey(for: date)
        guard !key.isEmpty,
              let data = defaults.data(forKey: key),
              let reflection = try? Self.reflectionDecoder.decode(DailyReflection.self, from: data)
        else { return nil }
        return reflection
    }

    private func cacheReflection(_ reflection: DailyReflection) {
        let key = dailyReflectionCacheKey(for: reflection.date)
        guard !key.isEmpty,
              let data = try? Self.reflectionEncoder.encode(reflection)
        else { return }
        defaults.set(data, forKey: key)
    }

    private static func logicalDate() -> Date {
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour < 3 else { return Date() }
        return Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    }

    func checkAndFetchDailyReflection() {
        guard isAuthenticated else { return }
        let today = Self.isoDateFormatter.string(from: Self.logicalDate())
        if let cached = loadCachedReflection(for: today) {
            dailyReflection = cached
            return
        }
        reflectionFetchTask?.cancel()
        reflectionFetchTask = Task { @MainActor in
            do {
                let result = try await apiClient.fetchDailyReflection()
                self.dailyReflection = result
                self.cacheReflection(result)
            } catch {
                #if DEBUG
                print("[AppState] Daily reflection fetch failed: \(error)")
                #endif
            }
        }
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
        static let profileFirstName = "walkworthy.profile.firstName"
        static let profileAge = "walkworthy.profile.age"
        static let profileMajor = "walkworthy.profile.major"
        static let profileOccupation = "walkworthy.profile.occupation"
        static let profileGender = "walkworthy.profile.gender"
        static let profileHobbies = "walkworthy.profile.hobbies"
        static let profileOptIn = "walkworthy.profile.optIn"
        static let dismissedNameBackfill = "walkworthy.dismissed.nameBackfill"
        static let lastAuthenticatedUser = "walkworthy.auth.lastUser"
        static let dailyReflectionPrefix = "walkworthy.dailyReflection"
    }
}
