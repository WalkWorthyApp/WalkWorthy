import Foundation

// Avoid touching the operator's preferences. AppState still uses its real
// UserDefaults API calls against this in-memory implementation. The harness and
// AppState confine every access to MainActor; no parallel test fixtures run.
nonisolated final class MemoryDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    override func object(forKey key: String) -> Any? { values[key] }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
    override func dictionaryRepresentation() -> [String: Any] { values }
}

// The harness compiles the unmodified production AppState and domain models.
// These replacements keep auth, networking, notifications and snapshots local.
actor FirebaseAuthSession {
    private var userSub: String?
    private var signOutFails = false
    func use(_ sub: String?) { userSub = sub }
    func failSignOut(_ fails: Bool) { signOutFails = fails }
    func currentUserSub() throws -> String {
        guard let userSub else { throw APIError.notAuthenticated }
        return userSub
    }
    func observeAuthState(onChange: @escaping @Sendable (Bool) -> Void) {}
    func signIn(email: String, password: String) throws { userSub = email }
    func createAccount(email: String, password: String) throws { userSub = email }
    func signInWithApple(idToken: String, rawNonce: String, fullName: PersonNameComponents?) throws {}
    func signOut() throws {
        if signOutFails { throw APIError.invalidResponse }
        userSub = nil
    }
    func signOut(ifUserSub expectedSub: String) throws { if userSub == expectedSub { userSub = nil } }
    func sendEmailVerification() throws {}
    func needsEmailVerification(reload: Bool) -> Bool { false }
    func secondsSinceLastSignIn() -> TimeInterval? { 0 }
    func reauthenticate(password: String) throws {}
    func currentUserEmail() -> String? { nil }
    func usesAppleSignIn() -> Bool { false }
    func revokeAppleAuthorizationForDeletion() throws {}
    func validBearerToken(forcingRefresh: Bool) throws -> String { "test-only-unused" }
}

@MainActor
final class NotificationScheduler {
    static let shared = NotificationScheduler()
    func invalidateSession(for sub: String) {}
    func beginSession(for sub: String) {}
    func removeReminders(for sub: String, includingLegacy: Bool) async {}
}

struct Snapshot<T> { let payload: T }
enum SnapshotKind: String { case profile, moodStatus, dailyReflection, weekSummary, moodLogFirstPage }

@MainActor
final class SnapshotStore {
    static let shared = SnapshotStore()
    var data: [String: Data] = [:]
    var deletedUsers: [String] = []
    var beforeBegin: (() throws -> Void)?
    var beginError: Error?

    private func key(_ kind: SnapshotKind, _ userSub: String) -> String { "\(userSub)/\(kind.rawValue)" }
    func seed<T: Encodable>(_ value: T, kind: SnapshotKind, userSub: String) throws {
        data[key(kind, userSub)] = try JSONEncoder().encode(value)
    }
    func corrupt(kind: SnapshotKind, userSub: String) { data[key(kind, userSub)] = Data("broken".utf8) }
    func readSync<T: Decodable>(_ type: T.Type, kind: SnapshotKind, userSub: String, dateSuffix: String? = nil) -> Snapshot<T>? {
        guard let bytes = data[key(kind, userSub)], let payload = try? JSONDecoder().decode(type, from: bytes) else { return nil }
        return Snapshot(payload: payload)
    }
    func write<T: Encodable>(_ value: T, kind: SnapshotKind, userSub: String, dateSuffix: String? = nil) async {
        try! seed(value, kind: kind, userSub: userSub)
    }
    func beginSession(for sub: String) async {
        do { try beforeBegin?() } catch { beginError = error }
    }
    func deleteAll(for sub: String) async { deletedUsers.append(sub) }
    func deleteAllDurably(for sub: String) async throws { deletedUsers.append(sub) }
}

@MainActor
final class TestAPI: EncouragementAPI {
    var profile: RemoteUserProfileResponse?
    var heldProfile: CheckedContinuation<RemoteUserProfileResponse?, Error>?
    var holdProfile = false
    var status = MoodStatusResponse(status: "pending", pendingCheckIn: nil, checkIn: nil, summary: nil)
    var heldStatus: CheckedContinuation<MoodStatusResponse, Error>?
    var holdStatus = false
    var statusCalls = 0
    var deletion: (() async throws -> Void)?

    func fetchUserProfile() async throws -> RemoteUserProfileResponse? {
        if holdProfile { return try await withCheckedThrowingContinuation { heldProfile = $0 } }
        return profile
    }
    func fetchMoodStatus() async throws -> MoodStatusResponse {
        statusCalls += 1
        if holdStatus { return try await withCheckedThrowingContinuation { heldStatus = $0 } }
        return status
    }
    func fetchPrivacyConsent() async throws -> PrivacyConsent {
        .init(aiSharing: false, noticeVersion: "2026-09-04", ageGroup: "18+", revision: 1)
    }
    func updatePrivacyConsent(_ update: PrivacyConsentUpdate) async throws -> PrivacyConsent { try await fetchPrivacyConsent() }
    func updateUserProfile(_ payload: RemoteUserProfileRequest) async throws -> RemoteUserProfileResponse? { nil }
    func submitMoodCheckIn(_ request: MoodCheckInRequest) async throws -> MoodCheckInResponse { throw APIError.invalidResponse }
    func fetchMoodHistory(days: Int, startDate: String?, endDate: String?) async throws -> MoodHistoryResponse { .init(summaries: [], daysRequested: days) }
    func fetchMoodLogFullHistory(days: Int, endDate: String?) async throws -> MoodLogResponse { .init(checkIns: [], daysRequested: days) }
    func fetchDailyReflection() async throws -> DailyReflection { throw APIError.invalidResponse }
    func deleteAccount() async throws { try await deletion?() }
}
