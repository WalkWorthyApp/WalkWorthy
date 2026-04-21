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

    func observeAuthState(onChange: @escaping @Sendable (Bool) -> Void) {
        guard authStateHandle == nil else { return }
        authStateHandle = Auth.auth().addStateDidChangeListener { _, user in
            onChange(user != nil)
        }
    }
}
