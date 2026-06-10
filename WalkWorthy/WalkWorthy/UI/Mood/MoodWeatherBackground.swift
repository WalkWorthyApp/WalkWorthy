//
//  MoodWeatherBackground.swift
//  WalkWorthy
//
//  Full-screen procedural weather background driven by mood score (0.0–1.0).
//  Apple Weather-style rendering: multi-stop atmospheric sky, sun bloom,
//  FBM shader cloud decks, and a particle layer for rain and lightning.
//  Every attribute is a continuous function of the score, so dragging the
//  slider morphs thunderstorm → rain → overcast → partly cloudy → clear.
//

import SwiftUI

// MARK: - Weather Parameters

/// Continuous weather description derived from a mood score. Every knob is
/// interpolated between five keyframes (thunderstorm, rain, overcast,
/// partly cloudy, clear) so the scene morphs smoothly with the slider.
struct WeatherParameters {
    let skyStops: [Color]            // top → horizon
    let farCloudCoverage: Double
    let farCloudDarkness: Double
    let nearCloudCoverage: Double
    let nearCloudDarkness: Double
    let cloudVerticalFade: Double    // y fraction where clouds finish fading out
    let windSpeed: Double            // noise-domain units/sec for the near deck
    let rainIntensity: Double        // 0–1
    let lightningIntensity: Double   // 0–1
    let sunStrength: Double          // 0–1
    let sunElevation: Double         // y fraction of height (smaller = higher)
    let hazeOpacity: Double

    init(moodScore: Double) {
        let t = min(max(moodScore, 0.0), 1.0)
        skyStops = Self.interpolatedSky(at: t)
        farCloudCoverage = Self.lerp([0.92, 0.88, 0.85, 0.50, 0.18], at: t)
        farCloudDarkness = Self.lerp([0.88, 0.66, 0.38, 0.10, 0.02], at: t)
        nearCloudCoverage = Self.lerp([0.97, 0.90, 0.82, 0.42, 0.10], at: t)
        nearCloudDarkness = Self.lerp([0.95, 0.72, 0.45, 0.10, 0.00], at: t)
        cloudVerticalFade = Self.lerp([1.25, 1.15, 1.05, 0.78, 0.55], at: t)
        windSpeed = Self.lerp([0.040, 0.026, 0.016, 0.012, 0.009], at: t)
        rainIntensity = Self.lerp([1.00, 0.55, 0.10, 0.00, 0.00], at: t)
        lightningIntensity = Self.lerp([1.00, 0.00, 0.00, 0.00, 0.00], at: t)
        sunStrength = Self.lerp([0.00, 0.00, 0.10, 0.62, 1.00], at: t)
        sunElevation = Self.lerp([0.40, 0.38, 0.34, 0.22, 0.13], at: t)
        hazeOpacity = Self.lerp([0.06, 0.09, 0.14, 0.18, 0.24], at: t)
    }

    // MARK: Keyframes

    private static let keyScores: [Double] = [0.0, 0.25, 0.5, 0.75, 1.0]

    /// Sky palettes per keyframe, 5 stops top → horizon (storm, rain,
    /// overcast, partly cloudy, clear).
    private static let skyPalettes: [[SIMD3<Double>]] = [
        [rgb(0x0B0E1A), rgb(0x12182B), rgb(0x1C2438), rgb(0x2A3346), rgb(0x3A4456)],
        [rgb(0x252E3B), rgb(0x33404F), rgb(0x435162), rgb(0x566375), rgb(0x6B7889)],
        [rgb(0x57697B), rgb(0x6E7E8E), rgb(0x8493A0), rgb(0x9CA8B2), rgb(0xB4BEC5)],
        [rgb(0x2566B8), rgb(0x3D7FCB), rgb(0x639DDC), rgb(0x90BEEA), rgb(0xC3DEF5)],
        [rgb(0x1B66D4), rgb(0x2F7DE0), rgb(0x559CEB), rgb(0x8CC2F4), rgb(0xD9EEFC)],
    ]

    private static func rgb(_ hex: UInt32) -> SIMD3<Double> {
        SIMD3(
            Double((hex >> 16) & 0xFF) / 255.0,
            Double((hex >> 8) & 0xFF) / 255.0,
            Double(hex & 0xFF) / 255.0
        )
    }

    /// Indices of the keyframes surrounding `t` plus the blend fraction.
    private static func segment(at t: Double) -> (lower: Int, upper: Int, fraction: Double) {
        var lower = 0
        for i in 0..<keyScores.count - 1 where t >= keyScores[i] {
            lower = i
        }
        let upper = min(lower + 1, keyScores.count - 1)
        let range = keyScores[upper] - keyScores[lower]
        let fraction = range > 0 ? (t - keyScores[lower]) / range : 0.0
        return (lower, upper, fraction)
    }

    private static func lerp(_ values: [Double], at t: Double) -> Double {
        let s = segment(at: t)
        return values[s.lower] + (values[s.upper] - values[s.lower]) * s.fraction
    }

    private static func interpolatedSky(at t: Double) -> [Color] {
        let s = segment(at: t)
        return (0..<skyPalettes[s.lower].count).map { stop in
            let mixed = skyPalettes[s.lower][stop] + (skyPalettes[s.upper][stop] - skyPalettes[s.lower][stop]) * s.fraction
            return Color(red: mixed.x, green: mixed.y, blue: mixed.z)
        }
    }
}

