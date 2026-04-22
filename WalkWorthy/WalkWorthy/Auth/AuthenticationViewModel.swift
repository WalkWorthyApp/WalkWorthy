//
//  AuthenticationViewModel.swift
//  WalkWorthy
//
//  Manages email/password authentication state and logic.
//

import SwiftUI
import Combine
import AuthenticationServices

@MainActor
final class AuthenticationViewModel: ObservableObject {
    enum AuthMode {
        case signIn
        case createAccount

        var title: String {
            switch self {
            case .signIn:
                return "Sign In"
            case .createAccount:
                return "Create Account"
            }
        }

        var submitButtonLabel: String {
            switch self {
            case .signIn:
                return "Sign In"
            case .createAccount:
                return "Create Account"
            }
        }
    }

    @Published var email: String = ""
    @Published var password: String = ""
    @Published var isLoading: Bool = false
    @Published var errorDetails: AuthErrorDetails?
    @Published var mode: AuthMode = .signIn
    @Published var showPassword: Bool = false

    private let appState: AppState

    init(appState: AppState) {
        self.appState = appState
        // Email recall is handled by iOS via `.textContentType(.emailAddress)`
        // + iCloud Keychain autofill on the SignInFormView. Storing a copy in
        // UserDefaults leaks across accounts on shared devices, so we don't.
    }

    /// Validates email and password inputs
    private func validateInputs() -> Bool {
        errorDetails = nil

        // Validate email
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedEmail.isEmpty {
            errorDetails = AuthErrorDetails(
                title: "Email Required",
                message: "Please enter your email address.",
                suggestion: nil
            )
            return false
        }

        // Basic email format validation
        if !trimmedEmail.contains("@") || !trimmedEmail.contains(".") {
            errorDetails = AuthErrorDetails(
                title: "Invalid Email",
                message: "Please enter a valid email address.",
                suggestion: "Example: yourname@example.com"
            )
            return false
        }

        // Validate password
        if password.isEmpty {
            errorDetails = AuthErrorDetails(
                title: "Password Required",
                message: "Please enter your password.",
                suggestion: nil
            )
            return false
        }

        // Password length validation for account creation
        if mode == .createAccount && password.count < 6 {
            errorDetails = AuthErrorDetails(
                title: "Weak Password",
                message: "Password must be at least 6 characters.",
                suggestion: nil
            )
            return false
        }

        return true
    }

    /// Attempts authentication (sign-in or account creation)
    func authenticate() async {
        guard validateInputs() else { return }

        isLoading = true
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)

        defer {
            isLoading = false
        }

        do {
            switch mode {
            case .signIn:
                try await appState.startSignIn(email: trimmedEmail, password: password)
            case .createAccount:
                try await appState.createAccount(email: trimmedEmail, password: password)
            }

            // Success - RootView will handle navigation to OnboardingForm
        } catch {
            // Translate Firebase error to user-friendly message
            errorDetails = FirebaseAuthErrorMapper.mapError(error)
        }
    }

    /// Raw (unhashed) nonce for the in-flight Sign in with Apple request.
    /// Generated in `configureAppleRequest` and consumed in
    /// `handleAppleAuthorizationResult`. Nil between requests.
    ///
    /// We must retain this value between the `onRequest` and `onCompletion`
    /// callbacks because Firebase's `OAuthProvider.appleCredential(...)`
    /// requires it to verify that Apple's returned identity token was signed
    /// over our hash of the same nonce — proof the token wasn't replayed.
    private var pendingAppleRawNonce: String?

    /// Configures an `ASAuthorizationAppleIDRequest` for Sign in with Apple.
    /// Called from `SignInWithAppleButton`'s `onRequest` closure. Generates a
    /// random nonce, stashes it for the completion handler, and sets the
    /// hashed nonce on the request alongside the requested scopes.
    func configureAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = SignInWithAppleCoordinator.generateRawNonce()
        pendingAppleRawNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = SignInWithAppleCoordinator.sha256(nonce)
    }

    /// Completes a Sign in with Apple flow once Apple's sheet has resolved.
    /// Handles three outcomes:
    ///   1. User cancelled the sheet — silently no-op (not an error).
    ///   2. Apple returned an unusable credential — surface a friendly error.
    ///   3. Success — exchange the identity token + raw nonce for a Firebase
    ///      session, mapping any Firebase errors through
    ///      `FirebaseAuthErrorMapper` for consistency with email/password.
    func handleAppleAuthorizationResult(_ result: Result<ASAuthorization, Error>) async {
        errorDetails = nil

        switch result {
        case .failure(let error):
            pendingAppleRawNonce = nil
            if let authError = error as? ASAuthorizationError, authError.code == .canceled {
                // User dismissed Apple's sheet. Not worth surfacing.
                return
            }
            errorDetails = FirebaseAuthErrorMapper.mapError(error)

        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let idTokenData = credential.identityToken,
                  let idToken = String(data: idTokenData, encoding: .utf8),
                  let rawNonce = pendingAppleRawNonce
            else {
                pendingAppleRawNonce = nil
                errorDetails = AuthErrorDetails(
                    title: "Apple Sign In Failed",
                    message: "Apple returned an unexpected response.",
                    suggestion: "Please try again, or use email sign-in instead."
                )
                return
            }
            // Single-use nonce — clear before the network call so a retry
            // regenerates a fresh one even if the call throws.
            pendingAppleRawNonce = nil

            isLoading = true
            defer { isLoading = false }

            do {
                try await appState.signInWithApple(idToken: idToken,
                                                   rawNonce: rawNonce,
                                                   fullName: credential.fullName)
                // Success - RootView will handle navigation to OnboardingForm.
            } catch {
                errorDetails = FirebaseAuthErrorMapper.mapError(error)
            }
        }
    }

    /// Toggle between sign-in and account creation modes
    func toggleMode() {
        mode = mode == .signIn ? .createAccount : .signIn
        // Clear error when switching modes
        errorDetails = nil
    }

    /// Clear the current error
    func clearError() {
        errorDetails = nil
    }

    /// Toggle password visibility
    func togglePasswordVisibility() {
        showPassword.toggle()
    }
}
