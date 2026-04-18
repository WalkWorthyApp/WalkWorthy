//
//  JournalIcons.swift
//  WalkWorthy
//
//  Central SF Symbol names used across the Journal feature.
//  Keeps icon choices consistent and grep-able.
//

import Foundation

enum JournalIcons {
    static let compose = "square.and.pencil"
    static let pinFilled = "pin.fill"
    static let pinSlashed = "pin.slash"
    static let trash = "trash"
    static let moodLinkedIndicator = "heart.text.square.fill"
    static let share = "square.and.arrow.up"
    static let overflowMenu = "ellipsis.circle"
    static let chevronDown = "chevron.down"
    static let chevronUp = "chevron.up"
    static let emptyState = "square.and.pencil"

    // Mood sentiment glyphs (grouped from MoodLevel enum's 5 raw values).
    static func moodGlyph(for moodLevelRaw: String?) -> String {
        switch moodLevelRaw {
        case "very_pleasant", "pleasant":
            return "sun.max.fill"
        case "neutral":
            return "cloud.fill"
        case "unpleasant", "very_unpleasant":
            return "cloud.rain.fill"
        default:
            return "circle"
        }
    }
}
