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

    @State private var authViewModel: AuthenticationViewModel?

    var body: some View {
        ZStack(alignment: .bottom) {
            backgroundGradient
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // MARK: - Top hero: logo + quote (fills remaining space above the card)
                Spacer()

                VStack(spacing: 16) {
                    logoImage
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 180)
                        .shadow(color: .black.opacity(0.2), radius: 16, x: 0, y: 8)

                    Text("WalkWorthy")
                        .font(.newsreaderSemiBoldItalic(fixedSize: 34))
                        .foregroundStyle(.white)

                    Text("For when life seems like rough waters, WalkWorthy knowing God is with you through the storm.")
                        .font(.subheadline)
                        .italic()
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)

                    if let notice = appState.authenticationNotice {
                        Text(notice)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Color.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }

                Spacer()

                // MARK: - Bottom card: content-sized white panel, anchored to bottom
                if let viewModel = authViewModel {
                    SignInFormView(viewModel: viewModel)
                        .padding(.top, 16)
                        .padding(.bottom, 8)
                        .background(
                            Color(.systemBackground)
                                .clipShape(
                                    UnevenRoundedRectangle(
                                        cornerRadii: .init(
                                            topLeading: 28,
                                            bottomLeading: 0,
                                            bottomTrailing: 0,
                                            topTrailing: 28
                                        ),
                                        style: .continuous
                                    )
                                )
                                .ignoresSafeArea(edges: .bottom)
                        )
                }
            }
        }
        .onAppear {
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
}

private extension Color {
    init(hex: UInt32, opacity: Double = 1.0) {
        let red = Double((hex & 0xFF0000) >> 16) / 255.0
        let green = Double((hex & 0x00FF00) >> 8) / 255.0
        let blue = Double(hex & 0x0000FF) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}
