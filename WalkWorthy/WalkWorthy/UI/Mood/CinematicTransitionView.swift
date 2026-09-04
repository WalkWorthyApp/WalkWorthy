//
//  CinematicTransitionView.swift
//  WalkWorthy
//
//  Replaces CrossTransitionView. Plays a 4-phase cinematic sequence:
//  dawn light → panoramic pan (cross on hill from right → left) →
//  sunlight bloom → response cards fade in over the scene.
//
//  The API call runs concurrently in MoodCheckInView. If it resolves
//  before the pan settles (Phase 4), cards appear on schedule.
//  If it's still in-flight, the view holds at the sunlit hillside
//  with a breathing glow until `response` updates.
//

import SwiftUI

struct CinematicTransitionView: View {
    let response: MoodCheckInResponse?
    let errorTitle: String?
    let errorMessage: String?
    let onDone: () -> Void
    let onRetry: () -> Void   // resets to .followUp in MoodCheckInView

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Animation State

    @State private var dawnOpacity: Double = 0
    @State private var imageOffsetX: CGFloat = 0
    @State private var sunBloomOpacity: Double = 0
    @State private var breathOpacity: Double = 1.0  // drives breathing pulse independently
    @State private var showCards: Bool = false
    @State private var panComplete: Bool = false
    // Set by onChange when response arrives before pan completes.
    // runAnimation reads this from @State storage (not the captured struct) after the sleep.
    @State private var responseArrivedEarly: Bool = false

    var body: some View {
        GeometryReader { geo in
            let screenW = geo.size.width
            let imageW = screenW * 2.0

            ZStack(alignment: .bottom) {
                // Background: 2× wide image, panned right → left
                Image("EasterHillscape")
                    .resizable()
                    .scaledToFill()
                    .frame(width: imageW, height: geo.size.height)
                    .clipped()
                    .offset(x: imageOffsetX)

                // Phase 1 — Dawn radial glow from upper-center (sun behind crosses, starts centered)
                RadialGradient(
                    colors: [
                        Color(red: 0.92, green: 0.76, blue: 0.24).opacity(0.55),
                        Color.clear
                    ],
                    center: UnitPoint(x: 0.6, y: 0.2),  // upper-center-right as pan begins
                    startRadius: scaled(10),
                    endRadius: screenW * 0.9
                )
                .ignoresSafeArea()
                .opacity(dawnOpacity)

                // Phase 3 — Sunlight bloom over crosses (settle at ~25% from left)
                // breathOpacity drives the waiting pulse; settles to 1.0 when cards show.
                RadialGradient(
                    colors: [
                        Color.white.opacity(0.45),
                        Color(red: 0.92, green: 0.76, blue: 0.24).opacity(0.30),
                        Color.clear
                    ],
                    center: UnitPoint(x: 0.35, y: 0.38),  // cross/sun position after pan settles
                    startRadius: scaled(5),
                    endRadius: screenW * 0.5
                )
                .ignoresSafeArea()
                .opacity(sunBloomOpacity * breathOpacity)

                // Response cards — bottom 65% of screen
                if showCards {
                    if let result = response {
                        ScrollView {
                            MoodResponseContent(response: result, onDismiss: onDone)
                                .padding(.horizontal, scaled(8))
                                .padding(.top, scaled(16))
                                .padding(.bottom, scaled(40))
                                .frame(maxWidth: .infinity)
                        }
                        .frame(width: screenW, height: geo.size.height * 0.80)
                        .transition(reduceMotion ? .identity : .opacity.animation(.easeIn(duration: 0.7)))
                    } else if let error = errorMessage {
                        errorOverlay(message: error, geo: geo)
                            .transition(reduceMotion ? .identity : .opacity.animation(.easeIn(duration: 0.5)))
                    }
                }
            }
            .frame(width: screenW, height: geo.size.height)
            .clipped()
            .ignoresSafeArea()
            // .task ties the animation lifetime to the view — auto-cancels on dismiss
            .task {
                imageOffsetX = screenW * 0.5
                if reduceMotion {
                    showReducedMotionState(screenW: screenW)
                } else {
                    await runAnimation(screenW: screenW)
                }
            }
        }
        .ignoresSafeArea()
        // Watch for API response or error arriving.
        // If pan is already done, show cards immediately.
        // If pan is still running, set responseArrivedEarly so runAnimation picks it up.
        .onChange(of: response) { _, newValue in
            guard newValue != nil else { return }
            if panComplete {
                revealCards()
            } else {
                responseArrivedEarly = true
            }
        }
        .onChange(of: errorMessage) { _, newValue in
            guard newValue != nil else { return }
            if panComplete {
                revealCards()
            } else {
                responseArrivedEarly = true
            }
        }
    }

