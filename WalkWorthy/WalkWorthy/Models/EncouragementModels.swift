//
//  EncouragementModels.swift
//  WalkWorthy
//
//  Shared models and sample data for the UI-only sprint.
//

import Foundation
import SwiftUI

protocol EncouragementAPI {
    func fetchNext() async throws -> NextResponse
    func fetchTodayCanvas() async throws -> TodayCanvas
    func triggerScanNow() async throws -> ScanNowResponse
    func updateUserProfile(_ payload: RemoteUserProfileRequest) async throws
    func fetchCalendarAgenda() async throws -> CalendarAgendaResponse
    func fetchCalendarLinkStatus() async throws -> CalendarLinkStatus
    func updateCalendarLink(_ payload: CalendarLinkUpdateRequest) async throws -> CalendarLinkStatus
    func deleteCalendarLink() async throws
}

struct NextResponse: Codable {
    let shouldNotify: Bool
    let payload: EncouragementPayload?
    let metadata: ScanLogSummary?
}

struct EncouragementPayload: Codable, Hashable {
    let id: String
    let ref: String
    let text: String
    let encouragement: String
    let translation: String?
    let expiresAt: String?
}

struct ScanLogSummary: Codable, Equatable {
    let encouragementId: String?
    let status: ScanStatus
    let plannerCount: Int?
    let stressfulCount: Int?
    let candidateCount: Int?
    let tags: [String]?
    let errorMessage: String?
}

enum ScanStatus: String, Codable {
    case success = "SUCCESS"
    case fallback = "FALLBACK"
}

struct ScanNowResponse: Codable {
    let message: String
    let encouragementId: String?
    let status: ScanStatus
    let log: ScanLogSummary?
}

struct CalendarAgendaResponse: Codable {
    let fetchedAt: Date?
    let items: [CalendarAgendaItem]
}

struct CalendarAgendaItem: Codable, Identifiable {
    let id: String
    let title: String
    let kind: CalendarAgendaKind
    let startAt: Date?
    let endAt: Date?
    let dueAt: Date?
    let course: String?
    let location: String?
    let url: URL?
    let timeZoneId: String?
}

enum CalendarAgendaKind: String, Codable, CaseIterable, Identifiable {
    case assignment
    case exam
    case event

    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .assignment: return "doc.text"
        case .exam: return "checkmark.seal"
        case .event: return "calendar"
        }
    }

    var displayName: String {
        switch self {
        case .assignment: return "Assignment"
        case .exam: return "Exam"
        case .event: return "Event"
        }
    }
}

struct CalendarLinkStatus: Codable, Equatable {
    enum LinkState: String, Codable {
        case pending = "PENDING"
        case active = "ACTIVE"
        case error = "ERROR"
        case migrationRequired = "MIGRATION_REQUIRED"
    }

    var calendarUrl: String?
    var status: LinkState
    var lastValidatedAt: Date?
    var lastError: String?
    var updatedAt: Date?
    var lastSyncedAt: Date?
    var lastSyncStatus: String?
    var lastSyncError: String?
}

struct CalendarLinkUpdateRequest: Codable {
    var calendarUrl: String
}

struct RemoteUserProfileRequest: Codable {
    var ageRange: String?
    var major: String?
    var gender: String?
    var hobbies: [String]?
    var optInTailored: Bool?
    var translationPreference: String?
}

struct TodayCanvas: Codable, Equatable {
    let assignmentsToday: [Assignment]
    let examsToday: [Exam]
}

struct Assignment: Codable, Equatable, Identifiable {
    let id: UUID
    let title: String
    let dueAt: String
    let points: Int?

    init(id: UUID = UUID(), title: String, due_at: String, points: Int?) {
        self.id = id
        self.title = title
        self.dueAt = due_at
        self.points = points
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case due_at
        case points
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let title = try container.decode(String.self, forKey: .title)
        let dueAt = try container.decode(String.self, forKey: .due_at)
        let points = try container.decodeIfPresent(Int.self, forKey: .points)
        self.init(title: title, due_at: dueAt, points: points)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(dueAt, forKey: .due_at)
        try container.encodeIfPresent(points, forKey: .points)
    }
}

struct Exam: Codable, Equatable, Identifiable {
    let id: UUID
    let title: String
    let when: String

