//
//  FirebaseAuthSession.swift
//  WalkWorthy
//
//  Manages Firebase Authentication tokens and provides bearerTokens for API calls.
//

import Foundation
import FirebaseAuth
import FirebaseAppCheck

actor FirebaseAuthSession: BearerTokenProviding, AppCheckTokenProviding {
    enum AuthError: LocalizedError, Sendable {
        case notAuthenticated
        case tokenFetchFailed(String)
        case userNotFound

        var errorDescription: String? {
            switch self {
            case .notAuthenticated:
                return "User is not authenticated. Please sign in."
            case .tokenFetchFailed(let message):
                return "Failed to get authentication token: \(message)"
            case .userNotFound:
                return "User not found."
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

    func signOut() async throws {
        try Auth.auth().signOut()
    }

    /// Returns the current user's email, if any. Used by the account-deletion
    /// re-auth sheet to build an `EmailAuthProvider` credential without asking
    /// the user to retype their email.
    func currentUserEmail() async -> String? {
        Auth.auth().currentUser?.email
    }

    /// Number of seconds since the current user's last successful sign-in.
    /// Returns `nil` when no user is signed in or the metadata is unavailable.
    /// Used to decide whether `user.delete()` requires re-authentication —
    /// Firebase rejects delete/password-change requests on stale sessions.
    func secondsSinceLastSignIn() async -> TimeInterval? {
        guard let lastSignIn = Auth.auth().currentUser?.metadata.lastSignInDate else {
            return nil
        }
        return Date().timeIntervalSince(lastSignIn)
    }

    /// Re-authenticate the signed-in user with their email + password. Required
    /// before a destructive action (account deletion) when the session is
    /// older than Firebase's sensitive-operation window.
    ///
    /// Throws `AuthError.notAuthenticated` if no user is currently signed in,
    /// or `AuthError.userNotFound` if the signed-in user has no email on file
    /// (shouldn't happen for email/password accounts but guards against future
    /// phone/social providers). Firebase Auth errors (wrong password, network
    /// failure, etc.) propagate unchanged so the view layer can surface them
    /// via `FirebaseAuthErrorMapper`.
    func reauthenticate(password: String) async throws {
        guard let user = Auth.auth().currentUser else {
            throw AuthError.notAuthenticated
        }
        guard let email = user.email else {
            throw AuthError.userNotFound
        }
        let credential = EmailAuthProvider.credential(withEmail: email, password: password)
        _ = try await user.reauthenticate(with: credential)
    }

    func observeAuthState(onChange: @escaping @Sendable (Bool) -> Void) {
        guard authStateHandle == nil else { return }
        authStateHandle = Auth.auth().addStateDidChangeListener { _, user in
            onChange(user != nil)
        }
    }
}
