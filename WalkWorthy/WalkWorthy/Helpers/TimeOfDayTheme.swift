//
//  TimeOfDayTheme.swift
//  WalkWorthy
//
//  Surface colors (backdrop / card / recessed) keyed to time of day.
//  Night keeps the ColorSet assets byte-for-byte; morning and midday
//  shift hue to match the sunrise and meadow hero images.
//

import SwiftUI

struct TimeOfDayTheme {
    let timeOfDay: TimeOfDay

    static var current: TimeOfDayTheme {
        TimeOfDayTheme(timeOfDay: .current)
    }

    // Full-screen backdrop. Gradient for morning/midday, solid-equivalent for night.
    var backdrop: LinearGradient {
        switch timeOfDay {
        case .morning:
            // Warm-orange glow near the top (behind + just below the sunrise hero),
            // blending into a dusky baby-blue base.
            return LinearGradient(
                stops: [
                    .init(color: Self.morningWarm, location: 0.00),
                    .init(color: Self.morningWarm, location: 0.35),
                    .init(color: Self.morningBlue, location: 0.55),
                    .init(color: Self.morningBlue, location: 1.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        case .midday:
            return LinearGradient(
                colors: [Self.middayGreenTop, Self.middayGreenBottom],
                startPoint: .top,
                endPoint: .bottom
            )
        case .night:
            let navy = Color("AppBackground")
            return LinearGradient(colors: [navy, navy], startPoint: .top, endPoint: .bottom)
        }
    }

    // Color the hero image's bottom edge fades into, so the hero → backdrop
    // transition reads as a single continuous surface.
    var heroFadeTarget: Color {
        switch timeOfDay {
        case .morning: return Self.morningWarm
        case .midday:  return Self.middayGreenTop
        case .night:   return Color("AppBackground")
        }
    }

    var card: Color {
        switch timeOfDay {
        case .morning: return Self.morningCard
        case .midday:  return Self.middayCard
        case .night:   return Color("CardBackground")
        }
    }

    var recessed: Color {
        switch timeOfDay {
        case .morning: return Self.morningRecessed
        case .midday:  return Self.middayRecessed
        case .night:   return Color("RecessedBackground")
        }
    }

    // MARK: - Palette (sRGB, tuned for dark-mode legibility)

    // Morning
    private static let morningWarm     = Color(red: 0.353, green: 0.239, blue: 0.169) // #5A3D2B (warm sunrise)
    private static let morningBlue     = Color(red: 0.145, green: 0.235, blue: 0.353) // #253C5A (darker dusky base)
    private static let morningCard     = Color(red: 0.271, green: 0.408, blue: 0.537) // #456889 (lighter baby blue)
    private static let morningRecessed = Color(red: 0.196, green: 0.314, blue: 0.459) // #325075

    // Midday
    private static let middayGreenTop    = Color(red: 0.086, green: 0.153, blue: 0.125) // #162720
    private static let middayGreenBottom = Color(red: 0.059, green: 0.118, blue: 0.090) // #0F1E17
    private static let middayCard        = Color(red: 0.106, green: 0.176, blue: 0.141) // #1B2D24
    private static let middayRecessed    = Color(red: 0.063, green: 0.114, blue: 0.086) // #101D16
}

extension Color {
    static var wwCardBackground: Color { TimeOfDayTheme.current.card }
    static var wwRecessedBackground: Color { TimeOfDayTheme.current.recessed }
}
