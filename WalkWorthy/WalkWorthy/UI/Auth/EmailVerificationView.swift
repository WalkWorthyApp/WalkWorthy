//
//  EmailVerificationView.swift
//  WalkWorthy
//
//  Full-screen gate shown to email/password accounts until their address is
//  verified (RootView blocks the main UI; the backend independently rejects
//  unverified tokens with 403 EMAIL_UNVERIFIED). Sign in with Apple accounts
//  never see this — Apple verifies emails upstream.
//
//  The user types the 6-digit code from the email right here, so they never
//  have to leave the app. iOS offers the code from Mail above the keyboard.
//

import SwiftUI

struct EmailVerificationView: View {
    @EnvironmentObject private var appState: AppState

    @State private var email: String?
    @State private var code = ""
    @State private var isWorking = false
    @State private var notice: String?
    @FocusState private var codeFieldFocused: Bool

    private static let codeLength = 6

    // Account deletion must stay reachable pre-verification (App Store
    // Guideline 5.1.1(v)) — the main Settings screen is behind this gate,
    // so the gate itself starts RootView's session-bound ceremony.
    @EnvironmentObject private var deletionFlow: AccountDeletionFlow

    var body: some View {
        ZStack {
            TimeOfDayTheme.current.backdrop
                .ignoresSafeArea()

            // Scrollable so the card and buttons stay reachable above the
            // number pad on small phones (see KeyboardAvoidance.swift).
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: scaled(20)) {
                        Spacer(minLength: scaled(24))

                        VStack(alignment: .leading, spacing: scaled(14)) {
                            Label("Verify your email", systemImage: "envelope.badge")
                                .font(.newsreaderSemiBoldItalic(size: scaled(28)))
                                .accessibilityAddTraits(.isHeader)

                            Text("We sent a 6-digit code to \(email ?? "your email address"). Enter it below to finish setting up your account.")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.85))

                            TextField("", text: $code, prompt: Text("000000").foregroundStyle(.white.opacity(0.35)))
                                .textContentType(.oneTimeCode)
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.center)
                                .font(.system(size: scaled(32), weight: .semibold, design: .monospaced))
                                .tracking(scaled(8))
                                .padding(.vertical, scaled(12))
                                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: scaled(14)))
                                .focused($codeFieldFocused)
                                .disabled(isWorking)
                                .accessibilityLabel("Verification code")
                                .onChange(of: code) { _, newValue in
                                    let digits = String(newValue.filter(\.isNumber).prefix(Self.codeLength))
                                    if digits != newValue {
                                        code = digits
                                        return
                                    }
                                    // AutoFill and paste deliver all six digits at once;
                                    // submit them without an extra tap.
                                    if digits.count == Self.codeLength { submitCode() }
                                }

                            if let notice {
                                Text(notice)
                                    .font(.footnote)
                                    .foregroundStyle(.white.opacity(0.75))
                            }

                            Button {
                                submitCode()
                            } label: {
                                Text("Verify")
                                    .fontWeight(.semibold)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, scaled(14))
                                    .background(Color.white, in: Capsule())
                                    .foregroundStyle(.black)
                            }
                            .disabled(isWorking || code.count != Self.codeLength)
                            .accessibilityHint("Checks the code from your email")

                            Button {
                                resend()
                            } label: {
                                Text("Send a new code")
                                    .fontWeight(.medium)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, scaled(10))
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                            .disabled(isWorking)
                        }
                        .glassCard()
                        .padding(.horizontal, scaled(24))

                        Button("Sign out") {
                            appState.signOut()
                        }
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.7))
                        .disabled(deletionFlow.isWorking)

                        Button("Delete account") {
                            deletionFlow.begin(using: appState)
                        }
                        .font(.footnote)
                        .foregroundStyle(.red.opacity(0.9))
                        .disabled(isWorking || deletionFlow.isWorking)

                        Spacer(minLength: scaled(24))
                    }
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                    .foregroundStyle(.white)
                }
                .scrollDismissesKeyboard(.interactively)
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .task {
            email = await appState.currentUserEmail()
            codeFieldFocused = true
        }
    }

    private func submitCode() {
        guard !isWorking, code.count == Self.codeLength else { return }
        isWorking = true
        notice = nil
        let submitted = code
        Task { @MainActor in
            do {
                try await appState.verifyEmailCode(submitted)
                if appState.needsEmailVerification {
                    // Accepted, but the refreshed account state hasn't caught
                    // up yet. A second tap re-checks without a new code.
                    notice = "Almost there. Tap Verify again in a moment."
                }
            } catch {
                code = ""
                notice = Self.message(for: error, fallback: "Couldn't check the code. Please try again.")
                codeFieldFocused = true
            }
            isWorking = false
        }
    }

    private func resend() {
        isWorking = true
        notice = nil
        code = ""
        Task { @MainActor in
            do {
                try await appState.resendVerificationCode()
                notice = "A new code is on its way. Check your inbox and spam folder."
            } catch {
                notice = Self.message(for: error, fallback: "Couldn't send the email. Please try again in a minute.")
            }
            isWorking = false
            codeFieldFocused = true
        }
    }

    /// The backend writes its 400/503 messages for users, so show them as-is.
    private static func message(for error: Error, fallback: String) -> String {
        switch error {
        case let APIError.server(status, message?) where status == 400 || status == 503:
            return message
        case APIError.rateLimited:
            return "Too many tries for now. Please wait a few minutes and try again."
        default:
            return fallback
        }
    }
}
