//
//  SignInFormView.swift
//  WalkWorthy
//
//  Email/password input form for sign-in and account creation.
//

import SwiftUI

struct SignInFormView: View {
    @ObservedObject var viewModel: AuthenticationViewModel
    @FocusState private var focusedField: Field?

    enum Field {
        case email
        case password
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Mode toggle
            modeToggle
                .padding(.bottom, 8)

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

            // Mode switch link
            modeSwitchLink
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                focusedField = .email
            }
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
                    .padding(.vertical, 10)
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
                    .padding(.vertical, 10)
            }
        }
        .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color(.systemGray4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var emailSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Email")
                .font(.subheadline.bold())
                .foregroundStyle(.primary)

            TextField("your.email@example.com", text: $viewModel.email)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.emailAddress)
                .focused($focusedField, equals: .email)
                .padding(12)
                .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color(.systemGray4), lineWidth: 1)
                )
        }
    }

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                .padding(.trailing, 12)
            }
            .padding(.leading, 12)
            .padding(.vertical, 12)
            .background(Color(.systemGray6), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
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
        VStack(alignment: .leading, spacing: 6) {
            Text(error.title)
                .font(.subheadline.bold())
                .foregroundStyle(.red)

            Text(error.displayText)
                .font(.footnote)
                .foregroundStyle(.red)
                .lineLimit(nil)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
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
            .padding(14)
            .background(
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.85), Color.accentColor],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isLoading)
    }

    private var modeSwitchLink: some View {
        HStack(spacing: 4) {
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
        .padding(.top, 8)
    }
}
