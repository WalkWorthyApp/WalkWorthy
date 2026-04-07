//
//  CrossTransitionView.swift
//  WalkWorthy
//
//  Easter cross transition animation that plays after mood check-in submission.
//  Three crosses rise against a burst of light, then fade to white.
//

import SwiftUI

// MARK: - Cross Shape

struct CrossShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Vertical bar: full height, centered, 25% width
        let vBar = CGRect(
            x: rect.width * 0.375,
            y: 0,
            width: rect.width * 0.25,
            height: rect.height
        )
        // Horizontal bar: 28% from top, full width, 20% height
        let hBar = CGRect(
            x: 0,
            y: rect.height * 0.28,
            width: rect.width,
            height: rect.height * 0.20
        )
        path.addRect(vBar)
        path.addRect(hBar)
        return path
    }
}

// MARK: - Cross Transition View

struct CrossTransitionView: View {
    let moodLevel: MoodLevel
    let onComplete: () -> Void

    // MARK: Animated State

    @State private var raysOpacity: Double = 0
    @State private var raysScale: Double = 0.1
    @State private var crossesOffset: Double = 300
    @State private var crossesOpacity: Double = 0
    @State private var whiteOverlayOpacity: Double = 0

    // MARK: Constants

    private static let rayColor = Color(red: 1.0, green: 0.97, blue: 0.85)
    private static let crossColor = Color(red: 0.15, green: 0.1, blue: 0.05)

    private static let centerCrossHeight: CGFloat = 180
    private static let centerCrossWidth: CGFloat = 100
    private static let sideCrossHeight: CGFloat = 150
    private static let sideCrossWidth: CGFloat = 83
    private static let sideOffset: CGFloat = 120

    var body: some View {
        ZStack {
            // Light rays burst
            raysView
                .opacity(raysOpacity)
                .scaleEffect(raysScale)

            // Three crosses
            crossesView
                .opacity(crossesOpacity)
                .offset(y: crossesOffset)

            // White fade-out overlay
            Rectangle()
                .fill(Color.white)
                .opacity(whiteOverlayOpacity)
        }
        .ignoresSafeArea()
        .onAppear(perform: runAnimation)
    }

    // MARK: - Subviews

    private var raysView: some View {
        ZStack {
            // Radial glow
            RadialGradient(
                gradient: Gradient(colors: [
                    Self.rayColor.opacity(0.9),
                    Self.rayColor.opacity(0.3),
                    Color.clear
                ]),
                center: .center,
                startRadius: 10,
                endRadius: 400
            )

            // Ray spokes
            ForEach(0..<10, id: \.self) { index in
                let angle = Angle.degrees(Double(index) * 36)
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [Self.rayColor.opacity(0.6), Color.clear],
                            startPoint: .center,
                            endPoint: .top
                        )
                    )
                    .frame(width: 6, height: 500)
                    .rotationEffect(angle)
            }
        }
    }

    private var crossesView: some View {
        GeometryReader { geometry in
            let bottomY = geometry.size.height * 0.55

            ZStack {
                // Left cross
                CrossShape()
                    .fill(Self.crossColor)
                    .frame(width: Self.sideCrossWidth, height: Self.sideCrossHeight)
                    .position(
                        x: geometry.size.width / 2 - Self.sideOffset,
                        y: bottomY
                    )

                // Center cross (tallest)
                CrossShape()
                    .fill(Self.crossColor)
                    .frame(width: Self.centerCrossWidth, height: Self.centerCrossHeight)
                    .position(
                        x: geometry.size.width / 2,
                        y: bottomY - 15
                    )

                // Right cross
                CrossShape()
                    .fill(Self.crossColor)
                    .frame(width: Self.sideCrossWidth, height: Self.sideCrossHeight)
                    .position(
                        x: geometry.size.width / 2 + Self.sideOffset,
                        y: bottomY
                    )
            }
        }
    }

    // MARK: - Animation Sequence

    private func runAnimation() {
        Task {
            // Phase 1: Rays burst (0–0.8s)
            withAnimation(.easeOut(duration: 0.8)) {
                raysOpacity = 0.8
                raysScale = 1.5
            }

            try? await Task.sleep(nanoseconds: 600_000_000)

            // Phase 2: Crosses rise (0.6–1.4s, overlaps with rays)
            withAnimation(.easeOut(duration: 0.8)) {
                crossesOffset = 0
                crossesOpacity = 1
            }

            try? await Task.sleep(nanoseconds: 1_200_000_000)

            // Phase 3: Fade to white (1.8–2.5s)
            withAnimation(.easeIn(duration: 0.7)) {
                whiteOverlayOpacity = 1
            }

            try? await Task.sleep(nanoseconds: 700_000_000)

            onComplete()
        }
    }
}

// MARK: - Preview

#Preview("Cross Transition - Neutral") {
    CrossTransitionView(moodLevel: .neutral) {
        // Animation complete
    }
    .background(Color.gray.opacity(0.3))
}
