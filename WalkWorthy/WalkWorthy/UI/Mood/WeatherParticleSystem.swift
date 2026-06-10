//
//  WeatherParticleSystem.swift
//  WalkWorthy
//
//  TimelineView + Canvas precipitation layer for the mood weather scene.
//  Depth-layered wind-blown rain and branched lightning with cloud
//  illumination, driven by intensities from WeatherParameters.
//

import SwiftUI

struct WeatherParticleSystem: View {
    let rainIntensity: Double       // 0–1
    let lightningIntensity: Double  // 0–1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { timeline in
            Canvas { context, size in
                // Frozen timestamp under Reduce Motion renders one static
                // frame — rain streaks read like a photograph.
                let time = reduceMotion ? 41.7 : timeline.date.timeIntervalSinceReferenceDate

                if rainIntensity > 0.01 {
                    drawRain(context: context, size: size, time: time)
                }
                // No lightning under Reduce Motion — flashing is also an
                // accessibility concern, not just a motion one.
                if lightningIntensity > 0.01 && !reduceMotion {
                    drawLightning(context: context, size: size, time: time)
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Rain

    /// Three depth layers: far = slow/short/faint, near = fast/long/bold.
    /// A shared wind angle makes the layers read as one storm.
    private struct RainLayer {
        let dropCount: Int
        let minSpeed: Double
        let maxSpeed: Double
        let minLength: Double
        let maxLength: Double
        let lineWidth: CGFloat
        let opacity: Double
    }

    private static let rainLayers: [RainLayer] = [
        RainLayer(dropCount: 44, minSpeed: 320, maxSpeed: 430, minLength: 11, maxLength: 17, lineWidth: 0.8, opacity: 0.20),
        RainLayer(dropCount: 36, minSpeed: 470, maxSpeed: 600, minLength: 18, maxLength: 26, lineWidth: 1.1, opacity: 0.32),
        RainLayer(dropCount: 26, minSpeed: 640, maxSpeed: 820, minLength: 28, maxLength: 42, lineWidth: 1.6, opacity: 0.45),
    ]

    /// Rain leans ~10° with the wind; streaks are drawn along their velocity.
    private static let windSlope = 0.18

    private func drawRain(context: GraphicsContext, size: CGSize, time: Double) {
        let rainColor = Color(red: 0.78, green: 0.85, blue: 0.95)

        for (layerIndex, layer) in Self.rainLayers.enumerated() {
            // sqrt keeps some far-layer depth alive at drizzle intensities.
            let activeCount = Int(Double(layer.dropCount) * rainIntensity.squareRoot())
            guard activeCount > 0 else { continue }
            let opacity = layer.opacity * (0.6 + 0.4 * rainIntensity)

            for i in 0..<activeCount {
                let seed = Self.dropSeeds[(i &+ layerIndex &* 17) % Self.dropSeeds.count]
                let speed = scaled(layer.minSpeed + (layer.maxSpeed - layer.minSpeed) * seed.speedUnit)
                let length = scaled(layer.minLength + (layer.maxLength - layer.minLength) * seed.lengthUnit)

                // Fall and wrap within a band slightly taller than the view.
                let band = size.height + length * 2
                let travel = time * speed + seed.travelOffset * band
                let y = travel.truncatingRemainder(dividingBy: band) - length

                // Drift sideways with the wind as the drop falls; wrap on x.
                let xBase = (seed.xFraction + Double(layerIndex) * 0.37) * size.width
                let x = (xBase + y * Self.windSlope).truncatingRemainder(dividingBy: size.width)
                let xWrapped = x < 0 ? x + size.width : x

                let head = CGPoint(x: xWrapped, y: y)
                let tail = CGPoint(x: xWrapped + Self.windSlope * length, y: y + length)

                var path = Path()
                path.move(to: head)
                path.addLine(to: tail)

                let style = StrokeStyle(lineWidth: scaled(layer.lineWidth), lineCap: .round)
                if layerIndex == 0 {
                    // Far layer: solid strokes — cheaper, and the fade is
                    // invisible at this scale anyway.
                    context.stroke(path, with: .color(rainColor.opacity(opacity)), style: style)
                } else {
                    // Streak fades along its length — reads as motion blur,
                    // brightest at the falling edge.
                    context.stroke(
                        path,
                        with: .linearGradient(
                            Gradient(colors: [rainColor.opacity(0), rainColor.opacity(opacity)]),
                            startPoint: head,
                            endPoint: tail
                        ),
                        style: style
                    )
                }
            }
        }
    }

    // MARK: - Lightning

    private func drawLightning(context: GraphicsContext, size: CGSize, time: Double) {
        let cycleLength = 4.0
        let cycle = (time / cycleLength).rounded(.down)
        // Roughly 1 in 5 cycles stays dark so strikes feel irregular.
        guard Self.hash(cycle * 17.31) < 0.8 else { return }

        let phase = time - cycle * cycleLength
        let brightness = Self.flickerEnvelope(phase) * lightningIntensity
        guard brightness > 0.01 else { return }

        let origin = CGPoint(
            x: (0.22 + Self.hash(cycle * 31.7 + 3.1) * 0.56) * size.width,
            y: size.height * 0.04
        )

        // Cloud illumination — a bloom centered on the strike origin rather
        // than a flat full-screen wash.
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .radialGradient(
                Gradient(colors: [Color.white.opacity(0.30 * brightness), .clear]),
                center: origin,
                startRadius: 0,
                endRadius: size.width * 0.9
            )
        )

        // The bolt itself only shows during the bright pulses.
        guard phase < 0.26, brightness > 0.3 * lightningIntensity else { return }

        let bolt = Self.boltPath(cycle: cycle, origin: origin, size: size)
        let boltColor = Color(red: 1.0, green: 1.0, blue: 0.88)

        var wideGlow = context
        wideGlow.addFilter(.blur(radius: scaled(7)))
        wideGlow.stroke(bolt, with: .color(boltColor.opacity(0.7 * brightness)), lineWidth: scaled(6))

        var innerGlow = context
        innerGlow.addFilter(.blur(radius: scaled(2.5)))
        innerGlow.stroke(bolt, with: .color(boltColor.opacity(0.9 * brightness)), lineWidth: scaled(2.6))

        context.stroke(bolt, with: .color(Color.white.opacity(brightness)), lineWidth: scaled(1.1))
    }

    /// Real lightning strobes: bright leader, brief dropout, a second return
    /// stroke, then a slow afterglow decay over ~half a second.
    private static func flickerEnvelope(_ phase: Double) -> Double {
        switch phase {
        case ..<0.07: return 1.0
        case ..<0.12: return 0.25
        case ..<0.20: return 0.85
        case ..<0.55: return 0.85 * (1.0 - (phase - 0.20) / 0.35)
        default: return 0.0
        }
    }

    /// Jagged main trunk with two short branches. Geometry is a pure
    /// function of the cycle index, so each strike looks different but a
    /// single strike is stable across frames.
    private static func boltPath(cycle: Double, origin: CGPoint, size: CGSize) -> Path {
        var path = Path()
        let segments = 8
        let segmentDrop = size.height * 0.5 / CGFloat(segments)

        var point = origin
        path.move(to: point)
        var trunkPoints: [CGPoint] = [point]

        for seg in 0..<segments {
            let jitter = hash(cycle * 7.7 + Double(seg) * 13.3) - 0.5
            point.x += jitter * scaled(52)
            point.y += segmentDrop * (0.85 + 0.3 * hash(cycle * 3.3 + Double(seg) * 5.1))
            path.addLine(to: point)
            trunkPoints.append(point)
        }

        for (branchIndex, sourceSegment) in [2, 5].enumerated() {
            var branchPoint = trunkPoints[sourceSegment]
            path.move(to: branchPoint)
            let direction: CGFloat = hash(cycle * 11.1 + Double(branchIndex)) < 0.5 ? -1 : 1
            for seg in 0..<3 {
                let jitter = hash(cycle * 9.4 + Double(branchIndex * 10 + seg) * 3.7)
                branchPoint.x += direction * scaled(14 + 18 * jitter)
                branchPoint.y += segmentDrop * (0.5 + 0.4 * jitter)
                path.addLine(to: branchPoint)
            }
        }

        return path
    }

    // MARK: - Deterministic Seeds

    private struct DropSeed {
        let xFraction: Double
        let travelOffset: Double
        let speedUnit: Double
        let lengthUnit: Double
    }

    /// Fixed seeds so drops don't jump between frames.
    private static let dropSeeds: [DropSeed] = (0..<44).map { i in
        let n = Double(i)
        return DropSeed(
            xFraction: hash(n * 12.9898),
            travelOffset: hash(n * 78.233 + 1.0),
            speedUnit: hash(n * 37.719 + 2.0),
            lengthUnit: hash(n * 93.989 + 3.0)
        )
    }

    /// Deterministic hash → [0, 1). Same trick as the shader's noise hash.
    private static func hash(_ n: Double) -> Double {
        let s = sin(n + 311.7) * 43758.5453
        return s - s.rounded(.down)
    }
}

#Preview("Storm") {
    WeatherParticleSystem(rainIntensity: 1.0, lightningIntensity: 1.0)
        .background(Color(red: 0.06, green: 0.07, blue: 0.12))
}

#Preview("Light Rain") {
    WeatherParticleSystem(rainIntensity: 0.4, lightningIntensity: 0.0)
        .background(Color(red: 0.25, green: 0.30, blue: 0.36))
}
