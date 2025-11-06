//
//  AppState.swift
//  WalkWorthy
//
//  Central application state for the live WalkWorthy experience.
//

import Foundation
import SwiftUI
import Combine
import AuthenticationServices

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var verseDeck: [Verse]
    @Published private(set) var history: [Verse]
    @Published private(set) var currentVerseIndex: Int
    @Published var selectedTranslation: Translation
    @Published var showPopups: Bool
    @Published var isCanvasLinked: Bool
    @Published var onboardingCompleted: Bool
    @Published var useProfilePersonalization: Bool
    @Published var calendarAgenda: [CalendarAgendaItem]
    @Published var calendarAgendaFetchedAt: Date?
    @Published private(set) var calendarLinkStatus: CalendarLinkStatus?
    @Published private(set) var authenticatedUserSub: String?
    @Published var isAuthenticated: Bool {
        didSet {
            if !isAuthenticated {
                latestScanSummary = nil
                encouragementStatusMessage = nil
                latestScanError = nil
                hasFreshEncouragement = true
            }
        }
    }
    @Published var isScanning: Bool
    @Published var latestScanSummary: ScanLogSummary?
    @Published var latestScanError: String?
    @Published var encouragementStatusMessage: String?
    @Published var hasFreshEncouragement: Bool
    @Published var authenticationNotice: String?

    private let apiClient: any EncouragementAPI
    private let notificationScheduler: NotificationScheduler
    private let defaults: UserDefaults
    private let config: Config
    private let authSession: AuthSession?
    private static let userScopedKeys: Set<String> = [
        StorageKey.onboardingCompleted,
        StorageKey.useProfilePersonalization,
        StorageKey.canvasLinked,
        StorageKey.calendarLinkStatus,
        StorageKey.translation,
        StorageKey.currentVerseIndex,
        StorageKey.history,
        StorageKey.verseDeck,
        StorageKey.profileAge,
        StorageKey.profileMajor,
        StorageKey.profileGender,
        StorageKey.profileHobbies,
        StorageKey.profileOptIn,
    ]
    private lazy var signInCoordinator: HostedUISignInCoordinator? = {
        guard let authSession else { return nil }
        return HostedUISignInCoordinator(config: config, authSession: authSession)
    }()

    init(
        config: Config = .shared,
        apiClient: any EncouragementAPI,
        authSession: AuthSession? = nil,
        notificationScheduler: NotificationScheduler = .shared,
        defaults: UserDefaults = .standard
    ) {
        self.config = config
        self.apiClient = apiClient
        self.authSession = authSession
        self.notificationScheduler = notificationScheduler
        self.defaults = defaults
        self.isAuthenticated = false
        self.verseDeck = []
        self.history = []
        self.currentVerseIndex = 0
        self.selectedTranslation = config.defaultTranslation
        self.showPopups = false
        self.calendarAgenda = []
        self.calendarAgendaFetchedAt = nil
        self.calendarLinkStatus = nil
        self.authenticatedUserSub = nil
        self.isCanvasLinked = false
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
                if let authSession {
                    try? await authSession.signOut()
                }
            }
        }
    }

    var currentVerse: Verse {
        verseDeck[safe: currentVerseIndex] ?? verseDeck.first ?? Verse.placeholder
    }

    var weeklyCalendarAgenda: [CalendarAgendaItem] {
        guard let bounds = currentWeekBounds else { return calendarAgenda }
        return calendarAgenda
            .filter { item in
                guard let date = agendaDate(for: item) else { return false }
                return date >= bounds.start && date <= bounds.end
            }
            .sorted { lhs, rhs in
                let lhsDate = agendaDate(for: lhs) ?? .distantFuture
                let rhsDate = agendaDate(for: rhs) ?? .distantFuture
                if lhsDate == rhsDate {
                    return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
                }
                return lhsDate < rhsDate
            }
    }

    var currentWeekLabel: String {
        guard let bounds = currentWeekBounds else { return "This Week" }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        let startText = formatter.string(from: bounds.start)
        let endText = formatter.string(from: bounds.end)
        return "\(startText) – \(endText)"
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

    func updateProfile(age: Int?, major: String, gender: Gender, hobbies: Set<String>, optIn: Bool) {
        let trimmedMajor = major.trimmingCharacters(in: .whitespacesAndNewlines)
        if let age {
            defaults.set(age, forKey: storageKey(StorageKey.profileAge))
        } else {
            defaults.removeObject(forKey: storageKey(StorageKey.profileAge))
        }
        defaults.set(trimmedMajor, forKey: storageKey(StorageKey.profileMajor))
        defaults.set(gender.rawValue, forKey: storageKey(StorageKey.profileGender))
        defaults.set(Array(hobbies), forKey: storageKey(StorageKey.profileHobbies))
        defaults.set(optIn, forKey: storageKey(StorageKey.profileOptIn))

        syncProfile(age: age, major: trimmedMajor, gender: gender, hobbies: hobbies, optIn: optIn)
    }

    func loadProfile() -> OnboardingProfile {
        if authenticatedUserSub == nil {
            return OnboardingProfile(age: nil, major: "", gender: .male, hobbies: [], optIn: true)
        }

        let age = defaults.value(forKey: storageKey(StorageKey.profileAge)) as? Int
        let major = defaults.string(forKey: storageKey(StorageKey.profileMajor)) ?? ""
        let gender = Gender(rawValue: defaults.string(forKey: storageKey(StorageKey.profileGender)) ?? "") ?? .male
        let hobbies = Set(defaults.stringArray(forKey: storageKey(StorageKey.profileHobbies)) ?? [])
        let optIn = defaults.object(forKey: storageKey(StorageKey.profileOptIn)) as? Bool ?? true
        return OnboardingProfile(age: age, major: major, gender: gender, hobbies: hobbies, optIn: optIn)
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

    func refreshCalendarLinkStatus(force: Bool = false) async {
        guard isAuthenticated else { return }
        guard let requestUserSub = authenticatedUserSub else { return }

        print("[AppState] Refreshing calendar link status", force ? "(force)" : "")
        if !force {
            if let status = calendarLinkStatus, status.status == .active {
                print("[AppState] Skipping refresh; status already ACTIVE")
                return
            }
        }

        do {
            let status = try await apiClient.fetchCalendarLinkStatus()
            guard requestUserSub == authenticatedUserSub else {
                print("[AppState] Ignoring calendar status response for stale user context")
                return
            }
            print("[AppState] Calendar link status fetched", status.status.rawValue)
            updateStoredCalendarStatus(status)
        } catch {
            print("[AppState] Failed to refresh calendar link status: \(error)")
        }
    }

    @discardableResult
    func submitCalendarLink(_ urlString: String) async throws -> CalendarLinkStatus {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw CalendarLinkInputError.empty
        }
        guard let candidate = URL(string: trimmed) else {
            throw CalendarLinkInputError.invalidURL
        }

        guard let scheme = candidate.scheme?.lowercased(), ["https", "http"].contains(scheme) else {
            throw CalendarLinkInputError.unsupportedScheme
        }

        guard let host = candidate.host, !host.isEmpty else {
            throw CalendarLinkInputError.missingHost
        }

        guard trimmed.lowercased().contains(".ics") || candidate.path.lowercased().hasSuffix(".ics") else {
            throw CalendarLinkInputError.notICS
        }

        if let allowedHost = config.canvasBaseURL?.host?.lowercased() {
            let hostLower = host.lowercased()
            let allowed = hostLower == allowedHost || hostLower.hasSuffix(".\(allowedHost)")
            if !allowed {
                throw CalendarLinkInputError.disallowedHost(expected: allowedHost)
            }
        }

        guard isAuthenticated else {
            throw CalendarLinkInputError.authenticationRequired
        }

        guard let requestUserSub = authenticatedUserSub else {
            throw CalendarLinkInputError.authenticationRequired
        }

        do {
            print("[AppState] Submitting calendar link", trimmed)
            let status = try await apiClient.updateCalendarLink(CalendarLinkUpdateRequest(calendarUrl: trimmed))
            guard requestUserSub == authenticatedUserSub else {
                print("[AppState] Ignoring calendar link save for stale user context")
                throw CancellationError()
            }
            print("[AppState] Calendar link saved", status.status.rawValue)
            updateStoredCalendarStatus(status)
            await fetchCalendarAgenda()
            return status
        } catch {
            print("[AppState] Calendar link save failed: \(error)")
            throw error
        }
    }

    @discardableResult
    func removeCalendarLink() async -> Bool {
        print("[AppState] Removing calendar link")
        let requestUserSub = authenticatedUserSub
        defaults.removeObject(forKey: storageKey(StorageKey.canvasLinked))

        guard isAuthenticated else { return false }

        do {
            try await apiClient.deleteCalendarLink()
            guard requestUserSub == authenticatedUserSub else {
                print("[AppState] Ignoring calendar link removal for stale user context")
                return false
            }
        } catch {
            print("[AppState] Failed to delete calendar link: \(error)")
            return false
        }

        updateStoredCalendarStatus(nil)
        calendarAgenda = []
        calendarAgendaFetchedAt = nil
        return true
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
        guard let authSession else {
            isAuthenticated = false
            return
        }

        do {
            _ = try await authSession.validBearerToken()
            isAuthenticated = true
            authenticationNotice = nil
            await refreshAuthenticatedUser()
            await refreshCalendarLinkStatus(force: true)
        } catch {
            isAuthenticated = false
            authenticationNotice = "Your session has expired. Please sign in again."
            setAuthenticatedUserSub(nil)
        }
    }

    func startSignIn(anchor: ASPresentationAnchor?) async throws {
        guard let coordinator = signInCoordinator else {
            throw HostedUISignInCoordinator.SignInError.misconfigured
        }
        do {
            try await coordinator.startSignIn(from: anchor)
            isAuthenticated = true
            authenticationNotice = nil
            await refreshAuthenticatedUser()
            await refreshCalendarLinkStatus(force: true)
        } catch {
            isAuthenticated = false
            if authenticationNotice == nil {
                authenticationNotice = error.localizedDescription
            }
            setAuthenticatedUserSub(nil)
            throw error
        }
    }

    func signOut() {
        clearCalendarLinkState()

        Task {
            if let authSession {
                try? await authSession.signOut()
            }

            await MainActor.run { [self] in
                clearCalendarLinkState()
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

    func refreshEncouragementDeck() {
        guard isAuthenticated else { return }
        Task {
            do {
                let response = try await apiClient.fetchNext()
                if response.shouldNotify {
                    notificationScheduler.scheduleEncouragementNotification(response.payload)
                }

                if let payload = response.payload {
                    let verse = Verse(payload: payload)
                    await MainActor.run { [self, verse, response] in
                        upsertVerse(verse)
                        hasFreshEncouragement = true
                        encouragementStatusMessage = statusMessage(forMetadata: response.metadata) ?? encouragementStatusMessage
                        if let metadata = response.metadata {
                            latestScanSummary = metadata
                        }
                        latestScanError = nil
                    }
                } else {
                    await MainActor.run { [self, response] in
                        if let metadata = response.metadata {
                            latestScanSummary = metadata
                            encouragementStatusMessage = statusMessage(forMetadata: metadata)
                        } else if response.shouldNotify == false {
                            encouragementStatusMessage = "Scan for new encouragement."
                        }
                        hasFreshEncouragement = response.shouldNotify
                        latestScanError = nil
                    }
                }
            } catch {
                await MainActor.run { [self] in
                    latestScanError = error.localizedDescription
                }
                print("[AppState] Failed to fetch next encouragement: \(error)")
            }
        }
    }

    func refreshCalendarAgenda() {
        guard isAuthenticated else { return }
        Task { [weak self] in
            await self?.fetchCalendarAgenda()
        }
    }

    private func fetchCalendarAgenda() async {
        let requestUserSub = authenticatedUserSub
        do {
            let response = try await apiClient.fetchCalendarAgenda()
            guard requestUserSub == authenticatedUserSub else {
                print("[AppState] Ignoring calendar agenda response for stale user context")
                return
            }
            await MainActor.run { [self] in
                calendarAgenda = response.items
                calendarAgendaFetchedAt = response.fetchedAt
            }
        } catch {
            print("[AppState] Failed to fetch calendar agenda: \(error)")
        }
    }

    func triggerScanNow() {
        guard isAuthenticated else {
            latestScanError = "Please sign in before running a scan."
            return
        }

        isScanning = true
        latestScanError = nil

        Task {
            do {
                let response = try await apiClient.triggerScanNow()
                await MainActor.run { [self, response] in
                    isScanning = false
                    latestScanSummary = response.log ?? latestScanSummary
                    encouragementStatusMessage = message(for: response)
                    latestScanError = nil
                }
                refreshEncouragementDeck()
            } catch let apiError as APIError {
                await MainActor.run { [self] in
                    isScanning = false
                    switch apiError {
                    case .conflict(let message):
                        latestScanError = message ?? "Link your Canvas account to enable scans."
                    case .unauthorized, .notAuthenticated:
                        latestScanError = nil
                        isAuthenticated = false
                        authenticationNotice = "Your session has expired. Please sign in again."
                    default:
                        latestScanError = apiError.errorDescription ?? "Scan failed."
                    }
                }
            } catch {
                await MainActor.run { [self] in
                    isScanning = false
                    latestScanError = error.localizedDescription
                }
            }
        }
    }

    func clearHistory() {
        history.removeAll()
        defaults.removeObject(forKey: storageKey(StorageKey.history))
        persistVerseDeck()
    }

    private func updateStoredCalendarStatus(_ status: CalendarLinkStatus?) {
        calendarLinkStatus = status

        if authenticatedUserSub == nil {
            isCanvasLinked = status?.status == .active
            if status == nil {
                calendarAgenda = []
                calendarAgendaFetchedAt = nil
            }
            return
        }

        defaults.removeObject(forKey: storageKey(StorageKey.canvasLinked))

        if let status {
            isCanvasLinked = status.status == .active
            try? defaults.encode(status, forKey: storageKey(StorageKey.calendarLinkStatus))
            if status.status == .active {
                refreshCalendarAgenda()
            }
        } else {
            isCanvasLinked = false
            defaults.removeObject(forKey: storageKey(StorageKey.calendarLinkStatus))
            calendarAgenda = []
            calendarAgendaFetchedAt = nil
        }
    }

    private func clearCalendarLinkState() {
        updateStoredCalendarStatus(nil)
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
        guard let authSession else {
            setAuthenticatedUserSub(nil)
            return
        }

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
            isCanvasLinked = false
            calendarLinkStatus = nil
            selectedTranslation = config.defaultTranslation
            currentVerseIndex = 0
            history = []
            verseDeck = [Verse.placeholder]
            calendarAgenda = []
            calendarAgendaFetchedAt = nil
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

        if let storedStatus = try? defaults.decode(CalendarLinkStatus.self, forKey: storageKey(StorageKey.calendarLinkStatus)) {
            calendarLinkStatus = storedStatus
            isCanvasLinked = storedStatus.status == .active
        } else {
            calendarLinkStatus = nil
            isCanvasLinked = defaults.object(forKey: storageKey(StorageKey.canvasLinked)) as? Bool ?? false
            if defaults.object(forKey: storageKey(StorageKey.calendarLinkStatus)) != nil {
                defaults.removeObject(forKey: storageKey(StorageKey.calendarLinkStatus))
            }
        }

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
        if defaults.object(forKey: storageKey(StorageKey.profileMajor)) != nil { return true }
        if defaults.object(forKey: storageKey(StorageKey.profileGender)) != nil { return true }
        if defaults.object(forKey: storageKey(StorageKey.profileHobbies)) != nil { return true }
        if defaults.object(forKey: storageKey(StorageKey.profileOptIn)) != nil { return true }
        return false
    }

    private var currentWeekBounds: (start: Date, end: Date)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1 // Sunday
        let today = Date()
        guard let interval = calendar.dateInterval(of: .weekOfYear, for: today) else {
            return nil
        }
        let startOfWeek = calendar.startOfDay(for: interval.start)
        guard let endOfWeek = calendar.date(byAdding: DateComponents(day: 7, second: -1), to: startOfWeek) else {
            return nil
        }
        return (startOfWeek, endOfWeek)
    }

    private func agendaDate(for item: CalendarAgendaItem) -> Date? {
        item.dueAt ?? item.startAt ?? item.endAt
    }

    private func syncProfile(age: Int?, major: String, gender: Gender, hobbies: Set<String>, optIn: Bool) {
        guard isAuthenticated else { return }
        let profile = OnboardingProfile(age: age, major: major, gender: gender, hobbies: hobbies, optIn: optIn)
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
        let trimmedMajor = profile.major.trimmingCharacters(in: .whitespacesAndNewlines)
        let hobbies = profile.hobbies.sorted()
        let payload = RemoteUserProfileRequest(
            ageRange: ageRangeString(for: profile.age),
            major: trimmedMajor.isEmpty ? nil : trimmedMajor,
            gender: profile.gender.rawValue.lowercased(),
            hobbies: hobbies.isEmpty ? nil : hobbies,
            optInTailored: profile.optIn,
            translationPreference: selectedTranslation.rawValue
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

    private func message(for response: ScanNowResponse) -> String {
        switch response.status {
        case .success:
            return "Scan accepted. We'll deliver a new encouragement shortly."
        case .fallback:
            if let reason = response.log?.errorMessage, !reason.isEmpty {
                return "Fallback encouragement queued: \(reason)"
            }
            return "Fallback encouragement queued. We'll keep looking for a fresh verse."
        }
    }

    private func ageRangeString(for age: Int?) -> String? {
        guard let age else { return nil }
        switch age {
        case ..<18: return "under-18"
        case 18...22: return "18-22"
        case 23...30: return "23-30"
        case 31...40: return "31-40"
        case 41...55: return "41-55"
        case 56...65: return "56-65"
        default: return "65+"
        }
    }
}
extension AppState {
    enum StorageKey {
        static let onboardingCompleted = "walkworthy.onboardingCompleted"
        static let useProfilePersonalization = "walkworthy.settings.useProfilePersonalization"
        static let canvasLinked = "walkworthy.canvas.linked"
        static let calendarLinkStatus = "walkworthy.settings.calendarLinkStatus"
        static let translation = "walkworthy.settings.translation"
        static let currentVerseIndex = "walkworthy.home.currentVerseIndex"
        static let history = "walkworthy.history.verses"
        static let verseDeck = "walkworthy.home.verseDeck"
        static let profileAge = "walkworthy.profile.age"
        static let profileMajor = "walkworthy.profile.major"
        static let profileGender = "walkworthy.profile.gender"
        static let profileHobbies = "walkworthy.profile.hobbies"
        static let profileOptIn = "walkworthy.profile.optIn"
        static let lastAuthenticatedUser = "walkworthy.auth.lastUser"
    }

    enum CalendarLinkInputError: LocalizedError {
        case empty
        case invalidURL
        case unsupportedScheme
        case missingHost
        case notICS
        case disallowedHost(expected: String)
        case authenticationRequired

        var errorDescription: String? {
            switch self {
            case .empty:
                return "Paste your Canvas calendar link before saving."
            case .invalidURL:
                return "That doesn’t look like a valid URL. Please copy the full calendar link from Canvas."
            case .unsupportedScheme:
                return "Canvas calendar links must start with https:// for security."
            case .missingHost:
                return "The calendar link is missing a Canvas domain."
            case .notICS:
                return "Canvas calendar links end in .ics. Double-check you copied the Calendar Feed URL."
            case .disallowedHost(let expected):
                return "That link isn’t from your school’s Canvas domain (\(expected))."
            case .authenticationRequired:
                return "You’re signed out. Please sign in and try again."
            }
        }
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
