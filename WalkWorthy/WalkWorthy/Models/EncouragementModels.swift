//
//  EncouragementModels.swift
//  WalkWorthy
//
//  Shared models used by the live encouragement API.
//

import Foundation

protocol EncouragementAPI {
    // Encouragement methods
    func fetchNext() async throws -> NextResponse
    func updateUserProfile(_ payload: RemoteUserProfileRequest) async throws

    // Mood tracking methods
    func submitMoodCheckIn(_ request: MoodCheckInRequest) async throws -> MoodCheckInResponse
    func fetchMoodStatus() async throws -> MoodStatusResponse
    func fetchMoodHistory(days: Int) async throws -> MoodHistoryResponse
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

struct RemoteUserProfileRequest: Codable {
    var ageRange: String?
    var occupation: String?
    var major: String?
    var gender: String?
    var hobbies: [String]?
    var optInTailored: Bool?
    var translationPreference: String?
    var checkInTimes: CheckInTimes?
    var timezone: String?
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
    case nkjv = "NKJV"
    case nasb = "NASB"
    case csb = "CSB"
    case nlt = "NLT"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .esv: return "English Standard Version"
        case .kjv: return "King James Version"
        case .niv: return "New International Version"
        case .nkjv: return "New King James Version"
        case .nasb: return "New American Standard Bible"
        case .csb: return "Christian Standard Bible"
        case .nlt: return "New Living Translation"
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
    var occupation: String  // For professionals
    var major: String       // For students
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
