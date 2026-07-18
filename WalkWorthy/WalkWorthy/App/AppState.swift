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
import UserNotifications
import FirebaseAnalytics
import FirebaseCrashlytics

@MainActor
final class AppState: ObservableObject {
    @Published var selectedTranslation: Translation
    @Published var onboardingCompleted: Bool
    @Published var useProfilePersonalization: Bool
    /// User has seen the AI data-sharing consent screen and tapped Continue.
    /// Required by App Review Guideline 5.1.2(i): mood data goes to OpenAI, so
    /// the app must obtain explicit in-app consent before the first AI call.
    /// Scoped per user; false blocks mood check-in AI + daily reflection fetch.
    @Published private(set) var aiConsentGiven: Bool = false
    /// Firebase Analytics collection toggle. Collection is disabled in
    /// Info.plist (FIREBASE_ANALYTICS_COLLECTION_ENABLED = NO) and only turned
    /// on at runtime once consent is given AND this flag is true, so no events
    /// are collected before the user has seen the disclosure.
    @Published private(set) var analyticsEnabled: Bool = true
    /// In-memory mirror of the backend profile for SwiftUI-observable access
    /// (HomeView greeting + tone-aware subtitle). Hydrated via
    /// `refreshProfileFromBackend()` at sign-in; nil before sign-in / after
    /// sign-out. No longer persisted to UserDefaults — backend is authoritative.
    @Published private(set) var currentProfile: OnboardingProfile?
    /// User has dismissed the "add your first name" prompt on Home. Scoped per user.
    @Published private(set) var nameBackfillDismissed: Bool = false
    /// Minimal, non-PII signal that the user has previously completed profile
    /// setup with a non-empty first name. Persisted per-user in UserDefaults so
    /// the NameBackfillBanner doesn't re-appear on a cold-launch-while-offline
    /// where `currentProfile` is nil until the backend fetch resolves. This
    /// stores NO PII — only a boolean. Cleared on sign-out.
    @Published private(set) var hasCompletedProfileSetup: Bool = false
    @Published private(set) var authenticatedUserSub: String?
    /// True while the signed-in email/password account hasn't verified its
    /// address. RootView blocks the main UI with EmailVerificationView and
    /// the backend independently rejects unverified tokens with 403
    /// EMAIL_UNVERIFIED. Always false for Sign in with Apple accounts.
    @Published private(set) var needsEmailVerification: Bool = false
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
    /// Surfaced to the UI when a SwiftData save/fetch fails. Views present an alert
    /// bound to this string and set it back to `nil` on dismiss. Replaces the
    /// previous pattern of silent `try?` failures that lost data without signal.
    @Published var journalError: String?

