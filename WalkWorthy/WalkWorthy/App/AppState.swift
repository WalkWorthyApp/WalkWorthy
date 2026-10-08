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
import FirebaseAnalytics
import FirebaseCrashlytics

@MainActor
final class AppState: ObservableObject {
    @Published var onboardingCompleted: Bool
    @Published var useProfilePersonalization: Bool
    /// User has seen the AI data-sharing consent screen and tapped Continue.
    /// Required by App Review Guideline 5.1.2(i): mood data goes to OpenAI, so
    /// the app must obtain explicit in-app consent before the first AI call.
    /// Scoped per user; false blocks mood check-in AI + daily reflection fetch.
    @Published private(set) var aiConsentGiven: Bool = false
    @Published private(set) var aiConsentBusy = false
    @Published private(set) var aiConsentError: String?
    @Published private(set) var consentAgeGroup = "unknown"
    @Published private(set) var accountDeletionPending = false
    @Published private(set) var accountDeletionBusy = false
    @Published private(set) var accountDeletionError: String?
    private var consentRevision = 0
    private var consentEpoch = UUID()
    private var consentOperation: Task<Bool, Never>?
    /// Monotonic token identifying the newest enqueued consent operation.
    private var consentTicket: UInt64 = 0
    /// Only the newest refresh may publish a receipt or a refresh error.
    private var consentRefreshTicket: UInt64 = 0
    private var moodSubmissionTask: Task<MoodCheckInResponse, Error>?
    /// Identifies the newest submission so a finished one cannot clear a newer task.
    private var moodSubmissionTicket: UInt64 = 0
    private var pendingWithdrawal: Bool {
        get { defaults.bool(forKey: storageKey(StorageKey.pendingWithdrawal)) }
        set { defaults.set(newValue, forKey: storageKey(StorageKey.pendingWithdrawal)) }
    }
    /// Firebase Analytics collection toggle. Collection is disabled in
    /// Info.plist (FIREBASE_ANALYTICS_COLLECTION_ENABLED = NO) and turned on
    /// only when the user independently enables this setting.
    @Published private(set) var analyticsEnabled: Bool = false
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
    /// Last-known 7-day mood summary for the current user. Snapshotted so the
    /// MoodHistoryView week grid renders instantly on cold launch. Only the
    /// default (last 7 days ending today) window is cached — range picker
    /// changes always fetch fresh.
    @Published var weekSummary: [DailyMoodSummary] = []
    /// First page (up to 14 items) of the mood check-in log, snapshotted so
    /// Settings → Check-in Log renders without a `ProgressView` on cold launch.
    /// Pages 2+ are not cached — they still fetch on demand.
    ///
    /// Unlike the other snapshot-backed properties, this is NOT hydrated by
    /// `hydrateFromSnapshots` — it's the largest snapshot (check-ins carry
    /// full AI response text) and backs a Settings deep-dive screen most
    /// sessions never open, so `MoodLogView.loadFirstPage()` lazily reads it
    /// from `SnapshotStore` on first visit instead of paying the sync decode
    /// on the cold-launch path.
    @Published var moodLogFirstPage: [MoodCheckIn] = []

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
    private var isResumingDeletionCleanup = false
    private var reflectionFetchTask: Task<Void, Never>?
    /// Background profile fetch spawned by the auth listener. The listener can
    /// fire more than once per session (foreground, token refresh); each new
    /// fire cancels the previous fetch so stale results never pile up or land
    /// after a sign-out/account switch.
    private var profileRefreshTask: Task<Void, Never>?
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
    private static let userScopedKeys: Set<String> = [
        StorageKey.onboardingCompleted,
        StorageKey.useProfilePersonalization,
        StorageKey.aiConsentGiven,
        StorageKey.pendingWithdrawal,
        StorageKey.pendingWithdrawalId,
        StorageKey.analyticsEnabled,
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
        self.authenticatedUserSub = nil
        self.useProfilePersonalization = false
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
    /// Profile PII (age, occupation, major, hobbies, first name) is
    /// never persisted in UserDefaults — the authoritative copy lives on the
    /// backend and is fetched into `currentProfile` at sign-in. UserDefaults
    /// plists inherit `NSFileProtectionCompleteUntilFirstUserAuthentication`
    /// and are readable from unencrypted iTunes backups; keeping PII out of
    /// them removes that exposure without a Keychain migration.
    func updateProfile(firstName: String, age: Int?, occupation: String, major: String, hobbies: Set<String>, optIn: Bool) {
        let trimmedFirstName = firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOccupation = occupation.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMajor = major.trimmingCharacters(in: .whitespacesAndNewlines)

        // Refresh observable profile so Home greeting updates without a relaunch.
        currentProfile = OnboardingProfile(
            firstName: trimmedFirstName,
            age: age,
            occupation: trimmedOccupation,
            major: trimmedMajor,
            hobbies: hobbies,
            optIn: optIn
        )
        useProfilePersonalization = optIn
        defaults.set(optIn, forKey: storageKey(StorageKey.useProfilePersonalization))

        // Flip the "setup complete" flag so the Home name banner stops showing
        // on offline cold-launches. Only set it when the user actually supplied
        // a non-empty first name — an empty value means they haven't completed
        // the backfill yet.
        if !trimmedFirstName.isEmpty {
            setHasCompletedProfileSetup(true)
        }

        syncProfile(firstName: trimmedFirstName, age: age, occupation: trimmedOccupation, major: trimmedMajor, hobbies: hobbies, optIn: optIn)
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
            hobbies: [],
            optIn: false
        )
    }

