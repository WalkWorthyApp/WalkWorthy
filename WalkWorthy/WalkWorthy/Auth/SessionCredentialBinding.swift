import Foundation

/// Binds account-owned requests to the sign-in that began their session.
///
/// Firebase reuses one `User` object for a sign-in — token refresh, `reload()`
/// and `reauthenticate(with:)` mutate it in place — and creates a new object for
/// every sign-in (firebase-ios-sdk 12.7.0). Pinning that object to a session
/// generation distinguishes sign-out → sign-in as the same UID even before
/// AppState observes it. Weak references never match a later object.
///
/// Generic over the user type so the host harness runs this exact logic.
@MainActor
final class SessionCredentialBinding<User: AnyObject> {
    private final class Pin {
        weak var user: User?
        init(_ user: User) { self.user = user }
    }

    private var pins: [UUID: Pin] = [:]
    private let uid: (User) -> String

    init(uid: @escaping (User) -> String) {
        self.uid = uid
    }

    /// Call synchronously when AppState creates `session` for `currentUser`.
    func pin(_ session: AuthSessionIdentity, to currentUser: User?) {
        pins = pins.filter { $0.value.user != nil }
        guard let currentUser, uid(currentUser) == session.userSub else { return }
        pins[session.generation] = Pin(currentUser)
    }

    /// The sign-in that owns `context`, while AppState still considers it
    /// current and Firebase still holds that same sign-in.
    func owner(for context: AuthenticatedRequestContext, currentUser: User?) throws -> User {
        try context.checkValidity()
        guard let currentUser, pins[context.identity.generation]?.user === currentUser else {
            throw CancellationError()
        }
        return currentUser
    }

    /// Runs `body` against the owning sign-in only, revalidating after the
    /// await. A failure after a switch is cancellation, not an auth error.
    func run<T>(
        for context: AuthenticatedRequestContext,
        currentUser: () -> User?,
        _ body: (User) async throws -> T
    ) async throws -> T {
        let owner = try owner(for: context, currentUser: currentUser())
        do {
            let result = try await body(owner)
            _ = try self.owner(for: context, currentUser: currentUser())
            return result
        } catch {
            _ = try self.owner(for: context, currentUser: currentUser())
            throw error
        }
    }
}
