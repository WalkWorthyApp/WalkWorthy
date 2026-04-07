//
//  WeatherParticleSystem.swift
//  WalkWorthy
//
//  TimelineView + Canvas particle system for mood weather effects.
//  Rain, lightning, waves, grass, and clouds driven by moodScore (0.0–1.0).
//

import SwiftUI

struct WeatherParticleSystem: View {
    let moodScore: Double

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate

                drawRain(context: &context, size: size, time: time)
                drawLightning(context: &context, size: size, time: time)
                drawBeachWaves(context: &context, size: size, time: time)
                drawClouds(context: &context, size: size, time: time)
                drawGrass(context: &context, size: size, time: time)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Rain (moodScore 0.0–0.5, intensity peaks at 0.0)

    private func drawRain(context: inout GraphicsContext, size: CGSize, time: Double) {
        guard moodScore < 0.5 else { return }

        // Intensity: 1.0 at score 0.0, fading to 0.0 at score 0.5
        let intensity = max(0, 1.0 - moodScore / 0.5)
        let particleCount = Int(60.0 * intensity)

        for i in 0..<particleCount {
            let seed = Self.rainSeeds[i % Self.rainSeeds.count]

            // Horizontal position: fixed per particle, scattered across width
            let x = seed.xFraction * size.width

            // Vertical position: falls at varying speed, wraps around
            let speed = seed.speed  // 200–400 pt/sec
            let totalFall = time * speed + seed.yOffset * size.height
            let y = totalFall.truncatingRemainder(dividingBy: Double(size.height))

            let height = seed.length  // 8–15pt

            var path = Path()
            path.move(to: CGPoint(x: x, y: y))
            path.addLine(to: CGPoint(x: x, y: y + height))

            context.stroke(
                path,
                with: .color(.white.opacity(0.4 * intensity)),
                lineWidth: 1
            )
        }
    }

    // MARK: - Lightning (moodScore 0.0–0.2)

    private func drawLightning(context: inout GraphicsContext, size: CGSize, time: Double) {
        guard moodScore < 0.2 else { return }

        let intensity = max(0, 1.0 - moodScore / 0.2)

        // Flash cycle: bolt appears every ~3 seconds, visible for 0.15s
        let cycleLength = 3.0
        let flashDuration = 0.15
        let phase = time.truncatingRemainder(dividingBy: cycleLength)

        guard phase < flashDuration else { return }

        // Brief screen flash
        let flashRect = Path(CGRect(origin: .zero, size: size))
        context.fill(flashRect, with: .color(.white.opacity(0.15 * intensity)))

        // Jagged bolt from near top-center downward
        let boltStartX = size.width * 0.45
        let boltStartY = size.height * 0.05
        let segments = 6
        let segmentHeight = 30.0

        var path = Path()
        path.move(to: CGPoint(x: boltStartX, y: boltStartY))

        var currentX = boltStartX
        var currentY = boltStartY

        for seg in 0..<segments {
            // Alternate zig-zag direction using deterministic offset
            let zigDirection: Double = seg.isMultiple(of: 2) ? 1.0 : -1.0
            let xOffset = zigDirection * Double(15 + (seg * 7) % 20)
            currentX += xOffset
            currentY += segmentHeight
            path.addLine(to: CGPoint(x: currentX, y: currentY))
        }

        context.stroke(
            path,
            with: .color(Color(red: 1.0, green: 1.0, blue: 0.8).opacity(0.9 * intensity)),
            lineWidth: 2
        )
    }

    // MARK: - Beach Waves (moodScore 0.4–0.6)

    private func drawBeachWaves(context: inout GraphicsContext, size: CGSize, time: Double) {
        guard moodScore >= 0.4 && moodScore <= 0.6 else { return }

        // Opacity peaks at 0.5
        let proximity = 1.0 - abs(moodScore - 0.5) / 0.1
        let opacity = max(0, min(1, proximity)) * 0.3

        let waveCount = 3
        for wave in 0..<waveCount {
            let baseY = size.height * (0.65 + Double(wave) * 0.06)
            let amplitude = 6.0 - Double(wave) * 1.5
            let phaseOffset = time * 0.5 + Double(wave) * 1.2

            var path = Path()
            let steps = 40
            for step in 0...steps {
                let fraction = Double(step) / Double(steps)
                let x = fraction * size.width
                let y = baseY + sin(fraction * .pi * 4 + phaseOffset) * amplitude

                if step == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }

            context.stroke(
                path,
                with: .color(Color(red: 0.2, green: 0.7, blue: 0.8).opacity(opacity)),
                lineWidth: 1.5
            )
        }
    }

    // MARK: - Cloud Drift (moodScore 0.5–1.0)