    /// Fetch the authoritative user profile from the backend and hydrate
    /// `currentProfile`. Failure is non-fatal — on network issues the user
    /// sees the last in-memory value (nil on a cold launch). Called at
    /// sign-in and after auth state changes.
    func refreshProfileFromBackend() async {
        guard isAuthenticated, !accountDeletionPending, let requestSub = authenticatedUserSub else { return }
        do {
            let response = try await apiClient.fetchUserProfile()
            // User switched accounts while the fetch was in flight — discard.
            // Applying the stale result would leak the previous user's PII into
            // the new user's in-memory profile and on-disk snapshot.
            guard authenticatedUserSub == requestSub, !accountDeletionPending else { return }
            guard !Task.isCancelled else { return }
            if let response {
                let profile = Self.profile(from: response)
                currentProfile = profile
                useProfilePersonalization = profile.optIn
                defaults.set(profile.optIn, forKey: storageKey(StorageKey.useProfilePersonalization))
                // Record the minimal "setup complete" flag so the
                // NameBackfillBanner gate survives offline cold-launches.
                let trimmedFirstName = profile.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmedFirstName.isEmpty {
                    setHasCompletedProfileSetup(true)
                }
                await SnapshotStore.shared.write(response, kind: .profile, userSub: requestSub)
            } else {
                currentProfile = nil
            }
        } catch {
            #if DEBUG
            print("[AppState] Failed to fetch profile from backend: \(error)")
            #endif
        }
    }

    /// Synchronously hydrates server-backed @Published properties from the
    /// on-disk SnapshotStore so views render instantly on sign-in. Called
    /// from `refreshAuthenticatedUser` before any network fetch. Per-property
    /// hydration is best-effort: a missing/corrupt snapshot leaves the current
    /// in-memory value untouched, so the existing async fetch path still fills
    /// it in without regression.
    private func hydrateFromSnapshots(userSub: String) {
        if let snapshot: Snapshot<RemoteUserProfileResponse> = SnapshotStore.shared.readSync(
            RemoteUserProfileResponse.self, kind: .profile, userSub: userSub
        ) {
            currentProfile = Self.profile(from: snapshot.payload)
            useProfilePersonalization = snapshot.payload.optInTailored ?? false
            defaults.set(
                useProfilePersonalization,
                forKey: storageKey(StorageKey.useProfilePersonalization)
            )
        }

        let today = Self.isoDateFormatter.string(from: Self.logicalDate())

        if let snapshot: Snapshot<MoodStatusResponse> = SnapshotStore.shared.readSync(
            MoodStatusResponse.self, kind: .moodStatus, userSub: userSub, dateSuffix: today
        ) {
            currentMoodStatus = snapshot.payload
        }

        if let snapshot: Snapshot<DailyReflection> = SnapshotStore.shared.readSync(
            DailyReflection.self, kind: .dailyReflection, userSub: userSub, dateSuffix: today
        ) {
            dailyReflection = snapshot.payload
        }

        // Not date-scoped: a day-old week grid is still a valid approximation
        // of the week and the view refetches immediately on appear; unlike
        // moodStatus, nothing actionable/submittable derives from a stale
        // summary.
        if let snapshot: Snapshot<[DailyMoodSummary]> = SnapshotStore.shared.readSync(
            [DailyMoodSummary].self, kind: .weekSummary, userSub: userSub
        ) {
            weekSummary = snapshot.payload
        }

        // `moodLogFirstPage` is deliberately NOT hydrated here — see its
        // doc comment; MoodLogView lazily reads that snapshot on first visit
        // to keep the biggest decode off the launch path.
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

        return OnboardingProfile(
            firstName: response.firstName ?? "",
            age: age,
            occupation: response.occupation ?? "",
            major: response.major ?? "",
            hobbies: Set(response.hobbies ?? []),
            optIn: response.optInTailored ?? false
        )
    }

    func setUseProfilePersonalization(_ isOn: Bool) {
        let previousValue = useProfilePersonalization
        useProfilePersonalization = isOn
        currentProfile?.optIn = isOn
        defaults.set(isOn, forKey: storageKey(StorageKey.useProfilePersonalization))

        guard isAuthenticated, !accountDeletionPending, let requestSub = authenticatedUserSub else { return }
        profileSyncTask?.cancel()
        profileSyncTask = Task { [weak self] in
            await self?.sendPersonalizationPreference(
                isOn,
                previousValue: previousValue,
                requestSub: requestSub
            )
        }
    }

    /// A local preference is never proof of permission. Only the server's
    /// versioned receipt enables AI requests. A queued withdrawal wins over grants.
    func refreshAIConsent() async {
        guard let sub = authenticatedUserSub, !accountDeletionPending, !aiConsentBusy else { return }
        if pendingWithdrawal {
            withdrawAIConsent(retrying: true)
            return
        }
        let epoch = consentEpoch
        consentRefreshTicket &+= 1
        let ticket = consentRefreshTicket
        do {
            let receipt = try await apiClient.fetchPrivacyConsent()
            guard !Task.isCancelled, authenticatedUserSub == sub, consentEpoch == epoch,
                  consentRefreshTicket == ticket, !aiConsentBusy,
                  receipt.revision >= consentRevision else { return }
            applyConsent(receipt)
            aiConsentError = nil
            checkAndFetchDailyReflection()
        } catch {
            guard !Task.isCancelled, authenticatedUserSub == sub, consentEpoch == epoch,
                  consentRefreshTicket == ticket, !aiConsentBusy else { return }
            // Only a definitive answer changes the flag. Clearing it up front
            // made every foreground swap `MoodCheckInView` to the consent
            // screen, and that teardown fires `checkInFlow.onDisappear`, which
            // cancels an in-flight submission. An unreachable server cannot
            // revoke a permission the server already granted, so leave the
            // last known state alone and surface the failure instead.
            aiConsentError = "AI sharing could not be verified. Connect to the internet and retry."
        }
    }