    // MARK: - Error Overlay

    private func errorOverlay(message: String, geo: GeometryProxy) -> some View {
        VStack(spacing: scaled(24)) {
            Spacer()

            VStack(spacing: scaled(16)) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: scaled(44)))
                    .foregroundColor(.orange)

                Text(errorTitle ?? "Something went wrong")
                    .font(Font.newsreaderSemiBoldItalic(size: scaled(20)))
                    .foregroundColor(.black)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(message)
                    .font(.body)
                    .foregroundColor(.black.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Try Again", action: onRetry)
                    .buttonStyle(.bordered)
            }
            .padding(scaled(28))
            .frame(maxWidth: geo.size.width - scaled(48))
            .background(
                RoundedRectangle(cornerRadius: scaled(20))
                    .fill(Color.white.opacity(0.92))
            )

            Spacer()
        }
        .frame(width: geo.size.width, height: geo.size.height)
    }

    // MARK: - Animation Sequence

    private func showReducedMotionState(screenW: CGFloat) {
        imageOffsetX = -screenW * 0.15
        dawnOpacity = 1.0
        sunBloomOpacity = 1.0
        breathOpacity = 1.0
        panComplete = true
        showCards = response != nil || errorMessage != nil
    }

    private func revealCards() {
        guard !showCards else { return }
        if reduceMotion {
            breathOpacity = 1.0
            showCards = true
        } else {
            withAnimation(.easeOut(duration: 0.4)) { breathOpacity = 1.0 }
            withAnimation { showCards = true }
        }
    }

    private func runAnimation(screenW: CGFloat) async {
        // Phase 1: Dawn light builds (0 → 2.0s)
        withAnimation(.easeOut(duration: 2.0)) {
            dawnOpacity = 1.0
        }

        // Phase 2: Pan begins at 0.4s, runs for 5.0s (settles at ~5.4s)
        try? await Task.sleep(for: .milliseconds(400))
        withAnimation(.timingCurve(0.25, 0.1, 0.05, 1.0, duration: 5.0)) {
            imageOffsetX = -screenW * 0.15
        }

        // Phase 3: Sun bloom starts as pan decelerates (4.0s mark)
        try? await Task.sleep(for: .milliseconds(3600))
        withAnimation(.easeIn(duration: 1.8)) {
            sunBloomOpacity = 1.0
        }

        // Phase 4: Pan settled (~5.4s total). Show cards or start breathing.
        try? await Task.sleep(for: .milliseconds(1400))

        panComplete = true
        if responseArrivedEarly {
            // Response arrived while pan was running — show immediately
            revealCards()
        } else {
            // Still waiting — breathe until onChange fires
            withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                breathOpacity = 0.65
            }
        }
    }
}

// MARK: - Preview

#Preview("Cinematic - Response Ready") {
    CinematicTransitionView(
        response: MoodCheckInResponse(
            checkInId: "preview",
            aiResponse: AIEncouragementResponse(
                message: "You are doing great. Keep going.",
                verseRef: "Philippians 4:6–7",
                verseText: "do not be anxious about anything, but in everything by prayer and supplication with thanksgiving let your requests be made known to God. And the peace of God, which surpasses all understanding, will guard your hearts and your minds in Christ Jesus.",
                translation: "ESV",
                supportResource: nil
            ),
            createdAt: "",
            expiresAt: "",
            isExisting: false
        ),
        errorTitle: nil,
        errorMessage: nil,
        onDone: {},
        onRetry: {}
    )
}

#Preview("Cinematic - Waiting") {
    CinematicTransitionView(
        response: nil,
        errorTitle: nil,
        errorMessage: nil,
        onDone: {},
        onRetry: {}
    )
}

#Preview("Cinematic - Rate Limited") {
    CinematicTransitionView(
        response: nil,
        errorTitle: "Usage limit reached",
        errorMessage: "You've reached the usage limit for this feature. Try again in ~60 minutes.",
        onDone: {},
        onRetry: {}
    )
}
