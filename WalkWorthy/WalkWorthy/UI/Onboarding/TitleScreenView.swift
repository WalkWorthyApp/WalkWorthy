//
//  TitleScreenView.swift
//  WalkWorthy
//
//  Presents the branded welcome experience before authentication.
//

import SwiftUI

struct TitleScreenView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    @State private var showAuthForm = false
    @State private var authViewModel: AuthenticationViewModel?

    var body: some View {
        ZStack {
            backgroundGradient
                .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 32) {
                    VStack(spacing: 32) {
                        Spacer()

                        logoImage
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 180)
                            .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 10)

                        VStack(spacing: 16) {
                            Text("For when life seems like rough waters, WalkWorthy knowing God is with you through the storm.")
                                .font(.title2.bold())
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 24)

                            if !showAuthForm {
                                Text("Tap continue to sign in with your WalkWorthy account.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }

                            if let notice = appState.authenticationNotice {
                                Text(notice)
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(Color.red)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 24)
                            }
                        }

                        // Continue button (visible when form is hidden)
                        if !showAuthForm {
                            Button(action: startSignIn) {
                                HStack {
                                    Text("Continue →")
                                        .font(.headline)
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(
                                    LinearGradient(
                                        colors: [Color.accentColor.opacity(0.85), Color.accentColor],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                                )
                                .foregroundStyle(Color.white)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 24)
                            .transition(.opacity)
                        }

                        Spacer()
                    }

                    // Sign-in form (appears when Continue is tapped)
                    if showAuthForm, let viewModel = authViewModel {
                        VStack(spacing: 0) {
                            Divider()
                                .padding(.bottom, 16)

                            SignInFormView(viewModel: viewModel)
                        }
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .padding(.vertical, 48)
            }
        }
        .onAppear {
            // Initialize view model lazily when the view appears
            if authViewModel == nil {
                authViewModel = AuthenticationViewModel(appState: appState)
            }
        }
    }

    private var logoImage: Image {
        Image(colorScheme == .dark ? "TitleLogoDark" : "TitleLogoLight")
            .renderingMode(.original)
    }

    private var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: colorScheme == .dark ?
                [Color(hex: 0x031E52), Color(hex: 0x012859), Color(hex: 0x0A3E7C)] :
                [Color(hex: 0xA9D7FF), Color(hex: 0x6DB6FF), Color(hex: 0x3384FF)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func startSignIn() {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            showAuthForm = true
        }
    }
}

private extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let red = Double((hex & 0xFF0000) >> 16) / 255.0
        let green = Double((hex & 0x00FF00) >> 8) / 255.0
        let blue = Double(hex & 0x0000FF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}