    private func applyConsent(_ receipt: PrivacyConsent) {
        consentRevision = receipt.revision
        consentAgeGroup = receipt.ageGroup
        aiConsentGiven = receipt.aiSharing && receipt.noticeVersion == "2026-09-04"
            && receipt.ageGroup == "18+" && !pendingWithdrawal
        applyAnalyticsCollectionState()
    }

    func grantAIConsent(ageGroup: String) async -> Bool {
        guard !accountDeletionPending, !aiConsentBusy, !pendingWithdrawal, ageGroup == "18+" else { return false }
        return await enqueueConsent(given: true, ageGroup: ageGroup).value
    }

    func withdrawAIConsent(retrying: Bool = false) {
        guard authenticatedUserSub != nil else { return }
        if !retrying || defaults.string(forKey: storageKey(StorageKey.pendingWithdrawalId)) == nil {
            defaults.set(UUID().uuidString, forKey: storageKey(StorageKey.pendingWithdrawalId))
        }
        pendingWithdrawal = true
        aiConsentGiven = false
        reflectionFetchTask?.cancel()
        moodSubmissionTask?.cancel()
        _ = enqueueConsent(given: false, ageGroup: nil)
    }

    func retryAIConsent() {
        if pendingWithdrawal { withdrawAIConsent(retrying: true) }
        else { Task { await refreshAIConsent() } }
    }

    private func enqueueConsent(given: Bool, ageGroup: String?) -> Task<Bool, Never> {
        let previous = consentOperation
        let sub = authenticatedUserSub
        let withdrawalId = given ? nil : defaults.string(forKey: storageKey(StorageKey.pendingWithdrawalId))
        // A refresh that began before this choice cannot overwrite its result,
        // even if it finishes after the mutation has released the busy flag.
        consentEpoch = UUID()
        let epoch = consentEpoch
        consentTicket &+= 1
        let ticket = consentTicket
        aiConsentBusy = true
        aiConsentError = nil
        let operation = Task { @MainActor [weak self] in
            _ = await previous?.value
            guard let self else { return false }
            // Every exit must release the busy flag, or the whole consent
            // system locks: `grantAIConsent` and `refreshAIConsent` both guard
            // on `!aiConsentBusy`, and an early return on a stale epoch (e.g.
            // `handleAIConsentRejection` bumping it mid-flight) used to strand
            // it at `true` with nothing left to clear it. Only the newest
            // enqueue releases it, so an older task finishing cannot clear the
            // flag a newer one is still relying on.
            defer { if self.consentTicket == ticket { self.aiConsentBusy = false } }
            guard !Task.isCancelled, let sub, self.authenticatedUserSub == sub,
                  self.consentEpoch == epoch, self.consentTicket == ticket else { return false }
            do {
                let update: PrivacyConsentUpdate
                if given {
                    // Grants compare-and-set against a freshly read revision.
                    // Conflicts require another explicit action, never a retry.
                    let current = try await self.apiClient.fetchPrivacyConsent()
                    guard !Task.isCancelled, self.authenticatedUserSub == sub,
                          self.consentEpoch == epoch, self.consentTicket == ticket else { return false }
                    update = .init(aiSharing: true, ageGroup: ageGroup, expectedRevision: current.revision)
                } else {
                    // Withdrawal is unconditional and idempotent. It must not
                    // depend on a GET quota, a notice version, or a stale revision.
                    // Waiting for `previous` above ensures it follows any grant
                    // already sent by this device.
                    update = .init(aiSharing: false, noticeVersion: nil, ageGroup: nil, expectedRevision: nil, withdrawalId: withdrawalId)
                }
                let result = try await self.apiClient.updatePrivacyConsent(update)
                guard !Task.isCancelled, self.authenticatedUserSub == sub,
                      self.consentEpoch == epoch, self.consentTicket == ticket else { return false }
                self.pendingWithdrawal = false
                self.defaults.removeObject(forKey: self.storageKey(StorageKey.pendingWithdrawalId))
                self.applyConsent(result)
                if given { self.checkAndFetchDailyReflection() }
                return given ? self.aiConsentGiven : !result.aiSharing
            } catch {
                guard !Task.isCancelled, self.authenticatedUserSub == sub,
                      self.consentEpoch == epoch, self.consentTicket == ticket else { return false }
                self.aiConsentGiven = false
                self.aiConsentError = given
                    ? "Permission was not confirmed. Review your choice and try again."
                    : "AI is off on this device, but withdrawal is not yet confirmed by the server. Retry when connected; other devices may still share data."
                return false
            }
        }
        consentOperation = operation
        return operation
    }

    private func handleAIConsentRejection(_ error: Error) {
        if case APIError.aiConsentRequired = error {
            aiConsentGiven = false
            consentEpoch = UUID()
            reflectionFetchTask?.cancel()
            moodSubmissionTask?.cancel()
            aiConsentError = "AI sharing permission has changed. Review your choice before continuing."
        }
    }

    func setAnalyticsEnabled(_ isOn: Bool) {
        analyticsEnabled = isOn && consentAgeGroup == "18+"
        defaults.set(analyticsEnabled, forKey: storageKey(StorageKey.analyticsEnabled))
        applyAnalyticsCollectionState()
    }

