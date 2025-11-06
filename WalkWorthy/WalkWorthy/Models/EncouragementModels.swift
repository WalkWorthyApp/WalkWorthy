//
//  EncouragementModels.swift
//  WalkWorthy
//
//  Shared models used by the live encouragement and Canvas APIs.
//

import Foundation

protocol EncouragementAPI {
    func fetchNext() async throws -> NextResponse
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
