import Foundation

// Shared by both harness executables.
struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure(description: message) }
}

@MainActor
func waitUntil(_ message: String, _ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(5))
    while !(await predicate()) {
        try check(ContinuousClock.now < deadline, message)
        await Task.yield()
    }
}

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

/// Firebase `User` stand-in: one object per sign-in, reused by token refresh
/// and re-authentication (which, as in Firebase, refreshes `authTime` in place).
final class FakeFirebaseUser {
    let uid: String
    let signIn: Int
    let isApple: Bool
    var authTime: Date
    init(uid: String, signIn: Int, isApple: Bool, authTime: Date) {
        self.uid = uid
        self.signIn = signIn
        self.isApple = isApple
        self.authTime = authTime
    }
}

enum FakeAuthError: Error { case wrongPassword, userMismatch, noAppleAccount }

/// Process-wide Firebase stand-in. The production credential binding runs
/// unchanged against it; hooks suspend token/App Check fetches for races.
@MainActor
enum FakeFirebase {
    static var currentUser: FakeFirebaseUser?
    static var signIns = 0
    static var credentials = SessionCredentialBinding<FakeFirebaseUser> { $0.uid }
    static var beforeToken: ((_ forcingRefresh: Bool) async -> Void)?
    static var beforeAppCheck: (() async -> Void)?
    static var beforeAuthTime: (() async -> Void)?
    static var beforeReauth: (() async -> Void)?
    /// Apple's sheet: suspend for races, or throw (e.g. the user cancels).
    static var appleSheet: (() async throws -> Void)?
    /// The Apple ID the sheet returns; Firebase rejects any other account.
    static var appleIDOnDevice: String?
    static var appleRevocations: [String] = []
    static var events: [String] = []

    static func reset() {
        currentUser = nil
        signIns = 0
        credentials = SessionCredentialBinding<FakeFirebaseUser> { $0.uid }
        beforeToken = nil
        beforeAppCheck = nil
        beforeAuthTime = nil
        beforeReauth = nil
        appleSheet = nil
        appleIDOnDevice = nil
        appleRevocations = []
        events = []
    }

    /// A new sign-in always creates a new user object, even for the same UID.
    static func signIn(_ uid: String, apple: Bool = false, authenticatedAgo: TimeInterval = 0) {
        signIns += 1
        currentUser = FakeFirebaseUser(uid: uid, signIn: signIns, isApple: apple,
                                       authTime: Date().addingTimeInterval(-authenticatedAgo))
        if apple { appleIDOnDevice = uid }
    }

    /// Carries the backend's recent-auth verdict (auth_time under 5 minutes)
    /// so the stub server can enforce it as `requestAccountDeletion` does.
    static func token(for user: FakeFirebaseUser) -> String {
        let recent = Date().timeIntervalSince(user.authTime) < 5 * 60
        return "token:\(user.uid):\(user.signIn):\(recent ? "recent" : "stale")"
    }
}

