import SwiftUI

/// Installed on RootView so the ceremony survives the switch from Settings or
/// email verification into pending local/cloud cleanup.
struct AccountDeletionPresentation: ViewModifier {
    @EnvironmentObject private var appState: AppState
    @StateObject private var flow = AccountDeletionFlow()

    func body(content: Content) -> some View {
        content
            .environmentObject(flow)
            .confirmationDialog("Delete Account?", isPresented: Binding(
                get: { flow.phase == .confirmation },
                set: { if !$0 { flow.dismissConfirmation() } }
            ), titleVisibility: .visible) {
                Button("Delete Account", role: .destructive) { flow.confirm(using: appState) }
                Button("Cancel", role: .cancel) { flow.cancel() }
            } message: {
                Text("This permanently removes your profile, mood history, journal entries, daily reflections, and encouragements. Device data removal starts immediately, even if server deletion needs a retry. This cannot be undone.")
            }
            .sheet(isPresented: Binding(
                get: { flow.isPresentingPassword },
                set: { if !$0 { flow.dismissPassword() } }
            )) {
                ReauthenticationSheet(flow: flow) { password in
                    flow.submit(password: password, using: appState)
                }
            }
            .alert("Couldn't delete account", isPresented: Binding(
                get: { flow.deletionError != nil },
                set: { if !$0 { flow.dismissError() } }
            )) {
                Button("OK", role: .cancel) { flow.dismissError() }
            } message: {
                Text(deletionErrorMessage)
            }
            .onChange(of: appState.authenticatedSession) { _, _ in flow.cancel() }
            .onDisappear { flow.cancel() }
    }

    private var deletionErrorMessage: String {
        guard let error = flow.deletionError else { return "" }
        switch error {
        case APIError.unauthorized, APIError.notAuthenticated:
            return "Please authenticate again to finish deleting your account. Retry deletion, or sign out and sign in again."
        case let error as APIError:
            return error.errorDescription ?? "Couldn't delete account — please try again."
        default:
            return "Couldn't confirm account deletion. Please try again."
        }
    }
}

private struct ReauthenticationSheet: View {
    @ObservedObject var flow: AccountDeletionFlow
    let onSubmit: (String) -> Void
    @State private var password = ""
    @FocusState private var passwordFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                TimeOfDayTheme.current.backdrop.ignoresSafeArea()
                Form {
                    Section {
                        Text("For your security, please re-enter your password to confirm account deletion.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .listRowBackground(Color.wwCardBackground)
                    }
                    Section("Password") {
                        SecureField("Password", text: $password)
                            .textContentType(.password)
                            .submitLabel(.continue)
                            .focused($passwordFocused)
                            .onSubmit { submit() }
                            .listRowBackground(Color.wwCardBackground)
                    }
                    if let error = flow.passwordError {
                        Section {
                            Text(FirebaseAuthErrorMapper.mapError(error).displayText)
                                .font(.subheadline)
                                .foregroundStyle(.red)
                                .listRowBackground(Color.wwCardBackground)
                        }
                    }
                }
                .scrollContentBackground(.hidden)
                .disabled(flow.isWorking)
            }
            .navigationTitle("Confirm Password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { flow.dismissPassword() }
                        .disabled(flow.isWorking)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if flow.isWorking {
                        ProgressView()
                    } else {
                        Button("Continue") { submit() }.disabled(password.isEmpty)
                    }
                }
            }
            .task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                passwordFocused = true
            }
        }
        .interactiveDismissDisabled(flow.isWorking)
    }

    private func submit() {
        guard !password.isEmpty, !flow.isWorking else { return }
        let submittedPassword = password
        password = ""
        onSubmit(submittedPassword)
    }
}
