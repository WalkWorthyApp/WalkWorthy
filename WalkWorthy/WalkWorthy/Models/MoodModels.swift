//
//  MoodModels.swift
//  WalkWorthy
//
//  Models for the mood tracking feature.
//

import Foundation
import SwiftUI

// MARK: - Check-in Types

enum CheckInType: String, Codable, CaseIterable, Identifiable {
    case morning
    case midday
    case evening

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .morning: return "Morning"
        case .midday: return "Midday"
        case .evening: return "Evening"
        }
    }

    var greeting: String {
        switch self {
        case .morning: return "Good morning! How are you feeling about today?"
        case .midday: return "How is your day going so far?"
        case .evening: return "How was your day?"
        }
    }

    var followUpQuestion: String {
        switch self {
        case .morning: return "How are you feeling about today?"
        case .midday: return "How much is on your plate right now?"
        case .evening: return "How are you feeling about tomorrow?"
        }
    }

    var followUpOptions: [String] {
        switch self {
        case .morning:
            return ["Dreading it", "A bit uneasy", "Okay about it", "Ready and excited"]
        case .midday:
            return ["Completely buried", "A lot on my plate", "Manageable", "Feeling on top of it"]
        case .evening:
            return ["Hopeful", "Nervous", "Uncertain", "Ready"]
        }
    }

    var iconName: String {
        switch self {
        case .morning: return "sunrise.fill"
        case .midday: return "sun.max.fill"
        case .evening: return "moon.stars.fill"
        }
    }

    var color: Color {
        switch self {
        case .morning: return .orange
        case .midday: return .yellow
        case .evening: return .indigo
        }
    }
}

// MARK: - Mood Level

enum MoodLevel: String, Codable, CaseIterable {
    case veryUnpleasant = "very_unpleasant"
    case unpleasant = "unpleasant"
    case neutral = "neutral"
    case pleasant = "pleasant"
    case veryPleasant = "very_pleasant"

    var displayName: String {
        switch self {
        case .veryUnpleasant: return "Very Unpleasant"
        case .unpleasant: return "Unpleasant"
        case .neutral: return "Neutral"
        case .pleasant: return "Pleasant"
        case .veryPleasant: return "Very Pleasant"
        }
    }

    /// Derive MoodLevel from a numeric score (1–10)
    static func from(score: Int) -> MoodLevel {
        switch score {
        case ...2: return .veryUnpleasant
        case 3...4: return .unpleasant
        case 5...6: return .neutral
        case 7...8: return .pleasant
        default: return .veryPleasant
        }
    }

    var sentiment: MoodSentiment {
        switch self {
        case .veryUnpleasant, .unpleasant: return .challenging
        case .neutral: return .neutral
        case .pleasant, .veryPleasant: return .positive
        }
    }
}

// MARK: - Mood Spectrum Data

struct MoodSpectrumData: Codable, Equatable {
    let moodScore: Int           // 1–10
    let moodLevel: String        // matches MoodLevel.rawValue, derived server-side
    let emotionTags: [String]    // selected emotion words
    let impactCategories: [String] // selected impact areas
    let followUpScore: Int       // 1–4
    let note: String?            // optional free text

    var moodLevelEnum: MoodLevel? {
        MoodLevel(rawValue: moodLevel)
    }
}

enum MoodSentiment: String, Codable {
    case positive
    case neutral
    case challenging

    var color: Color {
        switch self {
        case .positive: return Color(red: 0.4, green: 0.7, blue: 0.4)
        case .neutral: return Color(red: 0.95, green: 0.7, blue: 0.3)
        case .challenging: return Color(red: 0.85, green: 0.4, blue: 0.4)
        }
    }
}

// MARK: - API Models

struct MoodCheckInRequest: Codable {
    let checkInType: String
    let moodSpectrumData: MoodSpectrumData
}

struct MoodCheckInResponse: Codable, Equatable {
    let checkInId: String
    let aiResponse: AIEncouragementResponse
    let createdAt: String
    let expiresAt: String
    let isExisting: Bool?
}

struct AIEncouragementResponse: Codable, Equatable {
    let message: String
    let verseRef: String
    let verseText: String
    let translation: String
}

struct MoodCheckIn: Codable, Identifiable, Equatable {
    let id: String
    let checkInType: String
    let timestamp: String
    let date: String
    let moodSpectrumData: MoodSpectrumData?  // nil for old check-ins
    let aiResponse: AIEncouragementResponse
    let createdAt: String
    let expiresAt: String

    var checkInTypeEnum: CheckInType? {
        CheckInType(rawValue: checkInType)
    }

    var moodLevelEnum: MoodLevel? {
        moodSpectrumData?.moodLevelEnum
    }
}

