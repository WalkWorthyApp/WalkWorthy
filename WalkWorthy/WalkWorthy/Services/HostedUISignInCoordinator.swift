//
//  HostedUISignInCoordinator.swift
//  WalkWorthy
//
//  Wraps the Cognito Hosted UI sign-in flow in a reusable helper.
//

import Foundation
import AuthenticationServices
import UIKit

@MainActor
final class HostedUISignInCoordinator: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum SignInError: LocalizedError {
        case misconfigured
        case unableToStart
        case cancelled
        case missingAuthorization
        case stateMismatch
        case backend(String?)

        var errorDescription: String? {
            switch self {
            case .misconfigured:
                return "Cognito Hosted UI configuration is incomplete."
            case .unableToStart:
                return "Unable to present the sign-in flow."
            case .cancelled:
                return "Sign-in was cancelled."
            case .missingAuthorization:
                return "Cognito did not return an authorization code."
            case .stateMismatch:
                return "The sign-in response could not be validated."
            case .backend(let message):
                return message ?? "Failed to complete Cognito sign-in."
            }
        }
    }

    private let config: Config
    private let authSession: AuthSession
    private weak var anchorWindow: ASPresentationAnchor?
    private var webSession: ASWebAuthenticationSession?
    private var expectedState: String?

    init(config: Config, authSession: AuthSession) {
        self.config = config
        self.authSession = authSession
    }

    func startSignIn(from anchor: ASPresentationAnchor?) async throws {
        guard let redirectURI = config.cognitoRedirectURI else {
            throw SignInError.misconfigured
        }

        guard let authorizationURL = await buildAuthorizationURL() else {
            throw SignInError.misconfigured
        }

        anchorWindow = anchor ?? firstAvailableAnchor()

        let callbackURL = try await performWebAuthentication(url: authorizationURL, callbackScheme: redirectURI.scheme)
        let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)

        if let error = components?.queryItems?.first(where: { $0.name == "error" })?.value {
            if error == "access_denied" {
                throw SignInError.cancelled
            }
            throw SignInError.backend(error)
        }

        guard let code = components?.queryItems?.first(where: { $0.name == "code" })?.value,
              let state = components?.queryItems?.first(where: { $0.name == "state" })?.value else {
            throw SignInError.missingAuthorization
        }

        guard state == expectedState else {
            throw SignInError.stateMismatch
        }

        _ = try await authSession.exchangeAuthorizationCode(code)
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        if let anchorWindow {
            return anchorWindow
        }
        if let fallback = firstAvailableAnchor() {
            self.anchorWindow = fallback
            return fallback
        }
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            let anchor = ASPresentationAnchor(windowScene: scene)
            self.anchorWindow = anchor
            return anchor
        }

        if #available(iOS 26.0, *) {
            preconditionFailure("No UIWindowScene available to present the Hosted UI session.")
        } else {
            let window = UIWindow()
            self.anchorWindow = window
            return window
        }
    }

    // MARK: - Helpers

    private func buildAuthorizationURL() async -> URL? {
        let state = UUID().uuidString
        expectedState = state
        guard
            let base = config.cognitoDomain,
            let clientId = config.cognitoClientId,
            let redirect = config.cognitoRedirectURI?.absoluteString
        else {
            return nil
        }

        let scopes = ["email", "openid", "phone"].joined(separator: " ")

        var components = URLComponents(url: base.appendingPathComponent("login/continue"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: scopes),
            URLQueryItem(name: "redirect_uri", value: redirect),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "lang", value: Locale.current.language.languageCode?.identifier ?? "en"),
        ]

        if let url = components?.url {
            print("Opening Hosted UI:", url.absoluteString)
            return url
        }

        return nil
    }

    private func performWebAuthentication(url: URL, callbackScheme: String?) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
                self?.webSession = nil

                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: SignInError.cancelled)
                    return
                }

                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let callbackURL else {
                    continuation.resume(throwing: SignInError.missingAuthorization)
                    return
                }

                continuation.resume(returning: callbackURL)
            }

            session.prefersEphemeralWebBrowserSession = true
            session.presentationContextProvider = self

            guard session.start() else {
                continuation.resume(throwing: SignInError.unableToStart)
                return
            }

            self.webSession = session
        }
    }

    private func firstAvailableAnchor() -> ASPresentationAnchor? {
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow }) {
            return window
        }
        if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            return ASPresentationAnchor(windowScene: scene)
        }
        return nil
    }
}
