//
//  EncouragementModels.swift
//  WalkWorthy
//
//  Shared models used by the live encouragement API.
//

import Foundation

protocol EncouragementAPI {
    /// Sends a partial profile update (backend PATCH is a merge) and returns
    /// the fully merged profile document from the response so callers can
    /// persist the authoritative post-merge state (e.g. snapshot cache).
    /// Returns nil when the response body can't be decoded — the PATCH itself
    /// still succeeded in that case.
    @discardableResult
    func updateUserProfile(_ payload: RemoteUserProfileRequest) async throws -> RemoteUserProfileResponse?
    /// Fetch the authenticated user's profile from the backend. Returns nil
    /// when the backend has no profile on file yet (pre-onboarding).
    func fetchUserProfile() async throws -> RemoteUserProfileResponse?

    // Mood tracking methods
    func submitMoodCheckIn(_ request: MoodCheckInRequest) async throws -> MoodCheckInResponse
    func fetchMoodStatus() async throws -> MoodStatusResponse
    func fetchMoodHistory(days: Int, startDate: String?, endDate: String?) async throws -> MoodHistoryResponse
    func fetchMoodLogFullHistory(days: Int, endDate: String?) async throws -> MoodLogResponse
    func fetchDailyReflection() async throws -> DailyReflection

    /// Permanently deletes the authenticated user's Firestore data AND their
    /// Firebase Auth user. Required for App Store Guideline 5.1.1(v).
    /// On success the backend returns `{ "deleted": true }`; the Firebase Auth
    /// state listener then flips the client to signed-out.
    func deleteAccount() async throws

}

struct RemoteUserProfileRequest: Codable {
    var ageRange: String?
    /// Optional first name used only for Home-view greeting personalization.
    /// NOT forwarded to AI agents on the backend.
    var firstName: String?
    var occupation: String?
    var major: String?
    var hobbies: [String]?
    var optInTailored: Bool?
    var translationPreference: String?
    var checkInTimes: CheckInTimes?
    var timezone: String?
}

/// Mirror of the backend `UserProfile` document. All fields are optional
/// because the user may not have completed onboarding yet or may not have
/// populated every field. Decoded from `GET /userProfile`.
///
/// Marked `nonisolated` because the project defaults actor isolation to
/// `@MainActor` (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`); without this,
/// the type's `Codable` conformance would be main-actor-isolated, which
/// breaks its use as the `T: Codable & Sendable` payload for the
/// deliberately off-main-actor `SnapshotStore.readSync`/`write` (mirrors the
/// same annotation on `Snapshot`/`SnapshotKind` in SnapshotStore.swift).
nonisolated struct RemoteUserProfileResponse: Codable {
    var ageRange: String?
    var firstName: String?
    var occupation: String?
    var major: String?
    var hobbies: [String]?
    var optInTailored: Bool?
    var translationPreference: String?
    var timezone: String?
    var checkInTimes: CheckInTimes?
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

struct OnboardingProfile {
    /// Optional first name. Empty/whitespace means not set. Used only for Home
    /// greeting personalization — never passed to AI agents.
    var firstName: String
    var age: Int?
    var occupation: String  // For professionals
    var major: String       // For students
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
