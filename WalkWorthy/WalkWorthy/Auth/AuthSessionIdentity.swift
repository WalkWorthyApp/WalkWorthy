import Foundation

/// Ownership of work started during one authenticated account session.
/// UID alone cannot distinguish A → B → A or sign-out → sign-in as A.
/// Capture the whole value before suspension, then ask AppState whether it
/// is still current before publishing. This does not bind a network credential.
nonisolated struct AuthSessionIdentity: Hashable, Sendable {
    let userSub: String
    let generation: UUID

    init(userSub: String) {
        self.userSub = userSub
        self.generation = UUID()
    }
}
