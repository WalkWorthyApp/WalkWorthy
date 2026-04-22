//
//  SplashView.swift
//  WalkWorthy
//
//  Branded full-screen splash shown during cold-start auth resolution.
//  The LaunchSplash asset has light + dark variants; because RootView
//  passes `nil` to `preferredColorScheme` during `isCheckingAuth`, the
//  asset catalog picks the variant matching the DEVICE's system setting,
//  even though the rest of the app is forced-dark after auth resolves.
//
//  A custom linear progress bar animates from 0 → 90% over ~2s to give
//  the perception of "almost done loading".
//

import SwiftUI

struct SplashView: View {
    @State private var progress: CGFloat = 0.0

    var body: some View {
        ZStack {
            // Background fallback — AppBackground color matches the splash
            // image's background so any edge gap shows the same color
            // instead of black. Itself adaptive via asset catalog.
            Color("AppBackground")
                .ignoresSafeArea()

            // Splash image, full-bleed. Explicit max-infinity frame +
            // ignoresSafeArea guarantees coverage of notch + home indicator
            // areas on every iPhone aspect.
            Image("LaunchSplash")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .ignoresSafeArea()

            // Progress bar — pinned near the bottom, safe-area-aware so it
            // doesn't sit under the home indicator.
            VStack {
                Spacer()
                ProgressBar(progress: progress)
                    .frame(width: 240, height: 4)
                    .padding(.bottom, 56)
            }
        }
        .onAppear {
            // 0 → 90% over 2s; if auth resolves first, the SplashView
            // transitions out mid-animation. If auth takes longer, bar
            // plateaus at 90% — honest "nearly there" cue.
            withAnimation(.easeOut(duration: 2.0)) {
                progress = 0.9
            }
        }
    }
}

/// Simple Capsule-based linear progress bar. Explicit width-based fill
/// animates reliably via `withAnimation`, unlike SwiftUI's built-in
/// `ProgressView(value:).progressViewStyle(.linear)` in this context.
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