    init(id: UUID = UUID(), title: String, when: String) {
        self.id = id
        self.title = title
        self.when = when
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case when
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let title = try container.decode(String.self, forKey: .title)
        let when = try container.decode(String.self, forKey: .when)
        self.init(title: title, when: when)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(title, forKey: .title)
        try container.encode(when, forKey: .when)
    }
}

struct Verse: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let reference: String
    let text: String
    let encouragement: String
    let translation: Translation

    init(id: String, reference: String, text: String, encouragement: String, translation: Translation) {
        self.id = id
        self.reference = reference
        self.text = text
        self.encouragement = encouragement
        self.translation = translation
    }

    init(payload: EncouragementPayload) {
        self.init(
            id: payload.id,
            reference: payload.ref,
            text: payload.text,
            encouragement: payload.encouragement,
            translation: Translation(rawValue: payload.translation ?? "") ?? .esv
        )
    }

    static let placeholder = Verse(
        id: "placeholder",
        reference: "John 16:33",
        text: "In the world you will have tribulation. But take heart; I have overcome the world.",
        encouragement: "Keep going — Jesus already won the battle for you.",
        translation: .esv
    )
}

enum Translation: String, CaseIterable, Identifiable, Codable {
    case esv = "ESV"
    case kjv = "KJV"
    case niv = "NIV"
    case csb = "CSB"
    case msg = "MSG"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .esv: return "English Standard Version"
        case .kjv: return "King James Version"
        case .niv: return "New International Version"
        case .csb: return "Christian Standard Bible"
        case .msg: return "The Message"
        }
    }
}

struct EncouragementCard: Identifiable, Equatable {
    let id = UUID()
    let tag: String
    let title: String
    let message: String
}

enum Gender: String, CaseIterable, Identifiable {
    case female = "Female"
    case male = "Male"

    var id: String { rawValue }
}

struct OnboardingProfile {
    var age: Int?
    var major: String
    var gender: Gender
    var hobbies: Set<String>
    var optIn: Bool
}

enum Hobby: String, CaseIterable {
    case worship
    case serving
    case music
    case athletics
    case art
    case reading
    case mentoring
    case outdoors

    var label: String {
        switch self {
        case .worship: return "Worship"
        case .serving: return "Serving"
        case .music: return "Music"
        case .athletics: return "Athletics"
        case .art: return "Art"
        case .reading: return "Reading"
        case .mentoring: return "Mentoring"
        case .outdoors: return "Outdoors"
        }
    }
}

enum MockData {
    static let verses: [Verse] = [
        Verse(
            id: "verse-001",
            reference: "Isaiah 40:31",
            text: "But they who wait for the Lord shall renew their strength; they shall mount up with wings like eagles; they shall run and not be weary; they shall walk and not faint.",
            encouragement: "Strength is coming. Breathe, wait, and watch God renew you.",
            translation: .esv
        ),
        Verse(
            id: "verse-002",
            reference: "Philippians 4:6-7",
            text: "Do not be anxious about anything, but in everything by prayer and supplication with thanksgiving let your requests be made known to God.",
            encouragement: "Trade your worry for worship. God guards hearts that are honest with Him.",
            translation: .niv
        ),
        Verse(
            id: "verse-003",
            reference: "Joshua 1:9",
            text: "Have I not commanded you? Be strong and courageous. Do not be frightened, and do not be dismayed, for the Lord your God is with you wherever you go.",
            encouragement: "Wherever campus takes you today, you never walk alone.",
            translation: .kjv
        )
    ]

    static let encouragementCards: [EncouragementCard] = [
        EncouragementCard(tag: "Courage", title: "Step into boldness", message: "You were made for this moment. Take the step with confidence."),
        EncouragementCard(tag: "Rest", title: "Breathe deeply", message: "Pause and receive God’s rest. You don’t have to carry it alone."),
        EncouragementCard(tag: "Wisdom", title: "Ask for insight", message: "Invite the Spirit into the decision. Clarity often follows surrender."),
        EncouragementCard(tag: "Joy", title: "Look for the good", message: "Gratitude is rebellion against hurry. Celebrate a small win today."),
        EncouragementCard(tag: "Hope", title: "Light is breaking", message: "Even in long nights, God’s promises are still sunrise sure.")
    ]
}
