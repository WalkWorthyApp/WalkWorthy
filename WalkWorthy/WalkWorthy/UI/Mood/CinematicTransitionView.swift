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
    let errorMessage: String?
    let onDone: () -> Void
    let onRetry: () -> Void   // resets to .followUp in MoodCheckInView

    // MARK: - Animation State

    @State private var dawnOpacity: Double = 0
    @State private var imageOffsetX: CGFloat = 0
    @State private var sunBloomOpacity: Double = 0
    @State private var breathOpacity: Double = 1.0  // drives breathing pulse independently
    @State private var showCards: Bool = false
    @State private var panComplete: Bool = false

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

                // Phase 1 — Dawn radial glow from upper-right
                RadialGradient(
                    colors: [
                        Color(red: 0.92, green: 0.76, blue: 0.24).opacity(0.55),
                        Color.clear
                    ],
                    center: UnitPoint(x: 0.75, y: 0.25),  // upper-right sky
                    startRadius: 10,
                    endRadius: screenW * 0.9
                )
                .ignoresSafeArea()
                .opacity(dawnOpacity)

                // Phase 3 — Sunlight bloom over cross (left third)
                // breathOpacity drives the waiting pulse; settles to 1.0 when cards show.
                RadialGradient(
                    colors: [
                        Color.white.opacity(0.45),
                        Color(red: 0.92, green: 0.76, blue: 0.24).opacity(0.30),
                        Color.clear
                    ],
                    center: UnitPoint(x: 0.22, y: 0.42),  // cross position, left third
                    startRadius: 5,
                    endRadius: screenW * 0.45
                )
                .ignoresSafeArea()
                .opacity(sunBloomOpacity * breathOpacity)

                // Response cards — bottom 65% of screen
                if showCards {
                    if let result = response {
                        ScrollView {
                            MoodResponseContent(response: result, onDismiss: onDone)
                                .padding(.horizontal, 16)
                                .padding(.top, 16)
                                .padding(.bottom, 40)
                        }
                        .frame(height: geo.size.height * 0.65)
                        .background(.ultraThinMaterial.opacity(0.15))
                        .transition(.opacity.animation(.easeIn(duration: 0.7)))
                    } else if let error = errorMessage {
                        errorOverlay(message: error, geo: geo)
                            .transition(.opacity.animation(.easeIn(duration: 0.5)))
                    }
                }
            }
            .ignoresSafeArea()
            // .task ties the animation lifetime to the view — auto-cancels on dismiss
            .task {
                imageOffsetX = screenW * 0.5
                await runAnimation(screenW: screenW)
            }
        }
        .ignoresSafeArea()
        // Watch for API response arriving after pan completes
        .onChange(of: response) { _, newValue in
            guard newValue != nil, panComplete, !showCards else { return }
            withAnimation(.easeOut(duration: 0.4)) { breathOpacity = 1.0 }
            withAnimation { showCards = true }
        }
        // Watch for error arriving after pan completes
        .onChange(of: errorMessage) { _, newValue in
            guard newValue != nil, panComplete, !showCards else { return }
            withAnimation(.easeOut(duration: 0.4)) { breathOpacity = 1.0 }
            withAnimation { showCards = true }
        }
    }

    // MARK: - Error Overlay

    private func errorOverlay(message: String, geo: GeometryProxy) -> some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 44))
                    .foregroundColor(.orange)

                Text("Something went wrong")
                    .font(Font.newsreaderSemiBoldItalic(fixedSize: 20))
                    .foregroundColor(.primary)

                Text(message)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                Button("Try Again", action: onRetry)
                    .buttonStyle(.bordered)
            }
            .padding(28)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.white.opacity(0.92))
            )
            .padding(.horizontal, 24)

            Spacer()
        }
        .frame(height: geo.size.height * 0.65)
    }

    // MARK: - Animation Sequence

    private func runAnimation(screenW: CGFloat) async {
        // Phase 1: Dawn light builds (0 → 1.5s)
        withAnimation(.easeOut(duration: 1.5)) {
            dawnOpacity = 1.0
        }

        // Phase 2: Pan begins at 0.3s, runs for 3.7s (settles at ~4.0s)
        try? await Task.sleep(for: .milliseconds(300))
        withAnimation(.timingCurve(0.25, 0.1, 0.05, 1.0, duration: 3.7)) {
            imageOffsetX = -screenW * 0.25
        }

        // Phase 3: Sun bloom starts as pan decelerates (3.0s mark)
        try? await Task.sleep(for: .milliseconds(2700))
        withAnimation(.easeIn(duration: 1.5)) {
            sunBloomOpacity = 1.0
        }

        // Phase 4: Pan settled (4.0s total). Show cards or start breathing.
        try? await Task.sleep(for: .milliseconds(1000))

        panComplete = true
        if response != nil || errorMessage != nil {
            withAnimation { showCards = true }
        } else {
            // Hold at sunlit hillside, breathe until API responds
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
                verseRef: "Philippians 4:13",
                verseText: "I can do all things through Christ who strengthens me.",
                translation: "NIV"
            ),
            createdAt: "",
            expiresAt: "",
            isExisting: false
        ),
        errorMessage: nil,
        onDone: {},
        onRetry: {}
    )
}

#Preview("Cinematic - Waiting") {
    CinematicTransitionView(
        response: nil,
        errorMessage: nil,
        onDone: {},
        onRetry: {}
    )
}
