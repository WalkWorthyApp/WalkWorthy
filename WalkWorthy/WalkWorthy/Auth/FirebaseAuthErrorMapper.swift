//
//  FirebaseAuthErrorMapper.swift
//  WalkWorthy
//
//  Translates Firebase authentication errors into user-friendly messages with actionable suggestions.
//

import Foundation
import FirebaseAuth

struct AuthErrorDetails {
    let title: String
    let message: String
    let suggestion: String?

    var displayText: String {
        if let suggestion {
            return "\(message) \(suggestion)"
        }
        return message
    }
}

enum FirebaseAuthErrorMapper {
    static func mapError(_ error: Error) -> AuthErrorDetails {
        let nsError = error as NSError

        // Only map Firebase Auth errors; reject non-Firebase errors
        guard nsError.domain == AuthErrorDomain else {
            return AuthErrorDetails(
                title: "Unknown Error",
                message: error.localizedDescription.isEmpty ? "An unexpected error occurred." : error.localizedDescription,
                suggestion: "Please try again or contact support if the problem persists."
            )
        }

        // Handle Firebase Auth errors by code
        // Reference: https://firebase.google.com/docs/auth/troubleshoot-auth
        switch nsError.code {
        case AuthErrorCode.invalidEmail.rawValue:
            return AuthErrorDetails(
                title: "Invalid Email",
                message: "Please enter a valid email address.",
                suggestion: "Example: yourname@example.com"
            )

        case AuthErrorCode.userNotFound.rawValue:
            return AuthErrorDetails(
                title: "Account Not Found",
                message: "No account exists with this email.",
                suggestion: "Try creating a new account instead."
            )

        case AuthErrorCode.wrongPassword.rawValue:
            return AuthErrorDetails(
                title: "Incorrect Password",
                message: "The password you entered is incorrect.",
                suggestion: "Please try again. (You can reset it later if needed)"
            )

        case AuthErrorCode.emailAlreadyInUse.rawValue:
            return AuthErrorDetails(
                title: "Email Already Registered",
                message: "This email is already registered.",
                suggestion: "Try signing in instead, or use a different email."
            )

        case AuthErrorCode.weakPassword.rawValue:
            return AuthErrorDetails(
                title: "Weak Password",
                message: "Your password is too weak.",
                suggestion: "Use at least 6 characters with letters and numbers."
            )

        case AuthErrorCode.networkError.rawValue:
            return AuthErrorDetails(
                title: "Network Error",
                message: "Unable to connect. Please check your internet connection.",
                suggestion: "Try again when you have a stable connection."
            )

        case AuthErrorCode.tooManyRequests.rawValue:
            return AuthErrorDetails(
                title: "Too Many Attempts",
                message: "You've tried too many times. Please wait a moment.",
                suggestion: "Try again in a few minutes."
            )

        case AuthErrorCode.accountExistsWithDifferentCredential.rawValue:
            return AuthErrorDetails(
                title: "Account Exists",
                message: "An account with this email already exists.",
                suggestion: "Try signing in with a different method."
            )

        case AuthErrorCode.invalidCredential.rawValue:
            return AuthErrorDetails(
                title: "Invalid Credentials",
                message: "The credentials provided are invalid.",
                suggestion: "Please check your email and password and try again."
            )

        default:
            // Fallback for unknown errors
            return AuthErrorDetails(
                title: "Sign In Failed",
                message: error.localizedDescription.isEmpty ? "An error occurred during authentication." : error.localizedDescription,
                suggestion: "Please try again."
            )
        }
    }
}