    /// Collection stays off (Info.plist FIREBASE_ANALYTICS_COLLECTION_ENABLED
    /// = NO) until the user independently opts in to analytics.
    private func applyAnalyticsCollectionState() {
        Analytics.setAnalyticsCollectionEnabled(analyticsEnabled && consentAgeGroup == "18+")
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
        // Finish erasure before auth callbacks can hydrate any saved account.
        await resumePendingLocalDeletions()
        await authSession.observeAuthState { [weak self] isSignedIn in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if isSignedIn {
                    self.isAuthenticated = true
                    self.authenticationNotice = nil
                    // Load UID + user-scoped prefs (onboardingCompleted, translation,
                    // etc). No network — reads Auth.auth().currentUser.uid + UserDefaults.
                    await self.refreshAuthenticatedUser()
                    if self.accountDeletionPending {
                        self.isCheckingAuth = false
                        return
                    }
                    self.needsEmailVerification = await self.authSession.needsEmailVerification(reload: false)
                    // Fast path: returning user who's completed onboarding. UI can
                    // render MainTabView immediately using cached prefs; profile +
                    // daily reflection hydrate in the background so the splash
                    // doesn't block on network round-trips.
                    if self.onboardingCompleted {
                        self.isCheckingAuth = false
                        let expectedSub = self.authenticatedUserSub
                        self.profileRefreshTask?.cancel()
                        self.profileRefreshTask = Task { @MainActor [weak self] in
                            guard let self else { return }
                            await self.refreshProfileFromBackend()
                            // Account switched while the fetch was in flight —
                            // don't kick off a reflection fetch for the wrong
                            // user's consent state.
                            guard self.isAuthenticated, self.authenticatedUserSub == expectedSub else { return }
                            self.checkAndFetchDailyReflection()
                        }
                        return
                    }
                    // No local onboarding pref (first sign-in on this device or
                    // cleared app data). Don't block the splash on the profile
                    // fetch — show OnboardingForm immediately; if the fetch
                    // confirms a returning user, markOnboardingComplete() flips
                    // RootView to MainTabView mid-session. Deliberate trade-off
                    // (design spec: instant launch > avoiding a brief
                    // OnboardingForm flash on fresh devices).
                    self.isCheckingAuth = false
                    let expectedSub = self.authenticatedUserSub
                    self.profileRefreshTask?.cancel()
                    self.profileRefreshTask = Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.refreshProfileFromBackend()
                        // Account switched (or signed out) while the fetch was
                        // in flight — never mark onboarding complete for a user
                        // whose profile we didn't actually fetch.
                        guard self.isAuthenticated, self.authenticatedUserSub == expectedSub else { return }
                        if self.currentProfile != nil {
                            self.markOnboardingComplete()
                        }
                        self.checkAndFetchDailyReflection()
                    }
                } else {
                    self.isAuthenticated = false
                    self.needsEmailVerification = false
                    self.setAuthenticatedUserSub(nil)
                    self.isCheckingAuth = false
                }
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
                Crashlytics.crashlytics().record(error: NSError(domain: "WalkWorthy.AuthEmailVerification", code: 1, userInfo: nil))
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

    /// Confirming deletion immediately erases this device's data. A durable
    /// UID intent survives network errors and process termination so startup
    /// finishes local erasure even if the worker has already deleted Auth.
    func deleteAccount() async throws {
        guard let sub = authenticatedUserSub else { throw APIError.notAuthenticated }
        guard !accountDeletionBusy else { return }
        if pendingAccountDeletionIntents[sub] == nil {
            // Capture legacy ownership before any await, sign-out or defaults cleanup.
            setDeletionIntent(AccountDeletionIntent(includeLegacy: true), for: sub)
        }
        NotificationScheduler.shared.invalidateSession(for: sub)
        accountDeletionPending = true
        accountDeletionBusy = true
        accountDeletionError = nil
        consentEpoch = UUID()
        consentTicket &+= 1
        consentOperation?.cancel()
        consentOperation = nil
        aiConsentBusy = false
        aiConsentGiven = false
        analyticsEnabled = false
        applyAnalyticsCollectionState()
        moodSubmissionTask?.cancel()
        reflectionFetchTask?.cancel()
        profileRefreshTask?.cancel()
        profileSyncTask?.cancel()
        clearMoodState()
        currentProfile = nil
        journalEntries = []
        defer { accountDeletionBusy = false }
        var localError: Error?
        do { try await eraseLocalAccountData(for: sub) }
        catch { localError = error }

        // Local failure must never prevent the cloud request. Persist each side's
        // completion separately so a successful cloud deletion is not retried
        // using an Auth user that no longer exists.
        var serverError: Error?
        if pendingAccountDeletionIntents[sub]?.serverComplete != true {
            do {
                guard authenticatedUserSub == sub else { throw CancellationError() }
                try await apiClient.deleteAccount()
                updateDeletionIntent(for: sub) { $0.serverComplete = true }
            } catch { serverError = error }
        }
        if let error = localError ?? serverError {
            if authenticatedUserSub == sub {
                let localMessage = localError == nil ? nil : "Device cleanup is unfinished. Unlock your device and retry cleanup."
                let cloudMessage = serverError.map {
                    ($0 as? APIError)?.errorDescription ?? "Server deletion is not yet confirmed. Retry or contact support."
                }
                accountDeletionError = [localMessage, cloudMessage].compactMap { $0 }.joined(separator: " ")
            }
            throw error
        }
        do { try await finishDeletionIfComplete(for: sub) }
        catch {
            if authenticatedUserSub == sub {
                accountDeletionError = "Your data was deleted. Please retry signing out."
            }
            throw error
        }
    }

    private struct AccountDeletionIntent: Codable {
        var includeLegacy: Bool
        var localComplete = false
        var serverComplete = false
    }

    private var pendingAccountDeletionIntents: [String: AccountDeletionIntent] {
        if let data = defaults.data(forKey: StorageKey.accountDeletionIntents),
           let intents = try? JSONDecoder().decode([String: AccountDeletionIntent].self, from: data) {
            return intents
        }
        // Every v1 intent was recorded by the authenticated owner and included
        // legacy rows in its original cleanup. Preserve that decision even if
        // sign-out has since removed lastAuthenticatedUser.
        return Dictionary(uniqueKeysWithValues: Set(defaults.stringArray(forKey: StorageKey.pendingAccountDeletions) ?? []).map {
            ($0, AccountDeletionIntent(includeLegacy: true))
        })
    }

    private var pendingAccountDeletionUsers: Set<String> {
        Set(pendingAccountDeletionIntents.keys)
    }

    /// Runs without authentication, including after cloud deletion removed Auth.
    /// Foreground retries handle file protection lifting after a locked launch.
    func resumePendingLocalDeletions() async {
        guard !accountDeletionBusy, !isResumingDeletionCleanup else { return }
        isResumingDeletionCleanup = true
        defer { isResumingDeletionCleanup = false }
        for sub in pendingAccountDeletionUsers {
            do {
                try await eraseLocalAccountData(for: sub)
                try await finishDeletionIfComplete(for: sub)
            } catch { accountDeletionError = "Device cleanup is unfinished. Unlock your device and retry cleanup." }
        }
    }

    private func setDeletionIntent(_ intent: AccountDeletionIntent?, for sub: String) {
        var intents = pendingAccountDeletionIntents
        intents[sub] = intent
        // Only Bool/String records are encoded; failure is not expected.
        guard let data = try? JSONEncoder().encode(intents) else { return }
        defaults.set(data, forKey: StorageKey.accountDeletionIntents)
        defaults.removeObject(forKey: StorageKey.pendingAccountDeletions)
    }

    private func updateDeletionIntent(for sub: String, _ update: (inout AccountDeletionIntent) -> Void) {
        // Re-read after each await rather than overwriting another side's progress.
        guard var intent = pendingAccountDeletionIntents[sub] else { return }
        update(&intent)
        setDeletionIntent(intent, for: sub)
    }

    private func finishDeletionIfComplete(for sub: String) async throws {
        guard let intent = pendingAccountDeletionIntents[sub], intent.localComplete, intent.serverComplete else { return }
        // At startup AppState may not yet know the cached Auth UID. Check the
        // actual session atomically, before removing the recovery record.
        try await authSession.signOut(ifUserSub: sub)
        if authenticatedUserSub == sub {
            isAuthenticated = false
            setAuthenticatedUserSub(nil)
        }
        setDeletionIntent(nil, for: sub)
    }

    /// UID-specific, repeatable cleanup; never depends on the current Auth user.
    private func eraseLocalAccountData(for sub: String) async throws {
        guard let intent = pendingAccountDeletionIntents[sub] else { return }
        // Write migration/ownership before any local operation can fail.
        setDeletionIntent(intent, for: sub)
        NotificationScheduler.shared.invalidateSession(for: sub)
        var cleanupError: Error?
        if !intent.localComplete {
            let includeLegacy = intent.includeLegacy
            let descriptor = FetchDescriptor<JournalEntry>(
                predicate: #Predicate { $0.userSub == sub || (includeLegacy && $0.userSub == "") }
            )
            do {
                let rows = try modelContext.fetch(descriptor)
                for row in rows { modelContext.delete(row) }
                try modelContext.save()
            } catch { cleanupError = error }
            // Complete the other local stores even when SwiftData fails.
            removeUserScopedDefaults(for: sub)
            if includeLegacy {
                // Older reminder settings used bare keys. Do not let the next
                // account's migration inherit a deleted user's schedule.
                for key in defaults.dictionaryRepresentation().keys
                    where key.hasPrefix("walkworthy.reminders.") && !key.contains("::") {
                    defaults.removeObject(forKey: key)
                }
            }
            let prefix = "\(StorageKey.dailyReflectionPrefix)::\(sub)::"
            for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
                defaults.removeObject(forKey: key)
            }
        }
        await NotificationScheduler.shared.removeReminders(for: sub, includingLegacy: intent.includeLegacy)
        do { try await SnapshotStore.shared.deleteAllDurably(for: sub) }
        catch { if cleanupError == nil { cleanupError = error } }
        if let cleanupError { throw cleanupError }
        updateDeletionIntent(for: sub) { $0.localComplete = true }
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
        removeMoodDrafts(for: userSub)
        // Also clear the "last authenticated user" pointer so a subsequent
        // sign-in starts with a clean per-user slate.
        if defaults.string(forKey: StorageKey.lastAuthenticatedUser) == userSub {
            defaults.removeObject(forKey: StorageKey.lastAuthenticatedUser)
        }
    }

