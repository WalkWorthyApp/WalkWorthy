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

    // Account deletion must stay reachable pre-verification (App Store
    // Guideline 5.1.1(v)) — the main Settings screen is behind this gate,
    // so the gate itself offers it. Mirrors SettingsView's two-step flow.
    @State private var showDeleteConfirmation = false
    @State private var showReauthSheet = false
    @State private var deleteError: String?

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

                Button("Delete account") {
                    showDeleteConfirmation = true
                }
                .font(.footnote)
                .foregroundStyle(.red.opacity(0.9))
                .disabled(isWorking)

                Spacer()
            }
            .foregroundStyle(.white)
        }
        .task {
            email = await appState.currentUserEmail()
        }
        .confirmationDialog(
            "Delete Account?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Account", role: .destructive) {
                Task { await startAccountDeletion() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently removes your account and any data associated with it. This cannot be undone.")
        }
        .sheet(isPresented: $showReauthSheet) {
            ReauthenticationSheet(
                onAuthenticated: {
                    Task { await performBackendDeletion() }
                }
            )
        }
        .alert(
            "Couldn't delete account",
            isPresented: Binding(
                get: { deleteError != nil },
                set: { if !$0 { deleteError = nil } }
            ),
            presenting: deleteError
        ) { _ in
            Button("OK", role: .cancel) { deleteError = nil }
        } message: { message in
            Text(message)
        }
    }

    // MARK: - Account deletion (mirrors SettingsView's two-step flow)

    private func startAccountDeletion() async {
        guard appState.isAuthenticated, !isWorking else { return }
        let needsReauth = await appState.accountDeletionRequiresReauth()
        if needsReauth {
            showReauthSheet = true
        } else {
            await performBackendDeletion()
        }
    }

    private func performBackendDeletion() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await appState.deleteAccount()
            // Auth listener flips isAuthenticated; belt-and-suspenders:
            appState.signOut()
        } catch APIError.unauthorized, APIError.notAuthenticated {
            deleteError = "Please sign in again, then try deleting your account."
            appState.signOut()
        } catch let error as APIError {
            deleteError = error.errorDescription ?? "Couldn't delete account — please try again."
        } catch {
            deleteError = "Couldn't delete account — please try again."
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
