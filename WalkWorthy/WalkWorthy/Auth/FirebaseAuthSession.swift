//
//  FirebaseAuthSession.swift
//  WalkWorthy
//
//  Manages Firebase Authentication tokens and provides bearerTokens for API calls.
//

import Foundation
import FirebaseAuth
import FirebaseAppCheck
import AuthenticationServices

actor FirebaseAuthSession: BearerTokenProviding, AppCheckTokenProviding {
    enum AuthError: LocalizedError, Sendable {
        case notAuthenticated
        case tokenFetchFailed(String)
        case userNotFound
        case invalidAppleCredential

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "User is not authenticated. Please sign in."
            case .tokenFetchFailed(let message):
                return "Failed to get authentication token: \(message)"
            case .userNotFound:
                return "User not found."
            case .invalidAppleCredential:
                return "Apple Sign In returned an unexpected response. Please try again."
            }
        }
    }

    private var authStateHandle: AuthStateDidChangeListenerHandle?

    init() {
        // Firebase Auth is automatically initialized via GoogleService-Info.plist
    }

    // MARK: - BearerTokenProviding

    func validBearerToken(forcingRefresh: Bool) async throws -> String {
        guard let user = Auth.auth().currentUser else {
            throw AuthError.notAuthenticated
        }

        do {
            // Firebase SDK handles token caching and automatic refresh internally,
            // but callers can force a refresh (e.g. after a 401) to rule out a
            // mid-request expiration before surfacing the error to the user.
            return try await user.getIDToken(forcingRefresh: forcingRefresh)
        } catch {
            throw AuthError.tokenFetchFailed(error.localizedDescription)
        }
    }

    @MainActor private static let credentials = SessionCredentialBinding<User> { $0.uid }

    /// Pins the current Firebase sign-in to a new AppState session. Called
    /// synchronously wherever AppState creates a session.
    @MainActor
    func pinCredential(for session: AuthSessionIdentity) {
        Self.credentials.pin(session, to: Auth.auth().currentUser)
    }

    @MainActor
    func validateSession(for context: AuthenticatedRequestContext) throws {
        _ = try Self.credentials.owner(for: context, currentUser: Auth.auth().currentUser)
    }

    /// Fetches only the initiating sign-in's token; a later `currentUser`
    /// (another account, or a new sign-in as the same UID) never substitutes.
    @MainActor
    func validBearerToken(for context: AuthenticatedRequestContext, forcingRefresh: Bool) async throws -> String {
        do {
            return try await withOwner(context) { try await $0.getIDToken(forcingRefresh: forcingRefresh) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AuthError.tokenFetchFailed(error.localizedDescription)
        }
    }

    // MARK: - AppCheckTokenProviding

    func validAppCheckToken() async throws -> String {
        let result = try await AppCheck.appCheck().token(forcingRefresh: false)
        return result.token
    }

    // MARK: - Public Methods

    func currentUserSub() async throws -> String {
        guard let user = Auth.auth().currentUser else {
            throw AuthError.notAuthenticated
        }
        return user.uid
    }

    func signIn(email: String, password: String) async throws {
        _ = try await Auth.auth().signIn(withEmail: email, password: password)
    }

    func createAccount(email: String, password: String) async throws {
        _ = try await Auth.auth().createUser(withEmail: email, password: password)
    }

    func sendEmailVerification() async throws {
        guard let user = Auth.auth().currentUser else {
            throw AuthError.notAuthenticated
        }
        try await user.sendEmailVerification()
    }

    /// True when the signed-in account uses the email/password provider and
    /// the address hasn't been verified yet. Federated providers (Sign in
    /// with Apple) return false — their emails are verified upstream. Pass
    /// `reload: true` after the user taps "I've verified" so the check sees
    /// fresh server state instead of the cached user.
    func needsEmailVerification(reload: Bool) async -> Bool {
        guard let user = Auth.auth().currentUser else { return false }
        if reload { try? await user.reload() }
        let usesPassword = user.providerData.contains { $0.providerID == "password" }
        return usesPassword && !user.isEmailVerified
    }

    /// Exchanges an Apple identity token + raw nonce for a Firebase session.
    ///
    /// Used by both the view-model-driven `SignInWithAppleButton` path
    /// (which owns its own nonce via `SignInWithAppleCoordinator`'s static
    /// helpers) and the standalone coordinator path. The caller is
    /// responsible for presenting Apple's sheet; this method just bridges
    /// the returned credential into Firebase.
    ///
    /// `fullName` is populated only on the user's first Sign in with Apple
    /// for this app's bundle ID. Firebase's
    /// `appleCredential(withIDToken:rawNonce:fullName:)` overload will use it
    /// to set `displayName` on the Firebase user — a no-op on subsequent
    /// sign-ins, which is exactly the behavior we want.
    ///
    /// Required for App Store Guideline 4.8: any app offering email or
    /// third-party login must also offer Sign in with Apple.
    func signInWithApple(idToken: String,
                         rawNonce: String,
                         fullName: PersonNameComponents?) async throws {
        let firebaseCredential = OAuthProvider.appleCredential(
            withIDToken: idToken,
            rawNonce: rawNonce,
            fullName: fullName
        )
        _ = try await Auth.auth().signIn(with: firebaseCredential)
    }

    /// Convenience overload that drives the full flow through
    /// `SignInWithAppleCoordinator` — generates a nonce, presents Apple's
    /// sheet, and bridges the result into Firebase. Useful for callers that
    /// don't have a `SignInWithAppleButton` in hand (e.g. a plain action
    /// button, a UIKit host, or testing code paths).
    func signInWithApple() async throws {
        let coordinator = await SignInWithAppleCoordinator()
        let authorization = try await coordinator.authorize()

        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let idTokenData = credential.identityToken,
              let idToken = String(data: idTokenData, encoding: .utf8)
        else {
            throw AuthError.invalidAppleCredential
        }

        let rawNonce = await coordinator.rawNonce
        try await signInWithApple(idToken: idToken,
                                  rawNonce: rawNonce,
                                  fullName: credential.fullName)
    }

    func signOut() async throws {
        try Auth.auth().signOut()
    }

    /// Check and sign out without suspension so deletion of A cannot sign out B.
    func signOut(ifUserSub expectedSub: String) throws {
        guard Auth.auth().currentUser?.uid == expectedSub else { return }
        try Auth.auth().signOut()
    }

    /// Returns the current user's email, if any, for display on the email
    /// verification gate.
    func currentUserEmail() async -> String? {
        Auth.auth().currentUser?.email
    }

    // MARK: - Account deletion (bound to the confirming session)

    @MainActor
    private func withOwner<T>(
        _ context: AuthenticatedRequestContext,
        _ body: (User) async throws -> T
    ) async throws -> T {
        try await Self.credentials.run(for: context, currentUser: { Auth.auth().currentUser }, body)
    }

    /// Seconds since the owning sign-in last proved its credentials, from the
    /// ID token's `auth_time` — the claim the backend's recent-auth rule checks.
    @MainActor
    func secondsSinceAuthentication(for context: AuthenticatedRequestContext) async throws -> TimeInterval {
        try await withOwner(context) { user in
            Date().timeIntervalSince(try await user.getIDTokenResult(forcingRefresh: false).authDate)
        }
    }

    @MainActor
    func usesAppleSignIn(for context: AuthenticatedRequestContext) throws -> Bool {
        try Self.credentials.owner(for: context, currentUser: Auth.auth().currentUser)
            .providerData.contains { $0.providerID == "apple.com" }
    }

    /// Re-authenticates the owning sign-in with its password. Firebase keeps
    /// the same `User` and swaps in fresh tokens, so later requests carry a
    /// new `auth_time`. Firebase Auth errors (wrong password, network) propagate
    /// unchanged so the view layer can map them via `FirebaseAuthErrorMapper`.
    @MainActor
    func reauthenticate(password: String, for context: AuthenticatedRequestContext) async throws {
        try await withOwner(context) { user in
            guard let email = user.email else { throw AuthError.userNotFound }
            _ = try await user.reauthenticate(with: EmailAuthProvider.credential(withEmail: email, password: password))
        }
    }

    /// One Apple authorization first re-authenticates the owning sign-in (a
    /// fresh `auth_time` for the backend's recent-auth rule), then revokes Sign
    /// in with Apple — Firebase's documented deletion sequence. Firebase
    /// rejects a different Apple ID with `userMismatch`.
    @MainActor
    func reauthenticateAndRevokeApple(for context: AuthenticatedRequestContext) async throws {
        let coordinator = SignInWithAppleCoordinator()
        let authorization = try await withOwner(context) { _ in try await coordinator.authorize() }
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let idTokenData = credential.identityToken,
              let idToken = String(data: idTokenData, encoding: .utf8),
              let codeData = credential.authorizationCode,
              let authorizationCode = String(data: codeData, encoding: .utf8),
              !authorizationCode.isEmpty
        else {
            throw AuthError.invalidAppleCredential
        }
        let appleCredential = OAuthProvider.appleCredential(
            withIDToken: idToken,
            rawNonce: coordinator.rawNonce,
            fullName: nil
        )
        try await withOwner(context) { user in _ = try await user.reauthenticate(with: appleCredential) }
        try await withOwner(context) { _ in try await Auth.auth().revokeToken(withAuthorizationCode: authorizationCode) }
    }

    func observeAuthState(onChange: @escaping @Sendable (Bool) -> Void) {
        guard authStateHandle == nil else { return }
        authStateHandle = Auth.auth().addStateDidChangeListener { _, user in
            onChange(user != nil)
        }
    }
}