    func signOut() {
        ReminderPreferences.discardOwnerlessValues(in: defaults)
        authenticationNotice = "You have been signed out. Please sign in again."
        if let sub = authenticatedUserSub {
            NotificationScheduler.shared.invalidateSession(for: sub)
            Task { await NotificationScheduler.shared.removeReminders(for: sub, includingLegacy: true) }
        }

        // Cancel any in-flight per-user work so stale writes can't land
        // after the user signs out. Each task honors cooperative
        // cancellation; nothing here blocks.
        reflectionFetchTask?.cancel()
        reflectionFetchTask = nil
        profileRefreshTask?.cancel()
        profileRefreshTask = nil
        profileSyncTask?.cancel()
        profileSyncTask = nil

        // Drop the previous user's cached response data from memory so a
        // quick sign-in from another account never flashes the prior
        // user's reflection or mood summary.
        dailyReflection = nil
        latestMoodResponse = nil
        currentMoodStatus = nil
        weekSummary = []
        moodLogFirstPage = []
        lastMoodStatusFetch = nil

        // Remove all on-disk caches for the outgoing user (legacy reflection
        // keys + the SnapshotStore directory). Scoped by Firebase sub so
        // clearing eagerly prevents accidental reuse after a shared device is
        // handed to someone else. Capture the sub locally: if it's already
        // nil (never authenticated), skip cleanup but continue the rest of
        // the sign-out teardown as before.
        if let departingSub = authenticatedUserSub {
            removeMoodDrafts(for: departingSub)
            clearOnDiskUserCaches(for: departingSub)
        }

        // Wipe any pending local reminders so the next account doesn't
        // inherit a stranger's notification schedule. The new user will
        // re-register their own from Settings → Check-in Reminders.

        // Cancel any previous in-flight sign-out so stacked taps don't queue
        // duplicate `authSession.signOut()` calls.
        signOutTask?.cancel()
        signOutTask = Task { [weak self] in
            guard let self else { return }
            try? await self.authSession.signOut()
            // Listener fires and sets isAuthenticated = false, clears userSub
        }
    }

