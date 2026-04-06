//
//  JournalModels.swift
//  WalkWorthy
//
//  Models for the journaling feature.
//

import Foundation

// MARK: - Journal Entry

struct JournalEntry: Codable, Identifiable, Equatable {
    let id: String
    var text: String
    let date: String             // YYYY-MM-DD
    let linkedCheckInId: String? // optional link to a mood check-in
    let createdAt: String        // ISO 8601
    var updatedAt: String        // ISO 8601
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

// MARK: - Journal API Models

struct CreateJournalEntryRequest: Codable {
    let text: String
    let linkedCheckInId: String?
}

struct UpdateJournalEntryRequest: Codable {
    let text: String
}

struct JournalListResponse: Codable {
    let entries: [JournalEntry]
}
