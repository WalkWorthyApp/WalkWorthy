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
        case .morning: return "Do you have a lot on your plate today?"
        case .midday: return "What would help you most right now?"
        case .evening: return "How are you feeling about tomorrow?"
        }
    }

    var moodOptions: [MoodOption] {
        switch self {
        case .morning:
            return [.hopeful, .anxious, .tired, .confident, .nervous, .uncertain]
        case .midday:
            return [.betterThanExpected, .asExpected, .harderThanExpected, .stressful]
        case .evening:
            return [.greatDay, .goodDay, .challengingDay, .difficultDay]
        }
    }

    var followUpOptions: [String] {
        switch self {
        case .morning:
            return ["Yes", "No", "Somewhat"]
        case .midday:
            return ["Encouragement", "Peace", "Strength", "Wisdom"]
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

// MARK: - Mood Options

enum MoodOption: String, Codable, CaseIterable, Identifiable {
    // Morning moods
    case hopeful
    case anxious
    case tired
    case confident
    case nervous
    case uncertain

    // Midday moods
    case betterThanExpected = "better than expected"
    case asExpected = "as expected"
    case harderThanExpected = "harder than expected"
    case stressful

    // Evening moods
    case greatDay = "great day"
    case goodDay = "good day"
    case challengingDay = "challenging day"
    case difficultDay = "difficult day"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hopeful: return "Hopeful"
        case .anxious: return "Anxious"
        case .tired: return "Tired"
        case .confident: return "Confident"
        case .nervous: return "Nervous"
        case .uncertain: return "Uncertain"
        case .betterThanExpected: return "Better than expected"
        case .asExpected: return "As expected"
        case .harderThanExpected: return "Harder than expected"
        case .stressful: return "Stressful"
        case .greatDay: return "Great day"
        case .goodDay: return "Good day"
        case .challengingDay: return "Challenging day"
        case .difficultDay: return "Difficult day"
        }
    }

    var emoji: String {
        switch self {
        case .hopeful: return "🌅"
        case .anxious: return "😰"
        case .tired: return "😴"
        case .confident: return "💪"
        case .nervous: return "😬"
        case .uncertain: return "🤔"
        case .betterThanExpected: return "😊"
        case .asExpected: return "😌"
        case .harderThanExpected: return "😓"
        case .stressful: return "😤"
        case .greatDay: return "🎉"
        case .goodDay: return "😊"
        case .challengingDay: return "😔"
        case .difficultDay: return "💔"
        }
    }

    var color: Color {
        switch self {
        case .hopeful, .confident, .betterThanExpected, .greatDay, .goodDay:
            return Color(red: 0.4, green: 0.7, blue: 0.4) // Soft green
        case .tired, .asExpected, .uncertain:
            return Color(red: 0.95, green: 0.7, blue: 0.3) // Warm orange
        case .anxious, .nervous, .harderThanExpected, .stressful, .challengingDay, .difficultDay:
            return Color(red: 0.85, green: 0.4, blue: 0.4) // Soft coral/red
        }
    }

    var sentiment: MoodSentiment {
        switch self {
        case .hopeful, .confident, .betterThanExpected, .greatDay, .goodDay:
            return .positive
        case .tired, .asExpected, .uncertain:
            return .neutral
        case .anxious, .nervous, .harderThanExpected, .stressful, .challengingDay, .difficultDay:
            return .challenging
        }
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
    let primaryMood: String
    let followUpResponse: String
}

struct MoodCheckInResponse: Codable {
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

struct MoodResponses: Codable, Equatable {
    let primaryMood: String
    let followUpResponse: String
}

struct MoodCheckIn: Codable, Identifiable, Equatable {
    let id: String
    let checkInType: String
    let timestamp: String
    let date: String
    let responses: MoodResponses
    let aiResponse: AIEncouragementResponse
    let createdAt: String
    let expiresAt: String

    private static let iso8601Formatter = ISO8601DateFormatter()

    var checkInTypeEnum: CheckInType? {
        CheckInType(rawValue: checkInType)
    }

    var moodOption: MoodOption? {
        MoodOption(rawValue: responses.primaryMood)
    }

    var timestampDate: Date? {
        Self.iso8601Formatter.date(from: timestamp)
    }
}

struct CheckInSummary: Codable, Equatable {
    let checkInId: String
    let primaryMood: String
    let respondedAt: String

    var moodOption: MoodOption? {
        MoodOption(rawValue: primaryMood)
    }
}

struct DailyMoodSummary: Codable, Identifiable, Equatable {
    let date: String
    let morning: CheckInSummary?
    let midday: CheckInSummary?
    let evening: CheckInSummary?
    let overallSentiment: String?
    let updatedAt: String?

    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    var id: String { date }

    var sentiment: MoodSentiment? {
        guard let overallSentiment else { return nil }
        return MoodSentiment(rawValue: overallSentiment)
    }

    var completedCount: Int {
        [morning, midday, evening].compactMap { $0 }.count
    }

    var dateObject: Date? {
        Self.dateFormatter.date(from: date)
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

struct MoodStatusResponse: Codable {
    let status: String // "pending" or "completed"
    let pendingCheckIn: PendingCheckIn?
    let checkIn: MoodCheckIn?
    let summary: DailyMoodSummary?
}

struct MoodHistoryResponse: Codable {
    let summaries: [DailyMoodSummary]
    let daysRequested: Int
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
            print("[CheckInTimes] Failed to parse time string: \(timeString) for \(type.displayName)")
            return nil
        }

        var dateComponents = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        dateComponents.hour = components[0]
        dateComponents.minute = components[1]

        guard let date = Calendar.current.date(from: dateComponents) else {
            print("[CheckInTimes] Calendar.date failed to create date from components: hour=\(components[0]), minute=\(components[1])")
            return nil
        }
        return date
    }
}