// MARK: - Background View

struct MoodWeatherBackground: View {
    let moodScore: Double
    var isCompact: Bool = false

    var body: some View {
        if isCompact {
            compactOrb
        } else {
            WeatherScene(params: WeatherParameters(moodScore: moodScore))
                .animation(.easeInOut(duration: 0.5), value: moodScore)
        }
    }

    // MARK: Compact Orb

    private var compactOrb: some View {
        let params = WeatherParameters(moodScore: moodScore)
        let top = params.skyStops[0]
        let bottom = params.skyStops[3]
        return Circle()
            .fill(
                LinearGradient(
                    colors: [top, bottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
            .shadow(color: bottom.opacity(0.6), radius: scaled(20))
            .frame(width: scaled(100), height: scaled(100))
            .animation(.easeInOut(duration: 0.5), value: moodScore)
    }
}

// MARK: - Weather Scene

private struct WeatherScene: View {
    let params: WeatherParameters

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var startDate = Date()

    var body: some View {
        GeometryReader { geo in
            ZStack {
                sky
                sun(in: geo.size)
                cloudDecks(in: geo.size)
                horizonHaze
                WeatherParticleSystem(
                    rainIntensity: params.rainIntensity,
                    lightningIntensity: params.lightningIntensity
                )
            }
        }
        .ignoresSafeArea()
    }

    // MARK: Sky

    private var sky: some View {
        LinearGradient(
            colors: params.skyStops,
            startPoint: .top,
            endPoint: .bottom
        )
    }

    // MARK: Sun

    /// Layered bloom: bright core, warm halo, wide atmospheric glow.
    /// Sits behind the cloud decks so overcast skies diffuse it.
    private func sun(in size: CGSize) -> some View {
        let center = CGPoint(x: size.width * 0.30, y: size.height * params.sunElevation)
        return ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [Color(red: 1.0, green: 0.95, blue: 0.84).opacity(0.50), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: scaled(300)
                    )
                )
                .frame(width: scaled(600), height: scaled(600))
                .position(center)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color(red: 1.0, green: 0.91, blue: 0.66).opacity(0.85),
                            Color(red: 1.0, green: 0.84, blue: 0.42).opacity(0.22),
                            .clear,
                        ],
                        center: .center,
                        startRadius: scaled(8),
                        endRadius: scaled(130)
                    )
                )
                .frame(width: scaled(260), height: scaled(260))
                .position(center)

            Circle()
                .fill(Color.white)
                .frame(width: scaled(52), height: scaled(52))
                .blur(radius: scaled(7))
                .position(center)
        }
        .compositingGroup()
        .blendMode(.screen)
        .opacity(params.sunStrength)
    }

    // MARK: Cloud Decks

    /// Two parallax FBM shader layers: a distant slow deck and a nearer,
    /// faster one. Slow drift only needs 30fps.
    private func cloudDecks(in size: CGSize) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { timeline in
            let time = reduceMotion ? 0.0 : timeline.date.timeIntervalSince(startDate)
            ZStack {
                cloudDeck(
                    size: size,
                    coverage: params.farCloudCoverage,
                    darkness: params.farCloudDarkness,
                    scale: 3.4,
                    windOffset: time * params.windSpeed * 0.45 + 7.3,
                    verticalFade: params.cloudVerticalFade
                )
                .opacity(0.85)

                cloudDeck(
                    size: size,
                    coverage: params.nearCloudCoverage,
                    darkness: params.nearCloudDarkness,
                    scale: 2.0,
                    windOffset: time * params.windSpeed + 23.1,
                    verticalFade: params.cloudVerticalFade
                )
            }
        }
    }

    private func cloudDeck(
        size: CGSize,
        coverage: Double,
        darkness: Double,
        scale: Double,
        windOffset: Double,
        verticalFade: Double
    ) -> some View {
        Rectangle()
            .fill(Color.white)
            .colorEffect(
                ShaderLibrary.cloudLayer(
                    .float2(size),
                    .float(coverage),
                    .float(darkness),
                    .float(scale),
                    .float(windOffset),
                    .float(verticalFade)
                )
            )
    }

    // MARK: Horizon Haze

    /// Atmospheric perspective near the horizon — the depth cue that keeps
    /// the gradient sky from looking flat.
    private var horizonHaze: some View {
        LinearGradient(
            stops: [
                .init(color: .clear, location: 0.0),
                .init(color: .clear, location: 0.55),
                .init(color: Color(red: 0.95, green: 0.94, blue: 0.90).opacity(params.hazeOpacity), location: 1.0),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

#Preview("Full - Thunderstorm") {
    MoodWeatherBackground(moodScore: 0.0)
}

#Preview("Full - Rain") {
    MoodWeatherBackground(moodScore: 0.25)
}

#Preview("Full - Overcast") {
    MoodWeatherBackground(moodScore: 0.5)
}

#Preview("Full - Partly Cloudy") {
    MoodWeatherBackground(moodScore: 0.75)
}

#Preview("Full - Sunny") {
    MoodWeatherBackground(moodScore: 1.0)
}

#Preview("Compact Orb") {
    MoodWeatherBackground(moodScore: 0.7, isCompact: true)
        .frame(width: 200, height: 200)
        .background(Color.black)
}
