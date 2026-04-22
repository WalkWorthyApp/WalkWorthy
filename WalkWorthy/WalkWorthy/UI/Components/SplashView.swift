//
//  SplashView.swift
//  WalkWorthy
//
//  Branded full-screen splash shown during cold-start auth resolution.
//  The LaunchSplash asset has light + dark variants; the app is forced dark
//  at the WalkWorthyApp scene root so only the dark variant ever renders
//  here — ensuring the splash-to-home transition has no color-scheme flash.
//
//  A custom linear progress bar animates from 0 → 90% over ~2s to give the
//  perception of "almost done loading". The auth resolution typically
//  completes inside that window; on the rare occasion it takes longer, the
//  bar plateaus at 90% (never falsely claims completion).
//

import SwiftUI

struct SplashView: View {
    @State private var progress: CGFloat = 0.0

    var body: some View {
        ZStack(alignment: .bottom) {
            // Full-bleed splash image. `frame(maxWidth:maxHeight:.infinity)`
            // + `ignoresSafeArea` on the ZStack guarantees the image fills
            // the entire screen including the notch/dynamic island and home
            // indicator safe areas, with no gap at top or bottom.
            Image("LaunchSplash")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

            // Custom progress bar — a direct Capsule-based implementation
            // instead of SwiftUI's ProgressView(value:) which was not
            // animating the linear style reliably during cold start.
            ProgressBar(progress: progress)
                .frame(width: 240, height: 4)
                .padding(.bottom, 72)
        }
        .ignoresSafeArea()
        .onAppear {
            // Animate 0 → 90% over 2 seconds with easeOut. If auth resolves
            // before the animation finishes (typical), the SplashView
            // transitions out mid-animation. If auth takes longer, the bar
            // plateaus at 90% — honest "nearly there" cue, never 100%.
            withAnimation(.easeOut(duration: 2.0)) {
                progress = 0.9
            }
        }
    }
}

/// Simple linear progress bar with an animated fill. Explicit width-based
/// implementation because SwiftUI's `ProgressView(value:).progressViewStyle(.linear)`
/// can fail to animate value changes reliably in some contexts.
private struct ProgressBar: View {
    let progress: CGFloat

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.22))
                Capsule()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: max(0, geo.size.width * progress))
            }
        }
    }
}
