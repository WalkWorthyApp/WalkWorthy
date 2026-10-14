//
//  EncouragementModels.swift
//  WalkWorthy
//
//  Shared models used by the live encouragement API.
//

import Foundation

struct PrivacyConsent: Codable {
    /// The consent-screen wording in force. Must match the backend
    /// `NOTICE_VERSION`; bump both whenever AIConsentView's wording changes.
    static let currentNoticeVersion = "2026-10-14"

    var aiSharing: Bool
    var noticeVersion: String
    var ageGroup: String
    var revision: Int
    var updatedAt: String?
}

struct PrivacyConsentUpdate: Encodable {
    var aiSharing: Bool
    var noticeVersion: String? = PrivacyConsent.currentNoticeVersion
    var ageGroup: String?
    var expectedRevision: Int?
    var withdrawalId: String? = nil
}

/// A suggestion-box entry. `id` is generated once per draft and reused on
/// resend so a retry after a dropped response is stored only once.
struct SuggestionRequest: Encodable {
    enum Category: String, Encodable, CaseIterable, Identifiable {
        case idea
        case confusing
        case other

        var id: Self { self }

        var title: String {
            switch self {
            case .idea: return "Idea"
            case .confusing: return "Confusing"
            case .other: return "Other"
            }
        }
    }

    /// Matches the backend limit, which counts Unicode code points.
    static let maxLength = 1000

    var id: String
    var category: Category
    var text: String
    var appVersion: String?
}

protocol EncouragementAPI {
    func fetchPrivacyConsent() async throws -> PrivacyConsent
    func updatePrivacyConsent(_ update: PrivacyConsentUpdate) async throws -> PrivacyConsent
    /// Sends a partial profile update (backend PATCH is a merge) and returns
    /// the fully merged profile document from the response so callers can
    /// persist the authoritative post-merge state (e.g. snapshot cache).
    /// Returns nil when the response body can't be decoded — the PATCH itself
    /// still succeeded in that case.
    @discardableResult
    func updateUserProfile(_ payload: RemoteUserProfileRequest, context: AuthenticatedRequestContext) async throws -> RemoteUserProfileResponse?
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
    /// On success the backend returns `{ "deleted": true }`; AppState signs out.
    func deleteAccount(context: AuthenticatedRequestContext) async throws

    /// Stores a suggestion-box entry for the developer to read.
    func submitSuggestion(_ request: SuggestionRequest) async throws

}

struct RemoteUserProfileRequest: Codable {
    var ageRange: String?
    /// Optional first name used only for Home-view greeting personalization.
    /// NOT forwarded to AI agents on the backend.
    var firstName: String?
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
    var timezone: String?
    var checkInTimes: CheckInTimes?
}

struct OnboardingProfile {
    /// Optional first name. Empty/whitespace means not set. Used only for Home
    /// greeting personalization — never passed to AI agents.
    var firstName: String
    var age: Int?
}