    private let apiClient: any EncouragementAPI
    private let defaults: UserDefaults
    private let config: Config
    private let authSession: FirebaseAuthSession
    private var isObservingAuth = false
    private var reflectionFetchTask: Task<Void, Never>?
    /// Debounced profile PATCH. Cancelled on each `syncProfile` call and on
    /// sign-out so rapid edits collapse into a single network round-trip and
    /// stale writes never land after the user has signed out.
    private var profileSyncTask: Task<Void, Never>?
    /// Tracks the in-flight Firebase sign-out so rapid taps on the Sign Out
    /// button don't stack multiple concurrent sign-out calls against the auth
    /// actor. Each new sign-out cancels any prior in-flight task.
    private var signOutTask: Task<Void, Never>?
    /// Timestamp of the last successful mood-status fetch. Used by
    /// `loadMoodStatus()` to throttle redundant fetches while
    /// still honoring the ScenePhase.active trigger after the staleness
    /// window elapses.
    private var lastMoodStatusFetch: Date?
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
        StorageKey.aiConsentGiven,
        StorageKey.analyticsEnabled,
        StorageKey.translation,
        StorageKey.dismissedNameBackfill,
        StorageKey.hasCompletedProfileSetup,
    ]

    init(
        config: Config? = nil,
        apiClient: any EncouragementAPI,
        authSession: FirebaseAuthSession,
        defaults: UserDefaults = .standard,
        modelContainer: ModelContainer
    ) {
        let resolvedConfig = config ?? Config.shared

        self.config = resolvedConfig
        self.apiClient = apiClient
        self.authSession = authSession
        self.defaults = defaults
        self.modelContainer = modelContainer
        self.isAuthenticated = false
        self.selectedTranslation = resolvedConfig.defaultTranslation
        self.authenticatedUserSub = nil
        self.useProfilePersonalization = true
        self.onboardingCompleted = false

        reloadUserScopedPreferences()

        #if DEBUG
        Task.detached { await SnapshotStore.runSelfCheck() }
        #endif
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

    /// Updates user profile data in memory and syncs to the Firebase backend.
    ///
    /// Profile PII (age, occupation, major, gender, hobbies, first name) is
    /// never persisted in UserDefaults — the authoritative copy lives on the
    /// backend and is fetched into `currentProfile` at sign-in. UserDefaults
    /// plists inherit `NSFileProtectionCompleteUntilFirstUserAuthentication`
    /// and are readable from unencrypted iTunes backups; keeping PII out of
    /// them removes that exposure without a Keychain migration.
    func updateProfile(firstName: String, age: Int?, occupation: String, major: String, gender: Gender, hobbies: Set<String>, optIn: Bool) {
        let trimmedFirstName = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOccupation = occupation.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMajor = major.trimmingCharacters(in: .whitespacesAndNewlines)

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

        // Flip the "setup complete" flag so the Home name banner stops showing
        // on offline cold-launches. Only set it when the user actually supplied
        // a non-empty first name — an empty value means they haven't completed
        // the backfill yet.
        if !trimmedFirstName.isEmpty {
            setHasCompletedProfileSetup(true)
        }

        syncProfile(firstName: trimmedFirstName, age: age, occupation: trimmedOccupation, major: trimmedMajor, gender: gender, hobbies: hobbies, optIn: optIn)
    }

    /// Returns the current observable profile, or an empty profile for the
    /// pre-sign-in / pre-fetch state. Callers that need the authoritative
    /// copy from the backend should await `refreshProfileFromBackend()`.
    func loadProfile() -> OnboardingProfile {
        currentProfile ?? OnboardingProfile(
            firstName: "",
            age: nil,
            occupation: "",
            major: "",
            gender: .male,
            hobbies: [],
            optIn: true
        )
    }

    /// Fetch the authoritative user profile from the backend and hydrate
    /// `currentProfile`. Failure is non-fatal — on network issues the user
    /// sees the last in-memory value (nil on a cold launch). Called at
    /// sign-in and after auth state changes.
    func refreshProfileFromBackend() async {
        guard isAuthenticated else { return }
        do {
            let response = try await apiClient.fetchUserProfile()
            if let response {
                let profile = Self.profile(from: response)
                currentProfile = profile
                // Record the minimal "setup complete" flag so the
                // NameBackfillBanner gate survives offline cold-launches.
                let trimmedFirstName = profile.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedFirstName.isEmpty {
                    setHasCompletedProfileSetup(true)
                }
            } else {
                currentProfile = nil
            }
        } catch {
            #if DEBUG
            print("[AppState] Failed to fetch profile from backend: \(error)")
            #endif
        }
    }

    /// Maps an `age range` bucket (e.g. "25-34") to the midpoint so the
    /// onboarding form has something sensible to render. The numeric age
    /// entered at onboarding isn't persisted on the backend — only the
    /// bucket is — so this is a lossy round-trip by design.
    private static func profile(from response: RemoteUserProfileResponse) -> OnboardingProfile {
        let age: Int? = {
            guard let bucket = response.ageRange else { return nil }
            switch bucket {
            case "18-24": return 21
            case "25-34": return 30
            case "35-44": return 40
            case "45-54": return 50
            case "55-64": return 60
            case "65+": return 65
            default: return nil
            }
        }()

        // Map the backend's gender string to the local enum. Match both known
        // values explicitly — the previous `default: .male` silently coerced
        // unknown/missing values to male, which misrepresents users who never
        // set a gender and would misrepresent any future backend-side addition
        // (e.g. a third option). We can't add an "unknown" enum case without
        // reshaping the onboarding picker UI, so preserve the OnboardingProfile
        // contract (Gender is non-optional) by falling back to the picker's
        // default seed value (`.male`) only when the backend value is truly
        // absent, and log unknown string values in DEBUG so we notice drift.
        let gender: Gender
        switch response.gender?.lowercased() {
        case "female":
            gender = .female
        case "male":
            gender = .male
        case .none:
            // No value persisted on the backend yet — the user hasn't completed
            // gender selection. Use the form's default seed so the picker
            // renders without crashing; the user will pick explicitly on first
            // edit.
            gender = .male
        case .some(let raw):
            #if DEBUG
            print("[AppState] Unknown gender value from backend: \(raw); defaulting to .male")
            #endif
            gender = .male
        }

        return OnboardingProfile(
            firstName: response.firstName ?? "",
            age: age,
            occupation: response.occupation ?? "",
            major: response.major ?? "",
            gender: gender,
            hobbies: Set(response.hobbies ?? []),
            optIn: response.optInTailored ?? true
        )
    }

    func setUseProfilePersonalization(_ isOn: Bool) {
        useProfilePersonalization = isOn
        defaults.set(isOn, forKey: storageKey(StorageKey.useProfilePersonalization))
    }

    /// Records the user's explicit consent to AI data sharing (App Review
    /// Guideline 5.1.2(i)) after they've seen `AIConsentView`, and applies the
    /// analytics preference disclosed on the same screen.
    func setAIConsentGiven(_ given: Bool) {
        aiConsentGiven = given
        defaults.set(given, forKey: storageKey(StorageKey.aiConsentGiven))
        applyAnalyticsCollectionState()
        // The reflection fetch was blocked pre-consent; populate Home now.
        if given {
            checkAndFetchDailyReflection()
        }
    }

    func setAnalyticsEnabled(_ isOn: Bool) {
        analyticsEnabled = isOn
        defaults.set(isOn, forKey: storageKey(StorageKey.analyticsEnabled))
        applyAnalyticsCollectionState()
    }

    /// Collection stays off (Info.plist FIREBASE_ANALYTICS_COLLECTION_ENABLED
    /// = NO) until the user has seen the consent screen AND left analytics on —
    /// no events are ever collected pre-consent.
    private func applyAnalyticsCollectionState() {
        Analytics.setAnalyticsCollectionEnabled(aiConsentGiven && analyticsEnabled)
    }

    /// Record the user's dismissal of the "add your first name" banner on Home.
    /// Scoped per-user; persists across app launches.
    func setNameBackfillDismissed(_ isDismissed: Bool) {
        nameBackfillDismissed = isDismissed
        defaults.set(isDismissed, forKey: storageKey(StorageKey.dismissedNameBackfill))
    }

    /// Persists the minimal non-PII signal that the user has completed profile
    /// setup with a non-empty first name. Used by the Home `NameBackfillBanner`
    /// gate so a cold-launch-while-offline doesn't re-prompt users who already
    /// set their name. Scoped per user; no PII stored — only a boolean.
    private func setHasCompletedProfileSetup(_ completed: Bool) {
        hasCompletedProfileSetup = completed
        defaults.set(completed, forKey: storageKey(StorageKey.hasCompletedProfileSetup))
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
                    // Load UID + user-scoped prefs (onboardingCompleted, translation,
                    // etc). No network — reads Auth.auth().currentUser.uid + UserDefaults.
                    await self.refreshAuthenticatedUser()
                    self.needsEmailVerification = await self.authSession.needsEmailVerification(reload: false)
                    // Fast path: returning user who's completed onboarding. UI can
                    // render MainTabView immediately using cached prefs; profile +
                    // daily reflection hydrate in the background so the splash
                    // doesn't block on network round-trips.
                    if self.onboardingCompleted {
                        self.isCheckingAuth = false
                        Task { @MainActor [weak self] in
                            guard let self else { return }
                            await self.refreshProfileFromBackend()
                            self.checkAndFetchDailyReflection()
                        }
                        return
                    }
                    // Slow path: first sign-in or cleared app data. Need the
                    // backend profile to decide onboarding vs. main app; blocking
                    // here prevents an OnboardingForm flash for returning users
                    // whose scoped pref is missing.
                    await self.refreshProfileFromBackend()
                    if self.currentProfile != nil {
                        self.markOnboardingComplete()
                    }
                    self.checkAndFetchDailyReflection()
                } else {
                    self.isAuthenticated = false
                    self.needsEmailVerification = false
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
            Analytics.logEvent(AnalyticsEventLogin, parameters: [AnalyticsParameterMethod: "password"])
            await refreshAuthenticatedUser()
            needsEmailVerification = await authSession.needsEmailVerification(reload: false)
            await refreshProfileFromBackend()
            if currentProfile != nil {
                markOnboardingComplete()
            }
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
            Analytics.logEvent(AnalyticsEventSignUp, parameters: [AnalyticsParameterMethod: "password"])
            await refreshAuthenticatedUser()
            // New password accounts must verify their address before using
            // the app (RootView gate + backend 403). Send the email now;
            // failures aren't fatal — the gate screen offers a resend.
            do {
                try await authSession.sendEmailVerification()
            } catch {
                #if DEBUG
                print("[AppState] sendEmailVerification failed: \(error)")
                #else
                Crashlytics.crashlytics().record(error: error)
                #endif
            }
            needsEmailVerification = await authSession.needsEmailVerification(reload: false)
            await refreshProfileFromBackend()
            checkAndFetchDailyReflection()
        } catch {
            isAuthenticated = false
            authenticationNotice = nil
            setAuthenticatedUserSub(nil)
            throw error
        }
    }

    /// Bridges an Apple identity token + raw nonce into a Firebase session.
    /// Mirrors the post-sign-in state sync done in `startSignIn`: profile
    /// hydrate, onboarding completion check, daily reflection prefetch.
    /// Errors propagate unchanged so the view layer can route them through
    /// `FirebaseAuthErrorMapper` just like email/password.
    ///
    /// Required for App Store Guideline 4.8 — apps offering third-party or
    /// email login must also offer Sign in with Apple.
    func signInWithApple(idToken: String,
                         rawNonce: String,
                         fullName: PersonNameComponents?) async throws {
        do {
            try await authSession.signInWithApple(idToken: idToken,
                                                  rawNonce: rawNonce,
                                                  fullName: fullName)
            isAuthenticated = true
            authenticationNotice = nil
            Analytics.logEvent(AnalyticsEventLogin, parameters: [AnalyticsParameterMethod: "apple"])
            await refreshAuthenticatedUser()
            await refreshProfileFromBackend()
            if currentProfile != nil {
                markOnboardingComplete()
            }
            checkAndFetchDailyReflection()
        } catch {
            isAuthenticated = false
            authenticationNotice = nil
            setAuthenticatedUserSub(nil)
            throw error
        }
    }

    /// Firebase requires a recent sign-in (within ~5 minutes) before it will
    /// allow `user.delete()`. The backend account-deletion endpoint performs
    /// the Firebase Auth teardown server-side via the Admin SDK (which isn't
    /// subject to that window), but a stale client session also means the
    /// bearer token in the `Authorization` header can be older than the
    /// freshness window the backend enforces. Prompt the user to re-enter
    /// their password whenever the last sign-in was more than 5 minutes ago.
    private static let reauthRequiredWindow: TimeInterval = 5 * 60

    /// Returns `true` if the user must re-enter their password before we hit
    /// the backend `deleteAccount` endpoint. Gated on the Firebase-reported
    /// `lastSignInDate`; a fresh sign-in / create-account flow skips the prompt.
    func accountDeletionRequiresReauth() async -> Bool {
        guard let seconds = await authSession.secondsSinceLastSignIn() else {
            // No metadata means we can't prove freshness — safer to prompt.
            return true
        }
        return seconds > Self.reauthRequiredWindow
    }

    /// Re-authenticates the signed-in user with their email + password. Called
    /// from the account-deletion re-auth sheet before `deleteAccount()`.
    /// Propagates Firebase Auth errors so the view can surface them via
    /// `FirebaseAuthErrorMapper`.
    func reauthenticate(password: String) async throws {
        try await authSession.reauthenticate(password: password)
    }

    /// Permanently deletes the authenticated user's account.
    ///
    /// Flow:
    ///   1. Call the backend — it deletes all Firestore data AND the Firebase
    ///      Auth user. On success the backend returns `{ deleted: true }`.
    ///   2. Proactively clear local state (journal entries, mood cache,
    ///      per-user UserDefaults) so the UI never flashes stale data in the
    ///      window between the backend response and the Firebase auth listener
    ///      firing with `user == nil`.
    ///   3. Firebase's `addStateDidChangeListener` observes the server-side
    ///      user deletion and flips `isAuthenticated` to false, which drives
    ///      the UI back to `TitleScreenView` via `RootView`.
    ///
    /// On backend failure this method throws and leaves local state untouched
    /// so the user can retry without losing their on-device journal entries.
    /// Required for App Store Guideline 5.1.1(v).
    func deleteAccount() async throws {
        // Capture the sub before the backend call so we can clean up its
        // scoped UserDefaults keys after — once the auth listener fires,
        // `authenticatedUserSub` becomes nil.
        let departingSub = authenticatedUserSub

        try await apiClient.deleteAccount()

        // Backend succeeded: wipe everything tied to the deleted account.
        // Journal entries live in SwiftData scoped by userSub — clearJournalState
        // already deletes the departing user's rows and any legacy empty-sub rows.
        clearJournalState()
        clearMoodState()

        // Remove per-user UserDefaults (onboarding flags, personalization toggle,
        // translation preference, dismissed-banner flags, cached reflections,
        // reminder prefs). The account is gone — these keys should not linger.
        if let sub = departingSub {
            removeUserScopedDefaults(for: sub)
        }

        // Cancel any in-flight sync tasks so a stale PATCH doesn't land after
        // the backend has deleted the user.
        reflectionFetchTask?.cancel()
        reflectionFetchTask = nil
        profileSyncTask?.cancel()
        profileSyncTask = nil

        // Wipe scheduled local notifications so the deleted account's reminder
        // times don't fire on the next sign-in from a different account.
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()

        configurationError = nil

        // The Firebase auth state listener (started in `startObservingAuthState`)
        // will fire asynchronously when the server-side user deletion reaches the
        // client, flipping `isAuthenticated = false` and routing the UI back to
        // the title screen. Don't loop waiting for it here — SwiftUI re-renders
        // the moment the `@Published` property changes.
    }

    /// Removes every UserDefaults key scoped to the given Firebase sub.
    /// Called after a successful account deletion so no trace of the deleted
    /// user's preferences remains on-device. Matches the scoping convention in
    /// `storageKey(_:)`: `"<baseKey>::<userSub>"`.
    private func removeUserScopedDefaults(for userSub: String) {
        let suffix = "::\(userSub)"
        for key in defaults.dictionaryRepresentation().keys where key.hasSuffix(suffix) {
            defaults.removeObject(forKey: key)
        }
        // Also clear the "last authenticated user" pointer so a subsequent
        // sign-in starts with a clean per-user slate.
        if defaults.string(forKey: StorageKey.lastAuthenticatedUser) == userSub {
            defaults.removeObject(forKey: StorageKey.lastAuthenticatedUser)
        }
    }

    func signOut() {
        authenticationNotice = "You have been signed out. Please sign in again."

        // Cancel any in-flight per-user work so stale writes can't land
        // after the user signs out. Each task honors cooperative
        // cancellation; nothing here blocks.
        reflectionFetchTask?.cancel()
        reflectionFetchTask = nil
        profileSyncTask?.cancel()
        profileSyncTask = nil

        // Drop the previous user's cached response data from memory so a
        // quick sign-in from another account never flashes the prior
        // user's reflection or mood summary.
        dailyReflection = nil
        latestMoodResponse = nil
        currentMoodStatus = nil
        lastMoodStatusFetch = nil

        // Remove all cached daily-reflection blobs for the outgoing user.
        // The keys are scoped by Firebase sub so they're user-specific;
        // clearing them eagerly prevents accidental reuse after a shared
        // device is handed to someone else.
        clearCachedReflectionsForCurrentUser()

        // Wipe any pending local reminders so the next account doesn't
        // inherit a stranger's notification schedule. The new user will
        // re-register their own from Settings → Check-in Reminders.
        UNUserNotificationCenter.current().removeAllPendingNotificationRequests()

        // Cancel any previous in-flight sign-out so stacked taps don't queue
        // duplicate `authSession.signOut()` calls.
        signOutTask?.cancel()
        signOutTask = Task { [weak self] in
            guard let self else { return }
            try? await self.authSession.signOut()
            // Listener fires and sets isAuthenticated = false, clears userSub
        }
    }

    var requiresAuthenticationGate: Bool {
        !isAuthenticated
    }

    /// Resends the verification email for the signed-in password account.
    func resendVerificationEmail() async throws {
        try await authSession.sendEmailVerification()
    }

    /// Email address of the signed-in user, for display on the verification
    /// gate. Not persisted anywhere client-side.
    func currentUserEmail() async -> String? {
        await authSession.currentUserEmail()
    }

    /// Re-checks verification after the user says they've clicked the link.
    /// On success, forces a bearer-token refresh so the next API call carries
    /// email_verified=true (the backend rejects stale unverified tokens).
    func refreshEmailVerificationStatus() async {
        needsEmailVerification = await authSession.needsEmailVerification(reload: true)
        if !needsEmailVerification {
            _ = try? await authSession.validBearerToken(forcingRefresh: true)
        }
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
            aiConsentGiven = false
            analyticsEnabled = true
            selectedTranslation = config.defaultTranslation
            currentProfile = nil
            nameBackfillDismissed = false
            hasCompletedProfileSetup = false
            applyAnalyticsCollectionState()
            return
        }

        onboardingCompleted = defaults.bool(forKey: storageKey(StorageKey.onboardingCompleted))
        useProfilePersonalization = defaults.object(forKey: storageKey(StorageKey.useProfilePersonalization)) as? Bool ?? true
        aiConsentGiven = defaults.bool(forKey: storageKey(StorageKey.aiConsentGiven))
        analyticsEnabled = defaults.object(forKey: storageKey(StorageKey.analyticsEnabled)) as? Bool ?? true
        applyAnalyticsCollectionState()
        selectedTranslation = Translation(rawValue: defaults.string(forKey: storageKey(StorageKey.translation)) ?? "") ?? config.defaultTranslation

        // Profile PII is no longer cached in UserDefaults — hydrate via
        // `refreshProfileFromBackend()` on sign-in. Leaving `currentProfile`
        // untouched here so a sub-change during an active session doesn't
        // blank out an in-memory value that was just populated.
        nameBackfillDismissed = defaults.bool(forKey: storageKey(StorageKey.dismissedNameBackfill))
        hasCompletedProfileSetup = defaults.bool(forKey: storageKey(StorageKey.hasCompletedProfileSetup))
    }

    private func syncProfile(firstName: String, age: Int?, occupation: String, major: String, gender: Gender, hobbies: Set<String>, optIn: Bool) {
        guard isAuthenticated else { return }
        let profile = OnboardingProfile(firstName: firstName, age: age, occupation: occupation, major: major, gender: gender, hobbies: hobbies, optIn: optIn)

        // Debounce: cancel any in-flight sync and schedule a new one after a
        // short delay. Rapid edits in the onboarding form (e.g. toggling
        // hobbies) now collapse into a single PATCH instead of racing
        // concurrent requests that can land out of order.
        profileSyncTask?.cancel()
        profileSyncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            if Task.isCancelled { return }
            await self?.sendProfileUpdate(profile)
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

    /// Maps a user-entered age to the backend `AgeRange` bucket used for
    /// personalization. The backend only supports 18+ buckets today, so
    /// onboarding-gated teens (13-17, per `OnboardingForm.minimumAge`) map
    /// to `nil` and the agents fall back to other profile fields
    /// (occupation/major/hobbies) for tone. This is personalization-only —
    /// auth/usage is gated separately in the onboarding form, not here.
    private func ageRangeString(for age: Int?) -> String? {
        guard let age else { return nil }
        switch age {
        case ..<18: return nil // 13-17 allowed (gated in onboarding); no teen bucket on backend.
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

    /// Minimum interval between mood-status fetches. Anything shorter is
    /// considered cache-fresh and skipped. 60s matches the feature's cadence
    /// (morning/midday/evening) without hammering the backend.
    private static let moodStatusStaleness: TimeInterval = 60

    func loadMoodStatus() async {
        guard isAuthenticated else { return }
        if let lastFetch = lastMoodStatusFetch,
           Date().timeIntervalSince(lastFetch) < Self.moodStatusStaleness {
            return
        }

        do {
            let status = try await apiClient.fetchMoodStatus()
            currentMoodStatus = status
            lastMoodStatusFetch = Date()
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
        // Invalidate the staleness window so the next `loadMoodStatus()` call
        // refetches instead of returning the now-outdated cached status.
        lastMoodStatusFetch = nil
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
        lastMoodStatusFetch = nil
    }

    // MARK: - Journal
    //
    // Per-user scoping: every fetch/write is filtered by `authenticatedUserSub`
    // so User B on a shared device cannot see User A's entries. Unauthenticated
    // callers see an empty list and writes throw `JournalError.notAuthenticated`.
    // See `JournalEntry.userSub` for the column-level rationale.

    /// Predicate helper: returns entries belonging to the currently authenticated user.
    /// Extracted into a constant so fetches and queries use one source of truth.
    private func journalPredicate(dateFilter: String? = nil) -> Predicate<JournalEntry>? {
        guard let sub = authenticatedUserSub else { return nil }
        if let date = dateFilter {
            return #Predicate { $0.userSub == sub && $0.date == date }
        }
        return #Predicate { $0.userSub == sub }
    }

    func loadJournalEntries(date: String? = nil) {
        guard authenticatedUserSub != nil else {
            journalEntries = []
            return
        }
        let descriptor = FetchDescriptor<JournalEntry>(
            predicate: journalPredicate(dateFilter: date),
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        do {
            journalEntries = try modelContext.fetch(descriptor)
        } catch {
            journalEntries = []
            journalError = "Couldn't load your journal entries. Please try again."
            #if DEBUG
            print("[AppState] loadJournalEntries failed: \(error)")
            #else
            Crashlytics.crashlytics().record(error: error)
            #endif
        }
    }

    @discardableResult
    func createJournalEntry(
        text: String,
        linkedCheckInId: String? = nil,
        moodLevelRaw: String? = nil,
        moodScore: Int? = nil,
        emotionTags: [String] = []
    ) throws -> JournalEntry {
        guard let sub = authenticatedUserSub else {
            throw JournalError.notAuthenticated
        }
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
            emotionTags: emotionTags,
            userSub: sub
        )
        modelContext.insert(entry)
        try modelContext.save()
        journalEntries.insert(entry, at: 0)
        // Count only — journal text never leaves the device.
        Analytics.logEvent("journal_entry_created", parameters: nil)
        return entry
    }

    func updateJournalEntry(id: String, text: String) throws {
        guard let sub = authenticatedUserSub else {
            throw JournalError.notAuthenticated
        }
        // Scope the fetch by id AND userSub so a forged id from another user
        // (e.g. after a cross-account switch) cannot mutate someone else's row.
        let descriptor = FetchDescriptor<JournalEntry>(
            predicate: #Predicate { $0.id == id && $0.userSub == sub }
        )
        guard let entry = try modelContext.fetch(descriptor).first else { return }
        entry.text = text
        entry.updatedAt = Date()
        try modelContext.save()
        if let index = journalEntries.firstIndex(where: { $0.id == id }) {
            journalEntries[index] = entry
        }
    }

    func deleteJournalEntry(id: String) throws {
        guard let sub = authenticatedUserSub else {
            throw JournalError.notAuthenticated
        }
        let descriptor = FetchDescriptor<JournalEntry>(
            predicate: #Predicate { $0.id == id && $0.userSub == sub }
        )
        if let entry = try modelContext.fetch(descriptor).first {
            modelContext.delete(entry)
            try modelContext.save()
        }
        journalEntries.removeAll { $0.id == id }
    }

    func togglePin(_ entry: JournalEntry) {
        // Defense-in-depth: ignore attempts to pin an entry that doesn't belong
        // to the current user (SwiftUI @Query predicates should prevent this,
        // but keep the guard for safety).
        guard let sub = authenticatedUserSub, entry.userSub == sub else { return }
        entry.isPinned.toggle()
        entry.updatedAt = Date()
        do {
            try modelContext.save()
        } catch {
            // Non-blocking: revert on failure so UI state matches persisted state
            entry.isPinned.toggle()
            journalError = "Couldn't update pin. Please try again."
            #if DEBUG
            print("[AppState] togglePin save failed: \(error)")
            #endif
        }
    }

    /// Called on sign-out. Clears the in-memory list immediately and deletes
    /// the departing user's entries from the shared store so a subsequent sign-in
    /// by a different user on the same device cannot observe them.
    ///
    /// Legacy rows with an empty `userSub` (pre-column) are ONLY pruned when we
    /// have a confirmed departing user. `isAuthenticated = false` can also fire
    /// on a sign-in FAILURE (wrong password, network error) where no one was
    /// ever signed in; in that case `authenticatedUserSub` is nil and we must
    /// not touch legacy rows — they may be the real data of a pre-upgrade user
    /// who is currently trying to sign in.
    func clearJournalState() {
        journalEntries = []

        guard let departingSub = authenticatedUserSub else {
            // No confirmed departing user → nothing to delete. Preserves legacy
            // rows on sign-in-failure paths.
            return
        }

        // Delete this user's entries and any legacy empty-sub rows from the
        // store. Best-effort: if the delete fails, the in-memory list is still
        // cleared and the user-scoped predicate on fetch will hide the data on
        // next load.
        let descriptor = FetchDescriptor<JournalEntry>(
            predicate: #Predicate { $0.userSub == departingSub || $0.userSub == "" }
        )
        do {
            let rows = try modelContext.fetch(descriptor)
            for row in rows {
                modelContext.delete(row)
            }
            try modelContext.save()
        } catch {
            #if DEBUG
            print("[AppState] clearJournalState cleanup failed: \(error)")
            #else
            Crashlytics.crashlytics().record(error: error)
            #endif
        }
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

    /// Removes every cached daily-reflection key that belongs to the current
    /// authenticated user. Called at sign-out so the next user on the same
    /// device never sees a stranger's reflection. The matching key prefix
    /// is `walkworthy.dailyReflection::<userSub>::`.
    private func clearCachedReflectionsForCurrentUser() {
        guard let userSub = authenticatedUserSub else { return }
        let prefix = "\(StorageKey.dailyReflectionPrefix)::\(userSub)::"
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }

    private static func logicalDate() -> Date {
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour < 3 else { return Date() }
        return Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    }

    func checkAndFetchDailyReflection() {
        guard isAuthenticated else { return }
        // Reflections are AI-generated from mood summaries — no fetch until
        // the user has given AI consent (Guideline 5.1.2(i)).
        guard aiConsentGiven else { return }
        let today = Self.isoDateFormatter.string(from: Self.logicalDate())
        if let cached = loadCachedReflection(for: today) {
            dailyReflection = cached
            Analytics.logEvent("reflection_viewed", parameters: ["source": "cache"])
            return
        }
        reflectionFetchTask?.cancel()
        reflectionFetchTask = Task { @MainActor in
            do {
                let result = try await apiClient.fetchDailyReflection()
                self.dailyReflection = result
                self.cacheReflection(result)
                Analytics.logEvent("reflection_viewed", parameters: ["source": "network"])
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

    enum JournalError: LocalizedError {
        case notAuthenticated

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "Please sign in to save journal entries."
            }
        }
    }
}

extension AppState {
    enum StorageKey {
        static let onboardingCompleted = "walkworthy.onboardingCompleted"
        static let useProfilePersonalization = "walkworthy.settings.useProfilePersonalization"
        static let aiConsentGiven = "walkworthy.ai.consentGiven"
        static let analyticsEnabled = "walkworthy.settings.analyticsEnabled"
        static let translation = "walkworthy.settings.translation"
        static let dismissedNameBackfill = "walkworthy.dismissed.nameBackfill"
        static let hasCompletedProfileSetup = "walkworthy.profile.hasCompletedSetup"
        static let lastAuthenticatedUser = "walkworthy.auth.lastUser"
        static let dailyReflectionPrefix = "walkworthy.dailyReflection"
    }
}
