//
//  EncouragementModels.swift
//  WalkWorthy
//
//  Shared models used by the live encouragement API.
//

import Foundation

protocol EncouragementAPI {
    func updateUserProfile(_ payload: RemoteUserProfileRequest) async throws

    // Mood tracking methods
    func submitMoodCheckIn(_ request: MoodCheckInRequest) async throws -> MoodCheckInResponse
    func fetchMoodStatus() async throws -> MoodStatusResponse
    func fetchMoodHistory(days: Int, startDate: String?, endDate: String?) async throws -> MoodHistoryResponse
    func fetchDailyReflection() async throws -> DailyReflection

}

struct RemoteUserProfileRequest: Codable {
    var ageRange: String?
    /// Optional first name used only for Home-view greeting personalization.
    /// NOT forwarded to AI agents on the backend.
    var firstName: String?
    var occupation: String?
    var major: String?
    var gender: String?
    var hobbies: [String]?
    var optInTailored: Bool?
    var translationPreference: String?
    var checkInTimes: CheckInTimes?
    var timezone: String?
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
    /// Optional first name. Empty/whitespace means not set. Used only for Home
    /// greeting personalization — never passed to AI agents.
    var firstName: String
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
