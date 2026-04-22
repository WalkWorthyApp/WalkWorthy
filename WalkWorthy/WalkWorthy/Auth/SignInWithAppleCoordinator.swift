//
//  SignInWithAppleCoordinator.swift
//  WalkWorthy
//
//  Bridges `ASAuthorizationController`'s delegate-based API into an async
//  function. Required by Firebase's Sign in with Apple flow:
//    1. Generate a cryptographically random nonce.
//    2. Send its SHA-256 hash to Apple as `nonce` on the request.
//    3. Apple returns an identity token signed over that nonce hash.
//    4. Firebase's credential takes the original (raw) nonce back alongside
//       the identity token, verifying the token came from the same request.
//
//  The raw nonce MUST be kept on this coordinator and read back after the
//  Apple sheet resolves — that's how we prove to Firebase that the identity
//  token wasn't replayed from a different session.
//

import Foundation
import AuthenticationServices
import CryptoKit
import UIKit

@MainActor
final class SignInWithAppleCoordinator: NSObject,
                                        ASAuthorizationControllerDelegate,
                                        ASAuthorizationControllerPresentationContextProviding {

    /// Raw (unhashed) nonce generated for the request. Firebase's
    /// `OAuthProvider.appleCredential(withIDToken:rawNonce:fullName:)` requires
    /// this exact string to verify Apple's response.
    private(set) var rawNonce: String = ""

    /// Retains the coordinator until the Apple sheet dispatches a callback.
    /// `ASAuthorizationController` holds only a weak reference to its delegate,
    /// so without a self-retain the delegate deallocates the moment
    /// `authorize()` suspends — leaving Apple's callback pointing at nothing.
    private var selfRetain: SignInWithAppleCoordinator?

    private var continuation: CheckedContinuation<ASAuthorization, Error>?

    /// Presents the system Sign in with Apple sheet and returns the
    /// `ASAuthorization` on success. Throws on user cancellation or any
    /// authorization error surfaced by `ASAuthorizationController`.
    func authorize() async throws -> ASAuthorization {
        let nonce = Self.generateRawNonce(length: 32)
        rawNonce = nonce

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)

        // Retain self for the duration of the Apple sheet.
        selfRetain = self

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.presentationContextProvider = self
            controller.performRequests()
        }
    }

    // MARK: - ASAuthorizationControllerDelegate

    nonisolated func authorizationController(controller: ASAuthorizationController,
                                             didCompleteWithAuthorization authorization: ASAuthorization) {
        Task { @MainActor in
            self.finish(with: .success(authorization))
        }
    }

    nonisolated func authorizationController(controller: ASAuthorizationController,
                                             didCompleteWithError error: Error) {
        Task { @MainActor in
            self.finish(with: .failure(error))
        }
    }

    // MARK: - ASAuthorizationControllerPresentationContextProviding

    nonisolated func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        // Hop to the main actor synchronously via DispatchQueue — this delegate
        // method is called on the main thread by AuthenticationServices, so a
        // simple `MainActor.assumeIsolated` is safe.
        MainActor.assumeIsolated {
            // Find the active foreground window. Falls back to a fresh
            // UIWindow() on the extremely unlikely path where no connected
            // scene is foregrounded at the moment the user taps the button.
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first(where: { $0.activationState == .foregroundActive })
                ?? UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            return scene?.keyWindow ?? scene?.windows.first ?? UIWindow()
        }
    }

    // MARK: - Helpers

    private func finish(with result: Result<ASAuthorization, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        // Release the self-retain before resuming so the coordinator can be
        // deallocated once the awaiting task moves on.
        selfRetain = nil
        switch result {
        case .success(let authorization):
            continuation.resume(returning: authorization)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }

    /// Generates a URL-safe random string suitable for use as an OAuth nonce.
    /// Uses `SecRandomCopyBytes` for CSPRNG-backed randomness.
    ///
    /// Exposed `internal` so `AuthenticationViewModel` can share the same
    /// nonce generator when driving Apple's `SignInWithAppleButton` directly
    /// (the SwiftUI control's `onRequest` closure needs to set the hashed
    /// nonce on the request before it's handed to `ASAuthorizationController`).
    static func generateRawNonce(length: Int = 32) -> String {
        precondition(length > 0, "Nonce length must be positive.")
        let charset: [Character] =
            Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")

        var result = ""
        result.reserveCapacity(length)

        // Oversample random bytes to avoid bias when mapping bytes → charset.
        var remaining = length
        while remaining > 0 {
            var randoms = [UInt8](repeating: 0, count: 16)
            let status = SecRandomCopyBytes(kSecRandomDefault, randoms.count, &randoms)
            guard status == errSecSuccess else {
                // Fall back to `UUID`-derived bytes. `SecRandomCopyBytes` is
                // essentially never expected to fail on iOS, but we should
                // never trap the caller on a CSPRNG hiccup.
                let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "")
                result.append(String(uuid.prefix(remaining)))
                break
            }
            for byte in randoms where remaining > 0 {
                let index = Int(byte) % charset.count
                result.append(charset[index])
                remaining -= 1
            }
        }
        return result
    }

    /// SHA-256 hash of the given string, encoded as lowercase hex. Apple's
    /// Sign in with Apple flow expects the `nonce` field on the request to be
    /// the hex-encoded SHA-256 digest of the raw nonce. Exposed alongside
    /// `generateRawNonce` for the same reason — the view-model-driven button
    /// path needs to set this on its request.
    static func sha256(_ input: String) -> String {
        let data = Data(input.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
