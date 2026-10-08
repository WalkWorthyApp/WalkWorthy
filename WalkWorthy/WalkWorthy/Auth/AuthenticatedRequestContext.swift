import Foundation

/// Carries the initiating session and its existing authority through a request.
/// The closure observes AppState; this value owns no session lifecycle or epoch.
nonisolated struct AuthenticatedRequestContext: Sendable {
    let identity: AuthSessionIdentity
    private let isCurrent: @MainActor @Sendable () -> Bool

    init(identity: AuthSessionIdentity, isCurrent: @escaping @MainActor @Sendable () -> Bool) {
        self.identity = identity
        self.isCurrent = isCurrent
    }

    @MainActor
    func checkValidity() throws {
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
    }
}
