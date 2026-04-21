//
//  JournalModels.swift
//  WalkWorthy
//
//  Local SwiftData model for journal entries.
//

import Foundation
import SwiftData

@Model
class JournalEntry {
    @Attribute(.unique) var id: String
    var text: String
    var date: String             // YYYY-MM-DD
    var linkedCheckInId: String? // optional link to a mood check-in
    var createdAt: Date
    var updatedAt: Date

    // Pinning (Apple Notes-style "Pinned" section).
    var isPinned: Bool = false

    // Denormalized mood snapshot — populated at creation time for entries
    // created alongside a mood submission. Nil for standalone journal entries.
    var moodLevelRaw: String? = nil  // matches MoodLevel.rawValue
    var moodScore: Int? = nil        // 1–10
    var emotionTags: [String] = []   // selected emotion words

    // Per-user scoping. Required to prevent cross-user PII leaks on shared devices:
    // all fetches/queries filter by the current authenticated user's Firebase UID
    // (`appState.authenticatedUserSub`). Default "" covers entries written before
    // this column existed; such legacy entries never match a real user and are
    // cleaned up on sign-out via `AppState.clearJournalState()`.
    //
    // TODO: If ever migrating to encrypted backend sync, back-fill this column
    // from the sync payload rather than from local state.
    var userSub: String = ""

    init(
        id: String,
        text: String,
        date: String,
        linkedCheckInId: String?,
        createdAt: Date,
        updatedAt: Date,
        isPinned: Bool = false,
        moodLevelRaw: String? = nil,
        moodScore: Int? = nil,
        emotionTags: [String] = [],
        userSub: String = ""
    ) {
        self.id = id
        self.text = text
        self.date = date
        self.linkedCheckInId = linkedCheckInId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isPinned = isPinned
        self.moodLevelRaw = moodLevelRaw
        self.moodScore = moodScore
        self.emotionTags = emotionTags
        self.userSub = userSub
    }
}

extension JournalEntry {
    private static let inputFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    var displayDate: String {
        guard let date = JournalEntry.inputFormatter.date(from: self.date) else { return self.date }
        return JournalEntry.displayFormatter.string(from: date)
    }
}
