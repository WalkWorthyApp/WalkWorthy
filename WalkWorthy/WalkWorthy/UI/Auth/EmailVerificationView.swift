//
//  EmailVerificationView.swift
//  WalkWorthy
//
//  Full-screen gate shown to email/password accounts until their address is
//  verified (RootView blocks the main UI; the backend independently rejects
//  unverified tokens with 403 EMAIL_UNVERIFIED). Sign in with Apple accounts
//  never see this — Apple verifies emails upstream.
//

import SwiftUI

struct EmailVerificationView: View {
    @EnvironmentObject private var appState: AppState

    @State private var email: String?
    @State private var isWorking = false
    @State private var notice: String?

    var body: some View {
        ZStack {
            TimeOfDayTheme.current.backdrop
                .ignoresSafeArea()

            VStack(spacing: scaled(20)) {
                Spacer()

                VStack(alignment: .leading, spacing: scaled(14)) {
                    Label("Verify your email", systemImage: "envelope.badge")
                        .font(.newsreaderSemiBoldItalic(size: scaled(28)))
                        .accessibilityAddTraits(.isHeader)

                    Text("We sent a verification link to \(email ?? "your email address"). Tap the link, then come back here.")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.85))

                    if let notice {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.75))
                    }

                    Button {
                        refreshStatus()
                    } label: {
                        Text("I've verified")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, scaled(14))
                            .background(Color.white, in: Capsule())
                            .foregroundStyle(.black)
                    }
                    .disabled(isWorking)
                    .accessibilityHint("Checks whether your email has been verified")

                    Button {
                        resend()
                    } label: {
                        Text("Resend email")
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

                Spacer()
            }
            .foregroundStyle(.white)
        }
        .task {
            email = await appState.currentUserEmail()
        }
    }

    private func refreshStatus() {
        isWorking = true
        notice = nil
        Task { @MainActor in
            await appState.refreshEmailVerificationStatus()
            if appState.needsEmailVerification {
                notice = "Not verified yet — check your inbox (and spam folder), then try again."
            }
            isWorking = false
        }
    }

    private func resend() {
        isWorking = true
        notice = nil
        Task { @MainActor in
            do {
                try await appState.resendVerificationEmail()
                notice = "Verification email sent."
            } catch {
                notice = "Couldn't send the email — please try again in a minute."
            }
            isWorking = false
        }
    }
}