/// Marked `nonisolated` because the project defaults actor isolation to
/// `@MainActor` (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`); without this,
/// the type's `Codable` conformance would be main-actor-isolated, which
/// breaks its use (as part of `DailyMoodSummary`) as the `T: Codable &
/// Sendable` payload for the deliberately off-main-actor
/// `SnapshotStore.readSync`/`write` (mirrors the same annotation on
/// `MoodStatusResponse`/`DailyReflection` below).
nonisolated struct CheckInSummary: Codable, Equatable {
    let checkInId: String
    let moodLevel: String?       // nil for old check-ins (used primaryMood)
    let respondedAt: String

    var moodLevelEnum: MoodLevel? {
        guard let moodLevel else { return nil }
        return MoodLevel(rawValue: moodLevel)
    }
}

/// Marked `nonisolated` because the project defaults actor isolation to
/// `@MainActor` (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`); without this,
/// the type's `Codable` conformance would be main-actor-isolated, which
/// breaks its use as the `T: Codable & Sendable` payload (via `[DailyMoodSummary]`)
/// for the deliberately off-main-actor `SnapshotStore.readSync`/`write`
/// (mirrors the same annotation on `MoodStatusResponse`/`DailyReflection` below).
nonisolated struct DailyMoodSummary: Codable, Identifiable, Equatable {
    let date: String
    let morning: CheckInSummary?
    let midday: CheckInSummary?
    let evening: CheckInSummary?
    let overallSentiment: String?
    let updatedAt: String?

    var id: String { date }

    var sentiment: MoodSentiment? {
        guard let overallSentiment else { return nil }
        return MoodSentiment(rawValue: overallSentiment)
    }

    var completedCount: Int {
        [morning, midday, evening].compactMap { $0 }.count
    }
}

struct PendingCheckIn: Codable {
    let checkInType: String
    let dueAt: String
    let isOverdue: Bool

    var checkInTypeEnum: CheckInType? {
        CheckInType(rawValue: checkInType)
    }
}

/// Marked `nonisolated` because the project defaults actor isolation to
/// `@MainActor` (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`); without this,
/// the type's `Codable` conformance would be main-actor-isolated, which
/// breaks its use as the `T: Codable & Sendable` payload for the
/// deliberately off-main-actor `SnapshotStore.readSync`/`write` (mirrors the
/// same annotation on `DailyReflection` below).
nonisolated struct MoodStatusResponse: Codable {
    let status: String // "pending" or "completed"
    let pendingCheckIn: PendingCheckIn?
    let checkIn: MoodCheckIn?
    let summary: DailyMoodSummary?
}

struct MoodHistoryResponse: Codable {
    let summaries: [DailyMoodSummary]
    let daysRequested: Int
}

/// Full-fidelity check-in log response — each entry contains
/// `moodSpectrumData` (tags, impacts, note) and the full `aiResponse`,
/// unlike `MoodHistoryResponse` which only carries per-day summaries.
/// Powers the Settings → Check-in Log deep-dive view.
struct MoodLogResponse: Codable {
    let checkIns: [MoodCheckIn]
    let daysRequested: Int
}

// MARK: - Daily Reflection

/// Marked `nonisolated` because the project defaults actor isolation to
/// `@MainActor` (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`); without this,
/// the type's `Codable` conformance would be main-actor-isolated, which
/// breaks its use as the `T: Codable & Sendable` payload for the
/// deliberately off-main-actor `SnapshotStore.readSync`/`write` (mirrors the
/// same annotation on `RemoteUserProfileResponse` in EncouragementModels.swift
/// and on `Snapshot`/`SnapshotKind` in SnapshotStore.swift).
nonisolated struct DailyReflection: Codable, Equatable {
    let reflection: String
    let generatedAt: String
    let date: String        // "yyyy-MM-dd"
}

// MARK: - Check-in Times

struct CheckInTimes: Codable, Equatable {
    var morning: String  // "07:30" HH:mm format
    var midday: String   // "12:00"
    var evening: String  // "20:00"

    static let defaultTimes = CheckInTimes(
        morning: "07:30",
        midday: "12:00",
        evening: "20:00"
    )

    func timeFor(_ type: CheckInType) -> String {
        switch type {
        case .morning: return morning
        case .midday: return midday
        case .evening: return evening
        }
    }

    func dateFor(_ type: CheckInType) -> Date? {
        let timeString = timeFor(type)
        let components = timeString.split(separator: ":").compactMap { Int($0) }
        guard components.count == 2 else {
            #if DEBUG
            print("[CheckInTimes] Failed to parse time string: \(timeString) for \(type.displayName)")
            #endif
            return nil
        }

        var dateComponents = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        dateComponents.hour = components[0]
        dateComponents.minute = components[1]

        guard let date = Calendar.current.date(from: dateComponents) else {
            #if DEBUG
            print("[CheckInTimes] Calendar.date failed to create date from components: hour=\(components[0]), minute=\(components[1])")
            #endif
            return nil
        }
        return date
    }
}
