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

    private let tokenCache = TokenCache()

    init() {
        // Firebase Auth is automatically initialized via GoogleService-Info.plist
    }

    // MARK: - BearerTokenProviding

    func validBearerToken() async throws -> String {
        // Check cache first
        if let cached = tokenCache.cachedToken(), !cached.isExpired {
            return cached.token
        }

        // Fetch fresh token from Firebase
        guard let user = Auth.auth().currentUser else {
            throw AuthError.notAuthenticated
        }

        do {
            let token = try await user.getIDToken(forcingRefresh: true)
            tokenCache.cache(token: token, expiresAt: Date().addingTimeInterval(3600))
            return token
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
        tokenCache.clear()  // Clear any cached tokens from previous session
    }

    func createAccount(email: String, password: String) async throws {
        _ = try await Auth.auth().createUser(withEmail: email, password: password)
        tokenCache.clear()  // Clear any cached tokens
    }

    func signOut() async throws {
        try Auth.auth().signOut()
        tokenCache.clear()
    }

    // MARK: - Private

    /// Simple in-memory token cache to avoid excessive token refreshes
    private class TokenCache {
        struct CachedToken {
            let token: String
            let expiresAt: Date

            var isExpired: Bool {
                Date() >= expiresAt.addingTimeInterval(-30) // Refresh 30s before expiry
            }
        }

        private var cached: CachedToken?

        func cache(token: String, expiresAt: Date) {
            self.cached = CachedToken(token: token, expiresAt: expiresAt)
        }

        func cachedToken() -> CachedToken? {
            cached
        }

        func clear() {
            cached = nil
        }
    }
}
