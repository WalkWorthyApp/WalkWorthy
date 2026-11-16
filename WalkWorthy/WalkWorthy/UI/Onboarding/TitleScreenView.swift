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

            // The scroll content stops at the safe area, so this fills the
            // home-indicator strip below it and the card still reads as
            // anchored to the bottom edge of the screen.
            Color(.systemBackground)
                .frame(height: 0)
                .ignoresSafeArea(.container, edges: .bottom)

            // Scrollable so the keyboard pushes the sign-in card up instead of
            // covering its fields. The card is taller than the space left
            // above the keyboard, so it has to be able to scroll.
            GeometryReader { geometry in
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(spacing: 0) {
                            // MARK: - Top hero: logo + quote (fills remaining space above the card)
                            Spacer()

                            VStack(spacing: scaled(16)) {
                                logoImage
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: scaled(180))
                                    .shadow(color: .black.opacity(0.2), radius: scaled(16), x: 0, y: scaled(8))

                                Text("WalkWorthy")
                                    .font(.newsreaderSemiBoldItalic(size: scaled(34)))
                                    .foregroundStyle(.white)

                                Text("For when life seems like rough waters, WalkWorthy knowing God is with you through the storm.")
                                    .font(.subheadline)
                                    .italic()
                                    .foregroundStyle(.white.opacity(0.85))
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, scaled(32))

                                if let notice = appState.authenticationNotice {
                                    Text(notice)
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(Color.red)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, scaled(24))
                                }
                            }

                            Spacer()

                            // MARK: - Bottom card: content-sized white panel, anchored to bottom
                            if let viewModel = authViewModel {
                                SignInFormView(viewModel: viewModel, scrollProxy: proxy)
                                    .padding(.top, scaled(16))
                                    .padding(.bottom, scaled(8))
                                    .background(
                                        Color(.systemBackground)
                                            .clipShape(
                                                UnevenRoundedRectangle(
                                                    cornerRadii: .init(
                                                        topLeading: scaled(28),
                                                        bottomLeading: 0,
                                                        bottomTrailing: 0,
                                                        topTrailing: scaled(28)
                                                    ),
                                                    style: .continuous
                                                )
                                            )
                                    )
                            }
                        }
                        // At least a screen tall, so with the keyboard down the
                        // card sits at the bottom exactly as before.
                        .frame(minHeight: geometry.size.height)
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .scrollDismissesKeyboard(.interactively)
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
