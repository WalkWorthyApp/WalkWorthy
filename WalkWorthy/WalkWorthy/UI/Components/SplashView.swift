//
//  SplashView.swift
//  WalkWorthy
//
//  Branded full-screen splash shown during cold-start auth resolution.
//  The LaunchSplash asset has light + dark variants and fills the screen
//  so the hand-off from the system UILaunchScreen (same AppBackground color)
//  to Swift is seamless — no black flash at any step.
//
//  A linear progress bar at the bottom animates from 0 → 90% over ~2s to
//  give the perception of "almost done loading". The auth resolution
//  typically completes inside that window; on the rare occasion it takes
//  longer, the bar pauses at 90% until the view transitions out.
//

import SwiftUI

struct SplashView: View {
    @State private var progress: Double = 0.0

    var body: some View {
        ZStack {
            // Full-bleed adaptive splash image (light / dark variants via
            // asset catalog appearance). `resizable + scaledToFill + clipped`
            // gives us background-image semantics on any device aspect.
            Image("LaunchSplash")
                .resizable()
                .scaledToFill()
                .ignoresSafeArea()
                .clipped()

            // Linear progress bar sits above the safe area bottom so it's
            // visible on devices with home indicators.
            VStack {
                Spacer()
                ProgressView(value: progress, total: 1.0)
                    .progressViewStyle(.linear)
                    .tint(.white)
                    .frame(maxWidth: 260)
                    .padding(.bottom, 60)
                    .opacity(0.85)
            }
        }
        .onAppear {
            // Animate toward "almost done" over 2s. If auth resolves first
            // (typical), the SplashView transitions out before reaching 90%.
            // If auth takes longer, the bar plateaus at 90%, never claims
            // completion — an honest "loading, nearly there" cue.
            withAnimation(.easeOut(duration: 2.0)) {
                progress = 0.9
            }
        }
    }
}
