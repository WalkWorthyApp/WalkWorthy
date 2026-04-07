//
//  MoodWeatherBackground.swift
//  WalkWorthy
//
//  Full-screen animated weather background driven by mood score (0.0–1.0).
//  Inspired by Apple Weather app aesthetics with smooth cross-fading scenes.
//

import SwiftUI

struct MoodWeatherBackground: View {
    let moodScore: Double
    var isCompact: Bool = false

    var body: some View {
        if isCompact {
            compactOrb
        } else {
            fullBackground
        }
    }

    // MARK: - Full Background

    private var fullBackground: some View {
        ZStack {
            skyGradient

            sceneElements

            WeatherParticleSystem(moodScore: moodScore)
        }
        .ignoresSafeArea()
        .animation(.easeInOut(duration: 0.5), value: moodScore)
    }

    // MARK: - Compact Orb

    private var compactOrb: some View {
        let colors = interpolatedColors
        return Circle()
            .fill(
                LinearGradient(
                    colors: [colors.top, colors.bottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
            .shadow(color: colors.bottom.opacity(0.6), radius: 20)
            .frame(width: 100, height: 100)
            .animation(.easeInOut(duration: 0.5), value: moodScore)
    }

    // MARK: - Sky Gradient

    private var skyGradient: some View {
        let colors = interpolatedColors
        return LinearGradient(
            colors: [colors.top, colors.bottom],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: - Scene Elements

    @ViewBuilder
    private var sceneElements: some View {
        // Thunderstorm (0.0–0.2)
        thunderstormScene
            .opacity(rangeOpacity(low: 0.0, high: 0.2))

        // Overcast (0.2–0.4)
        overcastScene
            .opacity(rangeOpacity(low: 0.2, high: 0.4))

        // Beach (0.4–0.6)
        beachScene
            .opacity(rangeOpacity(low: 0.4, high: 0.6))

        // Pleasant (0.6–0.8)
        pleasantScene
            .opacity(rangeOpacity(low: 0.6, high: 0.8))

        // Sunny field (0.8–1.0)
        sunnyFieldScene
            .opacity(rangeOpacity(low: 0.8, high: 1.0))
    }

    // MARK: - Thunderstorm Scene

    private var thunderstormScene: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                // Dark jagged clouds
                RoundedRectangle(cornerRadius: 25)
                    .fill(Color(hex: 0x2D1B4E).opacity(0.9))
                    .frame(width: w * 0.5, height: 50)
                    .offset(x: -w * 0.1, y: h * 0.08)

                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(hex: 0x3D1C5A).opacity(0.85))
                    .frame(width: w * 0.4, height: 40)
                    .offset(x: w * 0.15, y: h * 0.05)

                RoundedRectangle(cornerRadius: 17)
                    .fill(Color(hex: 0x1A0A2E).opacity(0.8))
                    .frame(width: w * 0.35, height: 35)
                    .offset(x: -w * 0.2, y: h * 0.12)

                RoundedRectangle(cornerRadius: 22)
                    .fill(Color(hex: 0x2D1B4E).opacity(0.75))
                    .frame(width: w * 0.45, height: 45)
                    .offset(x: w * 0.25, y: h * 0.1)

                // Rain streaks (static decorative hints — particle system handles animated rain)
                ForEach(0..<12, id: \.self) { i in
                    let seedHeight = Self.rainStreakHeights[i % Self.rainStreakHeights.count]
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(0.3))
                        .frame(width: 1, height: seedHeight)
                        .offset(
                            x: CGFloat(i) * (w / 12) - w / 2 + 20,
                            y: h * 0.3 + CGFloat(i % 3) * 20
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Overcast Scene

    private var overcastScene: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                // Heavy grey cloud layers
                RoundedRectangle(cornerRadius: 27)
                    .fill(Color(hex: 0x4A5568).opacity(0.85))
                    .frame(width: w * 0.6, height: 55)
                    .offset(x: -w * 0.05, y: h * 0.06)

                RoundedRectangle(cornerRadius: 25)
                    .fill(Color(hex: 0x718096).opacity(0.75))
                    .frame(width: w * 0.55, height: 50)
                    .offset(x: w * 0.1, y: h * 0.1)

                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(hex: 0x4A5568).opacity(0.7))
                    .frame(width: w * 0.45, height: 40)
                    .offset(x: -w * 0.15, y: h * 0.14)

                // Lighter drizzle hints
                ForEach(0..<8, id: \.self) { i in
                    let seedHeight = Self.drizzleHeights[i % Self.drizzleHeights.count]
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.white.opacity(0.2))
                        .frame(width: 1, height: seedHeight)
                        .offset(
                            x: CGFloat(i) * (w / 8) - w / 2 + 30,
                            y: h * 0.35 + CGFloat(i % 4) * 15
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Beach Scene

    private var beachScene: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                // Ocean below horizon
                Rectangle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hex: 0x2980B9).opacity(0.6),
                                Color(hex: 0x1A5276).opacity(0.4),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(height: h * 0.35)
                    .offset(y: h * 0.325)

                // Gentle wave hint
                Ellipse()
                    .fill(Color(hex: 0x2980B9).opacity(0.3))
                    .frame(width: w * 1.2, height: 30)
                    .offset(y: h * 0.18)

                Ellipse()
                    .fill(Color(hex: 0x3498DB).opacity(0.2))
                    .frame(width: w * 1.1, height: 25)
                    .offset(y: h * 0.22)

                // Soft sun near horizon
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(hex: 0xF6D365).opacity(0.8),
                                Color(hex: 0xF6D365).opacity(0.0),
                            ],
                            center: .center,
                            startRadius: 15,
                            endRadius: 60
                        )
                    )
                    .frame(width: 120, height: 120)
                    .offset(x: w * 0.15, y: h * 0.08)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Pleasant Scene

    private var pleasantScene: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                // Warm partial sun in upper right
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color(hex: 0xF6A623).opacity(0.9),
                                Color(hex: 0xF6A623).opacity(0.0),
                            ],
                            center: .center,
                            startRadius: 20,
                            endRadius: 80
                        )
                    )
                    .frame(width: 160, height: 160)
                    .offset(x: w * 0.25, y: -h * 0.25)

                Circle()
                    .fill(Color(hex: 0xFDB813).opacity(0.95))
                    .frame(width: 50, height: 50)
                    .offset(x: w * 0.25, y: -h * 0.25)

                // Light cloud puffs
                Ellipse()
                    .fill(Color.white.opacity(0.5))
                    .frame(width: 80, height: 30)
                    .offset(x: -w * 0.2, y: -h * 0.15)

                Ellipse()
                    .fill(Color.white.opacity(0.4))
                    .frame(width: 60, height: 25)
                    .offset(x: w * 0.1, y: -h * 0.1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Sunny Field Scene

    private var sunnyFieldScene: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                // Bright full sun
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(0.9),
                                Color(hex: 0xFDB813).opacity(0.7),
                                Color(hex: 0xFDB813).opacity(0.0),
                            ],
                            center: .center,
                            startRadius: 15,
                            endRadius: 100
                        )
                    )
                    .frame(width: 200, height: 200)
                    .offset(x: w * 0.1, y: -h * 0.3)

                Circle()
                    .fill(Color(hex: 0xFDB813))
                    .frame(width: 60, height: 60)
                    .offset(x: w * 0.1, y: -h * 0.3)

                // Rolling green hill silhouette
                Ellipse()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hex: 0x6BCB77).opacity(0.7),
                                Color(hex: 0x4A9E5C).opacity(0.5),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: w * 1.4, height: h * 0.4)
                    .offset(y: h * 0.38)

                Ellipse()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(hex: 0x82D98E).opacity(0.6),
                                Color(hex: 0x5CB86B).opacity(0.4),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: w * 1.2, height: h * 0.35)
                    .offset(x: -w * 0.1, y: h * 0.42)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Static Seeds (avoid CGFloat.random in view body)

    private static let rainStreakHeights: [CGFloat] = [10, 12, 8, 14, 11, 9, 13, 15, 10, 8, 12, 14]
    private static let drizzleHeights: [CGFloat] = [7, 9, 6, 8, 10, 7, 9, 6]

    // MARK: - Color Interpolation

    private static let paletteStops: [(score: Double, top: (r: Double, g: Double, b: Double), bottom: (r: Double, g: Double, b: Double))] = [
        (0.0,  (0x1A / 255.0, 0x0A / 255.0, 0x2E / 255.0), (0x3D / 255.0, 0x1C / 255.0, 0x5A / 255.0)),
        (0.25, (0x2C / 255.0, 0x3E / 255.0, 0x50 / 255.0), (0x4A / 255.0, 0x55 / 255.0, 0x68 / 255.0)),
        (0.5,  (0x29 / 255.0, 0x80 / 255.0, 0xB9 / 255.0), (0xC9 / 255.0, 0xA9 / 255.0, 0x6E / 255.0)),
        (0.75, (0xF6 / 255.0, 0xA6 / 255.0, 0x23 / 255.0), (0xF5 / 255.0, 0xCB / 255.0, 0xA7 / 255.0)),
        (1.0,  (0x87 / 255.0, 0xCE / 255.0, 0xEB / 255.0), (0x98 / 255.0, 0xFB / 255.0, 0x98 / 255.0)),
    ]

    private var interpolatedColors: (top: Color, bottom: Color) {
        let score = min(max(moodScore, 0.0), 1.0)
        let stops = Self.paletteStops

        // Find the two surrounding stops
        var lowerIdx = 0
        for i in 0..<stops.count - 1 {
            if score >= stops[i].score {
                lowerIdx = i
            }
        }
        let upperIdx = min(lowerIdx + 1, stops.count - 1)

        let lower = stops[lowerIdx]
        let upper = stops[upperIdx]

        let range = upper.score - lower.score
        let t = range > 0 ? (score - lower.score) / range : 0.0

        let topR = lower.top.r + (upper.top.r - lower.top.r) * t
        let topG = lower.top.g + (upper.top.g - lower.top.g) * t
        let topB = lower.top.b + (upper.top.b - lower.top.b) * t

        let botR = lower.bottom.r + (upper.bottom.r - lower.bottom.r) * t
        let botG = lower.bottom.g + (upper.bottom.g - lower.bottom.g) * t
        let botB = lower.bottom.b + (upper.bottom.b - lower.bottom.b) * t

        return (
            top: Color(red: topR, green: topG, blue: topB),
            bottom: Color(red: botR, green: botG, blue: botB)
        )
    }

    // MARK: - Range Opacity

    /// Returns 1.0 when moodScore is fully within [low, high], fading to 0.0 outside with a 0.1 margin.
    private func rangeOpacity(low: Double, high: Double) -> Double {
        let score = min(max(moodScore, 0.0), 1.0)
        let fadeMargin = 0.1
        let center = (low + high) / 2.0
        let halfWidth = (high - low) / 2.0

        let distance = abs(score - center)
        if distance <= halfWidth {
            return 1.0
        } else if distance <= halfWidth + fadeMargin {
            return 1.0 - (distance - halfWidth) / fadeMargin
        } else {
            return 0.0
        }
    }
}

// MARK: - Color Hex Extension

private extension Color {
    init(hex: UInt32) {
        let r = Double((hex >> 16) & 0xFF) / 255.0
        let g = Double((hex >> 8) & 0xFF) / 255.0
        let b = Double(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b)
    }
}

#Preview("Full - Thunderstorm") {
    MoodWeatherBackground(moodScore: 0.1)
}

#Preview("Full - Beach") {
    MoodWeatherBackground(moodScore: 0.5)
}

#Preview("Full - Sunny") {
    MoodWeatherBackground(moodScore: 0.9)
}

#Preview("Compact Orb") {
    MoodWeatherBackground(moodScore: 0.7, isCompact: true)
        .frame(width: 200, height: 200)
        .background(Color.black)
}
