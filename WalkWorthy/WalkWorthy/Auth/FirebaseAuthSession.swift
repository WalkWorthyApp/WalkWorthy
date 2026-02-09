//
//  FirebaseAuthSession.swift
//  WalkWorthy
//
//  Manages Firebase Authentication tokens and provides bearerTokens for API calls.
//

import Foundation
import FirebaseAuth

actor FirebaseAuthSession: BearerTokenProviding {
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

    init() {
        // Firebase Auth is automatically initialized via GoogleService-Info.plist
    }

    // MARK: - BearerTokenProviding

    func validBearerToken() async throws -> String {
        guard let user = Auth.auth().currentUser else {
            throw AuthError.notAuthenticated
        }

        do {
            // Firebase SDK handles token caching and automatic refresh internally
            return try await user.getIDToken(forcingRefresh: false)
        } catch {
            throw AuthError.tokenFetchFailed(error.localizedDescription)
        }
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
}