    /// Mood drafts use a legacy dot-delimited key because the view owns their
    /// persistence. They can contain a free-text note, so clear them explicitly
    /// on sign-out and account deletion.
    private func removeMoodDrafts(for userSub: String) {
        let prefix = "walkworthy.moodCheckIn.draft.\(userSub)."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
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

    func accountUsesAppleSignIn() async -> Bool {
        await authSession.usesAppleSignIn()
    }

    func revokeAppleAuthorizationForDeletion() async throws {
        try await authSession.revokeAppleAuthorizationForDeletion()
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
        // Also retire legacy residue on the initial nil-to-nil auth callback.
        ReminderPreferences.discardOwnerlessValues(in: defaults)
        if authenticatedUserSub == sub {
            return
        }

        if let departingSub = authenticatedUserSub {
            NotificationScheduler.shared.invalidateSession(for: departingSub)
            Task { await NotificationScheduler.shared.removeReminders(for: departingSub, includingLegacy: true) }
        }

        consentEpoch = UUID()
        consentTicket &+= 1
        consentOperation?.cancel()
        consentOperation = nil
        aiConsentBusy = false
        aiConsentError = nil
        consentAgeGroup = "unknown"
        consentRevision = 0
        moodSubmissionTask?.cancel()
        reflectionFetchTask?.cancel()
        authenticatedUserSub = sub
        accountDeletionPending = sub.map { pendingAccountDeletionUsers.contains($0) } ?? false
        if let sub, !accountDeletionPending {
            NotificationScheduler.shared.beginSession(for: sub)
        }

        if let sub {
            // Purge sensitive drafts written by releases that used UserDefaults.
            removeMoodDrafts(for: sub)
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
            if pendingAccountDeletionUsers.contains(sub) {
                accountDeletionPending = true
                do {
                    try await eraseLocalAccountData(for: sub)
                    try await finishDeletionIfComplete(for: sub)
                } catch { accountDeletionError = "Device cleanup is unfinished. Unlock your device and retry cleanup." }
                return
            }
            // Lift any deleteAll tombstone from a prior session for this sub
            // before hydrating — this is the one legitimate way a new
            // session may resurrect on-disk snapshot writes.
            await SnapshotStore.shared.beginSession(for: sub)
            guard authenticatedUserSub == sub else { return }
            if accountDeletionPending {
                // Deletion may have begun while the actor call was suspended.
                // Restore its tombstone before any snapshot can be hydrated.
                do {
                    try await eraseLocalAccountData(for: sub)
                    try await finishDeletionIfComplete(for: sub)
                } catch { accountDeletionError = "Device cleanup is unfinished. Unlock your device and retry cleanup." }
                return
            }
            hydrateFromSnapshots(userSub: sub)
            await refreshAIConsent()
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
            useProfilePersonalization = false
            aiConsentGiven = false
            analyticsEnabled = false
            currentProfile = nil
            nameBackfillDismissed = false
            hasCompletedProfileSetup = false
            applyAnalyticsCollectionState()
            return
        }

        onboardingCompleted = defaults.bool(forKey: storageKey(StorageKey.onboardingCompleted))
        useProfilePersonalization = defaults.object(forKey: storageKey(StorageKey.useProfilePersonalization)) as? Bool ?? false
        aiConsentGiven = false // Legacy local consent does not authorize server sharing.
        analyticsEnabled = defaults.object(forKey: storageKey(StorageKey.analyticsEnabled)) as? Bool ?? false
        applyAnalyticsCollectionState()

        // Profile PII is no longer cached in UserDefaults — hydrate via
        // `refreshProfileFromBackend()` on sign-in. Leaving `currentProfile`
        // untouched here so a sub-change during an active session doesn't
        // blank out an in-memory value that was just populated.
        nameBackfillDismissed = defaults.bool(forKey: storageKey(StorageKey.dismissedNameBackfill))
        hasCompletedProfileSetup = defaults.bool(forKey: storageKey(StorageKey.hasCompletedProfileSetup))
    }

    private func syncProfile(firstName: String, age: Int?, occupation: String, major: String, hobbies: Set<String>, optIn: Bool) {
        guard isAuthenticated else { return }
        let profile = OnboardingProfile(firstName: firstName, age: age, occupation: occupation, major: major, hobbies: hobbies, optIn: optIn)

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
        guard isAuthenticated, !accountDeletionPending, let requestSub = authenticatedUserSub else { return }
        let trimmedFirstName = profile.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedOccupation = profile.occupation.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMajor = profile.major.trimmingCharacters(in: .whitespacesAndNewlines)
        let hobbies = profile.hobbies.sorted()

        // Get user's timezone
        let timezone = TimeZone.current.identifier

        let payload = RemoteUserProfileRequest(
            // Empty values are sent deliberately on this full form save so
            // the PATCH can remove fields the user cleared. Nil is reserved
            // for minimal partial updates such as a consent toggle.
            ageRange: ageRangeString(for: profile.age) ?? "",
            firstName: trimmedFirstName,
            occupation: trimmedOccupation,
            major: trimmedMajor,
            hobbies: hobbies,
            optInTailored: profile.optIn,
            checkInTimes: nil,  // TODO: Add UI for custom check-in times
            timezone: timezone
        )

        do {
            // Snapshot the merged document the backend returns — NOT the
            // request payload. The PATCH is a server-side merge, so any field
            // this request omitted (e.g. nil firstName) is preserved remotely;
            // snapshotting the request would record it as nil and hydrate a
            // blank greeting on the next cold launch. `currentProfile` is
            // deliberately left untouched here: it was already set
            // optimistically by `updateProfile()`, and this debounced PATCH
            // may land after newer in-memory edits.
            let updated = try await apiClient.updateUserProfile(payload)
            // User switched accounts while the PATCH was in flight — don't
            // persist this user's merged profile into the new user's snapshot.
            guard authenticatedUserSub == requestSub, !accountDeletionPending else { return }
            if let updated {
                await SnapshotStore.shared.write(updated, kind: .profile, userSub: requestSub)
            }
        } catch {
            #if DEBUG
            print("[AppState] Failed to sync profile: \(error)")
            #endif
        }
    }

    /// Persists the Settings toggle as an immediate, minimal PATCH. The backend
    /// reads this Firestore value before every AI request, so a local-only write
    /// would not actually withdraw profile sharing.
    private func sendPersonalizationPreference(
        _ isOn: Bool,
        previousValue: Bool,
        requestSub: String
    ) async {
        let payload = RemoteUserProfileRequest(
            ageRange: nil,
            firstName: nil,
            occupation: nil,
            major: nil,
            hobbies: nil,
            optInTailored: isOn,
            checkInTimes: nil,
            timezone: nil
        )

        do {
            let updated = try await apiClient.updateUserProfile(payload)
            guard authenticatedUserSub == requestSub, !accountDeletionPending else { return }
            if let updated {
                await SnapshotStore.shared.write(updated, kind: .profile, userSub: requestSub)
            }
        } catch {
            guard !Task.isCancelled, !accountDeletionPending,
                  authenticatedUserSub == requestSub,
                  useProfilePersonalization == isOn else { return }
            useProfilePersonalization = previousValue
            currentProfile?.optIn = previousValue
            defaults.set(previousValue, forKey: storageKey(StorageKey.useProfilePersonalization))
            #if DEBUG
            print("[AppState] Failed to sync personalization preference: \(error)")
            #endif
        }
    }

    /// Maps a user-entered age to the backend `AgeRange` bucket used for
    /// personalization. The backend only supports 18+ buckets today, so
    /// Sign-up is gated at 18 (`OnboardingForm.minimumAge`), so every value
    /// here lands in a real bucket; anything below 18 maps to `nil` purely as
    /// a defensive fallback and the agents fall back to other profile fields
    /// (occupation/major/hobbies) for tone. This is personalization-only —
    /// auth/usage is gated separately in the onboarding form, not here.
    private func ageRangeString(for age: Int?) -> String? {
        guard let age else { return nil }
        switch age {
        case ..<18: return nil // Unreachable: sign-up requires 18+. Defensive only.
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
        guard isAuthenticated, !accountDeletionPending, let requestSub = authenticatedUserSub else { return }
        if let lastFetch = lastMoodStatusFetch,
           Date().timeIntervalSince(lastFetch) < Self.moodStatusStaleness {
            return
        }

        do {
            let status = try await apiClient.fetchMoodStatus()
            // User switched accounts while the fetch was in flight — discard.
            // Applying the stale result would render the previous user's mood
            // in the new user's session and persist it into their snapshot.
            guard authenticatedUserSub == requestSub, !accountDeletionPending else { return }
            currentMoodStatus = status
            lastMoodStatusFetch = Date()
            // Date-scoped: the check-in type is a time-of-day claim, so the
            // snapshot's validity is day-bounded — a previous-day snapshot
            // must not hydrate (prevents stale-card wrong-type submissions).
            let today = Self.isoDateFormatter.string(from: Self.logicalDate())
            await SnapshotStore.shared.write(status, kind: .moodStatus, userSub: requestSub, dateSuffix: today)
        } catch {
            #if DEBUG
            print("[AppState] Failed to load mood status: \(error)")
            #endif
        }
    }

    func submitMoodCheckIn(_ request: MoodCheckInRequest) async throws -> MoodCheckInResponse {
        try Task.checkCancellation()
        guard isAuthenticated else {
            throw MoodError.notAuthenticated
        }

        guard aiConsentGiven else { throw APIError.aiConsentRequired }
        let sub = authenticatedUserSub
        let epoch = consentEpoch
        let submission = Task {
            try Task.checkCancellation()
            return try await apiClient.submitMoodCheckIn(request)
        }
        moodSubmissionTask = submission
        moodSubmissionTicket &+= 1
        let ticket = moodSubmissionTicket
        let response: MoodCheckInResponse
        defer { if moodSubmissionTicket == ticket { moodSubmissionTask = nil } }
        do {
            response = try await withTaskCancellationHandler {
                try await submission.value
            } onCancel: {
                submission.cancel()
            }
        }
        catch {
            guard !Task.isCancelled, !submission.isCancelled,
                  authenticatedUserSub == sub, consentEpoch == epoch,
                  moodSubmissionTicket == ticket else { throw CancellationError() }
            handleAIConsentRejection(error)
            throw error
        }
        guard !Task.isCancelled, !submission.isCancelled, aiConsentGiven,
              authenticatedUserSub == sub, consentEpoch == epoch,
              moodSubmissionTicket == ticket else { throw CancellationError() }
        latestMoodResponse = response
        // Intentionally do NOT write a nil snapshot here — the disk snapshot
        // is the last-known server view and should stay until the async
        // loadMoodStatus() below refreshes it. This keeps a cold launch mid-
        // submit from rendering blank check-in cards.
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

    /// Publishes a freshly fetched 7-day summary and snapshots it — but only
    /// if the account that requested the fetch is still signed in. The caller
    /// (MoodHistoryView) captures `requestSub` before its fetch await; a
    /// mismatch means the user switched accounts mid-fetch, so the stale
    /// result must be dropped rather than persisted into the new user's
    /// `@Published` state and on-disk snapshot.
    func publishWeekSummary(_ summaries: [DailyMoodSummary], requestSub: String) async {
        guard authenticatedUserSub == requestSub, !accountDeletionPending else { return }
        weekSummary = summaries
        await SnapshotStore.shared.write(summaries, kind: .weekSummary, userSub: requestSub)
    }

    /// Publishes a freshly fetched mood-log first page and snapshots it, with
    /// the same cross-account guard as `publishWeekSummary(_:requestSub:)`.
    func publishMoodLogFirstPage(_ page: [MoodCheckIn], requestSub: String) async {
        guard authenticatedUserSub == requestSub, !accountDeletionPending else { return }
        moodLogFirstPage = page
        await SnapshotStore.shared.write(page, kind: .moodLogFirstPage, userSub: requestSub)
    }

    func clearMoodState() {
        currentMoodStatus = nil
        latestMoodResponse = nil
        dailyReflection = nil
        weekSummary = []
        moodLogFirstPage = []
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
            Crashlytics.crashlytics().record(error: NSError(domain: "WalkWorthy.JournalLoad", code: 2, userInfo: nil))
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
            Crashlytics.crashlytics().record(error: NSError(domain: "WalkWorthy.JournalCleanup", code: 3, userInfo: nil))
            #endif
        }
    }

    private func loadCachedReflection(for date: String) -> DailyReflection? {
        guard let userSub = authenticatedUserSub else { return nil }

        // Prefer the new SnapshotStore.
        if let snapshot: Snapshot<DailyReflection> = SnapshotStore.shared.readSync(
            DailyReflection.self, kind: .dailyReflection, userSub: userSub, dateSuffix: date
        ) {
            return snapshot.payload
        }

        // Legacy path: migrate the old UserDefaults key on first read. Removing
        // the key makes the migration self-terminating; past-date reflections
        // are never read again and the sign-out sweep still clears the prefix.
        let legacyKey = "\(StorageKey.dailyReflectionPrefix)::\(userSub)::\(date)"
        guard let data = defaults.data(forKey: legacyKey),
              let reflection = try? Self.reflectionDecoder.decode(DailyReflection.self, from: data)
        else { return nil }
        Task { await SnapshotStore.shared.write(reflection, kind: .dailyReflection, userSub: userSub, dateSuffix: date) }
        defaults.removeObject(forKey: legacyKey)
        return reflection
    }

    private func cacheReflection(_ reflection: DailyReflection) async {
        guard let userSub = authenticatedUserSub else { return }
        await SnapshotStore.shared.write(
            reflection, kind: .dailyReflection, userSub: userSub, dateSuffix: reflection.date
        )
    }

    /// Removes every on-disk cache scoped to the given user — the legacy
    /// UserDefaults reflection keys and the SnapshotStore directory. Called
    /// at sign-out and account deletion so the next user on this device
    /// never sees a stranger's data. Takes the sub explicitly (captured by
    /// the caller before any suspension point) so a concurrent auth-listener
    /// nil-ing of `authenticatedUserSub` can't turn cleanup into a no-op.
    private func clearOnDiskUserCaches(for userSub: String) {
        let prefix = "\(StorageKey.dailyReflectionPrefix)::\(userSub)::"
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
        // Ordering assumption: this actor job is enqueued immediately at
        // sign-out, seconds before any re-sign-in's beginSession could run;
        // worst case is in-memory-only and self-heals on relaunch.
        Task { await SnapshotStore.shared.deleteAll(for: userSub) }
    }

    private static func logicalDate() -> Date {
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour < 3 else { return Date() }
        return Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    }

    func checkAndFetchDailyReflection() {
        guard isAuthenticated, !accountDeletionPending else { return }
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
        let requestSub = authenticatedUserSub
        let epoch = consentEpoch
        reflectionFetchTask = Task { @MainActor in
            do {
                let result = try await apiClient.fetchDailyReflection()
                // User switched accounts mid-fetch — applying A's reflection
                // would render it in B's session and persist it to B's snapshot.
                guard !Task.isCancelled, self.aiConsentGiven, self.consentEpoch == epoch, self.authenticatedUserSub == requestSub else { return }
                self.dailyReflection = result
                await self.cacheReflection(result)
                Analytics.logEvent("reflection_viewed", parameters: ["source": "network"])
            } catch {
                guard !Task.isCancelled, self.authenticatedUserSub == requestSub,
                      self.consentEpoch == epoch else { return }
                self.handleAIConsentRejection(error)
                #if DEBUG
                print("[AppState] Daily reflection fetch failed")
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
        static let pendingWithdrawal = "walkworthy.ai.pendingWithdrawal.v1"
        static let pendingWithdrawalId = "walkworthy.ai.pendingWithdrawalId.v1"
        static let pendingAccountDeletions = "walkworthy.pendingAccountDeletions.v1"
        static let accountDeletionIntents = "walkworthy.accountDeletionIntents.v2"
        static let aiConsentGiven = "walkworthy.ai.consentGiven.v2"
        static let analyticsEnabled = "walkworthy.settings.analyticsOptIn.v2"
        static let dismissedNameBackfill = "walkworthy.dismissed.nameBackfill"
        static let hasCompletedProfileSetup = "walkworthy.profile.hasCompletedSetup"
        static let lastAuthenticatedUser = "walkworthy.auth.lastUser"
        static let dailyReflectionPrefix = "walkworthy.dailyReflection"
    }
}
