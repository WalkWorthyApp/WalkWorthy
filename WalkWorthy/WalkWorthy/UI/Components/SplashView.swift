//
//  SplashView.swift
//  WalkWorthy
//
//  Branded splash displayed during cold-start auth resolution. Matches the
//  UILaunchScreen's AppBackground color + TitleLogoDark image so the visual
//  hand-off from the system launch screen to the SwiftUI `isCheckingAuth`
//  state is seamless — no black-flash between the two.
//

import SwiftUI

struct SplashView: View {
    @State private var isPulsing: Bool = false

    var body: some View {
        ZStack {
            Color("AppBackground")
                .ignoresSafeArea()

            VStack(spacing: scaled(20)) {
                Image("TitleLogoDark")
                    .resizable()
                    .scaledToFit()
                    .frame(width: scaled(180))
                    .opacity(isPulsing ? 1.0 : 0.88)
                    .scaleEffect(isPulsing ? 1.0 : 0.985)
                    .animation(
                        .easeInOut(duration: 1.4).repeatForever(autoreverses: true),
                        value: isPulsing
                    )

                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white.opacity(0.6))
            }
        }
        .onAppear { isPulsing = true }
    }
}
