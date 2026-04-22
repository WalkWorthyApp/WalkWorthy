//
//  SignInFormView.swift
//  WalkWorthy
//
//  Email/password input form for sign-in and account creation.
//

import SwiftUI
import AuthenticationServices

struct SignInFormView: View {
    @ObservedObject var viewModel: AuthenticationViewModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedField: Field?

    enum Field {
        case email
        case password
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scaled(20)) {
            // Mode toggle
            modeToggle
                .padding(.bottom, scaled(8))

            // Email field
            emailSection

            // Password field
            passwordSection

            // Error display
            if let error = viewModel.errorDetails {
                errorCard(error)
            }

            // Submit button
            submitButton

            // "or" divider between email/password and Apple sign-in
            orDivider

            // Sign in with Apple — required by App Store Guideline 4.8
            appleSignInButton

            // Mode switch link
            modeSwitchLink
        }
        .padding(.horizontal, scaled(24))
        .padding(.vertical, scaled(16))
        .task {
            // Wait for SwiftUI to settle keyboard/focus before requesting email focus.
            // Using `.task` (vs. DispatchQueue.asyncAfter) ensures SwiftUI cancels
            // this on view disappear, avoiding a focus race if the user taps
            // another field quickly.
            try? await Task.sleep(for: .milliseconds(300))
            focusedField = .email
        }
        .onChange(of: viewModel.email) {
            if viewModel.errorDetails != nil {
                viewModel.clearError()
            }
        }
        .onChange(of: viewModel.password) {
            if viewModel.errorDetails != nil {
                viewModel.clearError()
            }
        }
    }

    // MARK: - Components

    private var modeToggle: some View {
        HStack(spacing: 0) {
            Button(action: {
                if viewModel.mode != .signIn {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        viewModel.mode = .signIn
                    }
                }
            }) {
                Text("Sign In")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(viewModel.mode == .signIn ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, scaled(10))
            }

            Button(action: {
                if viewModel.mode != .createAccount {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        viewModel.mode = .createAccount
                    }
                }
            }) {
                Text("Create")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(viewModel.mode == .createAccount ? .primary : .secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, scaled(10))
            }
        }
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: scaled(12), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: scaled(12), style: .continuous)
                .stroke(Color(.systemGray4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: scaled(12), style: .continuous))
    }

    private var emailSection: some View {
        VStack(alignment: .leading, spacing: scaled(8)) {
            Text("Email")
                .font(.subheadline.bold())
                .foregroundStyle(.primary)

            TextField("your.email@example.com", text: $viewModel.email)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.emailAddress)
                .focused($focusedField, equals: .email)
                .padding(scaled(12))
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: scaled(14), style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: scaled(14), style: .continuous)
                        .strokeBorder(Color(.systemGray4), lineWidth: 1)
                )
        }
    }

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: scaled(8)) {
            Text("Password")
                .font(.subheadline.bold())
                .foregroundStyle(.primary)

            HStack {
                if viewModel.showPassword {
                    TextField("Password", text: $viewModel.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .focused($focusedField, equals: .password)
                } else {
                    SecureField("Password", text: $viewModel.password)
                        .textContentType(viewModel.mode == .createAccount ? .newPassword : .password)
                        .focused($focusedField, equals: .password)
                }

                Button(action: viewModel.togglePasswordVisibility) {
                    Image(systemName: viewModel.showPassword ? "eye.slash" : "eye")
                        .foregroundStyle(.secondary)
                }
                .accessibilityLabel(viewModel.showPassword ?
                    NSLocalizedString("Hide password", comment: "Password visibility toggle - hide action") :
                    NSLocalizedString("Show password", comment: "Password visibility toggle - show action"))
                .accessibilityHint(NSLocalizedString("Double tap to toggle password visibility", comment: "Password visibility toggle hint"))
                .padding(.trailing, scaled(12))
            }
            .padding(.leading, scaled(12))
            .padding(.vertical, scaled(12))
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: scaled(14), style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: scaled(14), style: .continuous)
                    .strokeBorder(Color(.systemGray4), lineWidth: 1)
            )

            if viewModel.mode == .createAccount {
                Text("At least 6 characters")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func errorCard(_ error: AuthErrorDetails) -> some View {
        VStack(alignment: .leading, spacing: scaled(6)) {
            Text(error.title)
                .font(.subheadline.bold())
                .foregroundStyle(.red)

            Text(error.displayText)
                .font(.footnote)
                .foregroundStyle(.red)
                .lineLimit(nil)
        }
        .padding(scaled(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: scaled(12), style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: scaled(12), style: .continuous)
                .stroke(Color.red.opacity(0.2), lineWidth: 1)
        )
        .transition(.opacity.combined(with: .move(edge: .top)))
        .accessibilityElement(children: .combine)
        .onAppear {
            let announcement = "\(error.title). \(error.displayText)"
            UIAccessibility.post(notification: .announcement, argument: announcement)
        }
    }

    private var submitButton: some View {
        Button(action: {
            Task {
                await viewModel.authenticate()
            }
        }) {
            HStack {
                if viewModel.isLoading {
                    ProgressView()
                        .tint(.white)
                } else {
                    Text(viewModel.mode.submitButtonLabel)
                        .font(.headline)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(scaled(14))
            .background(
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.85), Color.accentColor],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: scaled(16), style: .continuous)
            )
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isLoading)
    }

    private var orDivider: some View {
        HStack(spacing: scaled(12)) {
            Rectangle()
                .fill(Color(.systemGray4))
                .frame(height: 1)
            Text("or")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color(.systemGray4))
                .frame(height: 1)
        }
        .padding(.vertical, scaled(4))
        .accessibilityHidden(true)
    }

    private var appleSignInButton: some View {
        // `.signIn` is the right label regardless of `viewModel.mode` — Apple
        // treats first-time and repeat taps the same way, creating the
        // Firebase account on first success and signing in on subsequent ones.
        //
        // The button configures its request in `onRequest` (via the view
        // model, which owns the nonce lifecycle), and the view model consumes
        // the resulting `ASAuthorization` in `onCompletion`.
        SignInWithAppleButton(.signIn, onRequest: { request in
            viewModel.configureAppleRequest(request)
        }, onCompletion: { result in
            Task { @MainActor in
                await viewModel.handleAppleAuthorizationResult(result)
            }
        })
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(maxWidth: .infinity)
        .frame(height: scaled(48))
        .clipShape(RoundedRectangle(cornerRadius: scaled(16), style: .continuous))
        .disabled(viewModel.isLoading)
        .opacity(viewModel.isLoading ? 0.6 : 1)
    }

    private var modeSwitchLink: some View {
        HStack(spacing: scaled(4)) {
            Text(viewModel.mode == .signIn ? "Don't have an account?" : "Already have an account?")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button(action: viewModel.toggleMode) {
                Text(viewModel.mode == .signIn ? "Create one" : "Sign in")
                    .font(.footnote.bold())
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .padding(.top, scaled(8))
    }
}
