//
//  AuthenticationViewModel.swift
//  WalkWorthy
//
//  Manages email/password authentication state and logic.
//

import SwiftUI
import Combine

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
        // Load last saved email
        self.email = LastEmailStorage.loadEmail() ?? ""
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
        if mode == .createAccount && password.count < 8 {
            errorDetails = AuthErrorDetails(
                title: "Weak Password",
                message: "Password must be at least 8 characters.",
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
            // Save email before attempting auth
            LastEmailStorage.saveEmail(trimmedEmail)

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