actor FirebaseAuthSession: BearerTokenProviding, AppCheckTokenProviding {
    private var signOutFails = false
    /// Restores or refreshes `sub`: keeps the existing sign-in for the same UID.
    func use(_ sub: String?) async {
        await MainActor.run {
            guard let sub else { FakeFirebase.currentUser = nil; return }
            if FakeFirebase.currentUser?.uid != sub { FakeFirebase.signIn(sub) }
        }
    }
    func failSignOut(_ fails: Bool) { signOutFails = fails }
    func currentUserSub() async throws -> String {
        guard let sub = await MainActor.run(body: { FakeFirebase.currentUser?.uid }) else { throw APIError.notAuthenticated }
        return sub
    }
    func observeAuthState(onChange: @escaping @Sendable (Bool) -> Void) {}
    func signIn(email: String, password: String) async throws { await MainActor.run { FakeFirebase.signIn(email) } }
    func createAccount(email: String, password: String) async throws { await MainActor.run { FakeFirebase.signIn(email) } }
    func signInWithApple(idToken: String, rawNonce: String, fullName: PersonNameComponents?) throws {}
    func signOut() async throws {
        if signOutFails { throw APIError.invalidResponse }
        await MainActor.run { FakeFirebase.currentUser = nil }
    }
    func signOut(ifUserSub expectedSub: String) async throws {
        await MainActor.run { if FakeFirebase.currentUser?.uid == expectedSub { FakeFirebase.currentUser = nil } }
    }
    func sendEmailVerification() throws {}
    func needsEmailVerification(reload: Bool) -> Bool { false }
    func currentUserEmail() -> String? { nil }

    // Session-bound deletion steps: same shape as production, which wraps each
    // Firebase call in the shared `SessionCredentialBinding.run`.
    @MainActor private func withOwner<T>(_ context: AuthenticatedRequestContext, _ body: (FakeFirebaseUser) async throws -> T) async throws -> T {
        try await FakeFirebase.credentials.run(for: context, currentUser: { FakeFirebase.currentUser }, body)
    }
    @MainActor func usesAppleSignIn(for context: AuthenticatedRequestContext) throws -> Bool {
        try FakeFirebase.credentials.owner(for: context, currentUser: FakeFirebase.currentUser).isApple
    }
    @MainActor func secondsSinceAuthentication(for context: AuthenticatedRequestContext) async throws -> TimeInterval {
        try await withOwner(context) { user in
            await FakeFirebase.beforeAuthTime?()
            return Date().timeIntervalSince(user.authTime)
        }
    }
    @MainActor func reauthenticate(password: String, for context: AuthenticatedRequestContext) async throws {
        try await withOwner(context) { user in
            await FakeFirebase.beforeReauth?()
            guard password == "correct horse" else { throw FakeAuthError.wrongPassword }
            user.authTime = Date()
            FakeFirebase.events.append("reauthenticate:\(user.uid)")
        }
    }
    @MainActor func reauthenticateAndRevokeApple(for context: AuthenticatedRequestContext) async throws {
        let appleID = try await withOwner(context) { _ in
            try await FakeFirebase.appleSheet?()
            guard let appleID = FakeFirebase.appleIDOnDevice else { throw FakeAuthError.noAppleAccount }
            return appleID
        }
        try await withOwner(context) { user in
            guard user.uid == appleID else { throw FakeAuthError.userMismatch }
            user.authTime = Date()
            FakeFirebase.events.append("reauthenticate:\(user.uid)")
        }
        try await withOwner(context) { user in
            FakeFirebase.appleRevocations.append(user.uid)
            FakeFirebase.events.append("revokeApple:\(user.uid)")
        }
    }

    // Same shape as production: ambient for context-free work, pinned otherwise.
    func validBearerToken(forcingRefresh: Bool) async throws -> String {
        await FakeFirebase.beforeToken?(forcingRefresh)
        guard let user = await MainActor.run(body: { FakeFirebase.currentUser }) else { throw APIError.notAuthenticated }
        return await FakeFirebase.token(for: user)
    }
    @MainActor func pinCredential(for session: AuthSessionIdentity) {
        FakeFirebase.credentials.pin(session, to: FakeFirebase.currentUser)
    }
    @MainActor func validateSession(for context: AuthenticatedRequestContext) throws {
        _ = try FakeFirebase.credentials.owner(for: context, currentUser: FakeFirebase.currentUser)
    }
    @MainActor func validBearerToken(for context: AuthenticatedRequestContext, forcingRefresh: Bool) async throws -> String {
        try await withOwner(context) { user in
            await FakeFirebase.beforeToken?(forcingRefresh)
            return FakeFirebase.token(for: user)
        }
    }
    func validAppCheckToken() async throws -> String {
        await FakeFirebase.beforeAppCheck?()
        return "app-check"
    }
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
    /// Account erasure only (deleteAllDurably), not sign-out cache cleanup.
    var erasedAccounts: [String] = []
    var beforeBegin: (() throws -> Void)?
    var beginError: Error?
    var beforeDurableDelete: (() throws -> Void)?

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
    func deleteAllDurably(for sub: String) async throws {
        try beforeDurableDelete?()
        deletedUsers.append(sub)
        erasedAccounts.append(sub)
    }
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
    func updateUserProfile(_ payload: RemoteUserProfileRequest, context: AuthenticatedRequestContext) async throws -> RemoteUserProfileResponse? { nil }
    func submitMoodCheckIn(_ request: MoodCheckInRequest) async throws -> MoodCheckInResponse { throw APIError.invalidResponse }
    func fetchMoodHistory(days: Int, startDate: String?, endDate: String?) async throws -> MoodHistoryResponse { .init(summaries: [], daysRequested: days) }
    func fetchMoodLogFullHistory(days: Int, endDate: String?) async throws -> MoodLogResponse { .init(checkIns: [], daysRequested: days) }
    func fetchDailyReflection() async throws -> DailyReflection { throw APIError.invalidResponse }
    func deleteAccount(context: AuthenticatedRequestContext) async throws { try await deletion?() }
}
