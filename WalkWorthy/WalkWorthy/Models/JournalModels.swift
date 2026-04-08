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

    init(id: String, text: String, date: String, linkedCheckInId: String?, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.text = text
        self.date = date
        self.linkedCheckInId = linkedCheckInId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
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