    private func drawClouds(context: inout GraphicsContext, size: CGSize, time: Double) {
        guard moodScore >= 0.5 else { return }

        // Opacity: 20% at neutral, 60% at very pleasant
        let t = min(max((moodScore - 0.5) / 0.5, 0), 1)
        let baseOpacity = 0.2 + t * 0.4

        for i in 0..<3 {
            let seed = Self.cloudSeeds[i]

            // Drift slowly rightward, wrap
            let speed = seed.speed  // ~15–25 pt/sec
            let totalDrift = time * speed + seed.startX * size.width
            let x = totalDrift.truncatingRemainder(dividingBy: size.width + 120) - 60

            let y = seed.yFraction * size.height * 0.4

            // Cloud = overlapping circles
            let r1 = seed.radius1
            let r2 = seed.radius2
            let r3 = seed.radius3

            let cloudColor = Color.white.opacity(baseOpacity)

            let circle1 = Path(ellipseIn: CGRect(x: x - r1, y: y - r1, width: r1 * 2, height: r1 * 2))
            let circle2 = Path(ellipseIn: CGRect(x: x + r1 * 0.7 - r2, y: y - r2 * 0.5 - r2, width: r2 * 2, height: r2 * 2))
            let circle3 = Path(ellipseIn: CGRect(x: x + r1 * 1.2 - r3, y: y - r3, width: r3 * 2, height: r3 * 2))

            context.fill(circle1, with: .color(cloudColor))
            context.fill(circle2, with: .color(cloudColor))
            context.fill(circle3, with: .color(cloudColor))
        }
    }

    // MARK: - Grass Blades (moodScore 0.7–1.0, intensity peaks at 1.0)

    private func drawGrass(context: inout GraphicsContext, size: CGSize, time: Double) {
        guard moodScore >= 0.7 else { return }

        let intensity = min(max((moodScore - 0.7) / 0.3, 0), 1)
        let bladeCount = Int(40.0 * intensity)

        for i in 0..<bladeCount {
            let seed = Self.grassSeeds[i % Self.grassSeeds.count]

            let baseX = seed.xFraction * size.width
            let baseY = size.height
            let height = seed.height  // 20–40pt

            // Sway with sine wave
            let swayAmount = 8.0 * intensity
            let sway = sin(time * 1.5 + seed.phaseOffset) * swayAmount

            let tipX = baseX + sway
            let tipY = baseY - height

            // Control point for curve
            let ctrlX = baseX + sway * 0.5
            let ctrlY = baseY - height * 0.6

            var path = Path()
            path.move(to: CGPoint(x: baseX, y: baseY))
            path.addQuadCurve(
                to: CGPoint(x: tipX, y: tipY),
                control: CGPoint(x: ctrlX, y: ctrlY)
            )

            let greenValue = 0.5 + seed.greenVariation * 0.3
            context.stroke(
                path,
                with: .color(Color(red: 0.2, green: greenValue, blue: 0.15).opacity(0.7 * intensity)),
                lineWidth: 1.5
            )
        }
    }

    // MARK: - Deterministic Seeds

    /// Fixed seeds so particles don't jump on re-render.
    private struct RainSeed {
        let xFraction: Double
        let yOffset: Double
        let speed: Double
        let length: Double
    }

    private struct CloudSeed {
        let startX: Double
        let yFraction: Double
        let speed: Double
        let radius1: Double
        let radius2: Double
        let radius3: Double
    }

    private struct GrassSeed {
        let xFraction: Double
        let height: Double
        let phaseOffset: Double
        let greenVariation: Double
    }

    // Pre-computed deterministic seeds — avoids random in render loop
    private static let rainSeeds: [RainSeed] = {
        var seeds: [RainSeed] = []
        for i in 0..<60 {
            let hash = Double(((i &* 2654435761) & 0xFFFF))  // simple hash
            let xFrac = Double(i) / 60.0 + (hash / 65535.0) * 0.015
            let yOff = (hash.truncatingRemainder(dividingBy: 100)) / 100.0
            let speed = 200.0 + (hash.truncatingRemainder(dividingBy: 200))
            let length = 8.0 + (hash.truncatingRemainder(dividingBy: 7))
            seeds.append(RainSeed(xFraction: xFrac, yOffset: yOff, speed: speed, length: length))
        }
        return seeds
    }()

    private static let cloudSeeds: [CloudSeed] = [
        CloudSeed(startX: 0.1, yFraction: 0.15, speed: 15, radius1: 20, radius2: 16, radius3: 14),
        CloudSeed(startX: 0.5, yFraction: 0.25, speed: 20, radius1: 25, radius2: 18, radius3: 20),
        CloudSeed(startX: 0.8, yFraction: 0.10, speed: 12, radius1: 18, radius2: 22, radius3: 15),
    ]

    private static let grassSeeds: [GrassSeed] = {
        var seeds: [GrassSeed] = []
        for i in 0..<40 {
            let hash = Double(((i &* 2654435761) & 0xFFFF))
            let xFrac = Double(i) / 40.0 + (hash / 65535.0) * 0.02
            let height = 20.0 + (hash.truncatingRemainder(dividingBy: 20))
            let phase = Double(i) * 0.7 + (hash / 65535.0) * 2.0
            let greenVar = (hash.truncatingRemainder(dividingBy: 100)) / 100.0
            seeds.append(GrassSeed(xFraction: xFrac, height: height, phaseOffset: phase, greenVariation: greenVar))
        }
        return seeds
    }()
}

#Preview("Rain & Lightning") {
    WeatherParticleSystem(moodScore: 0.1)
        .background(Color(red: 0.1, green: 0.04, blue: 0.18))
}

#Preview("Beach Waves") {
    WeatherParticleSystem(moodScore: 0.5)
        .background(Color(red: 0.16, green: 0.5, blue: 0.72))
}

#Preview("Grass & Clouds") {
    WeatherParticleSystem(moodScore: 0.9)
        .background(Color(red: 0.53, green: 0.81, blue: 0.92))
}
