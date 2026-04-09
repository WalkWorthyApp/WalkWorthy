//
//  JournalEntryView.swift
//  WalkWorthy
//
//  Full-screen journal entry editor. Handles both new entries and
//  editing existing ones. Auto-saves on dismiss.
//

import SwiftUI

struct JournalEntryView: View {
    let entry: JournalEntry?

    @EnvironmentObject private var appState: AppState
    @State private var text: String
    @State private var isSaving = false

    init(entry: JournalEntry?) {
        self.entry = entry
        _text = State(initialValue: entry?.text ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Date header
            Text(displayDate)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.horizontal, scaled(16))
                .padding(.top, scaled(16))
                .padding(.bottom, scaled(8))

            // Linked check-in badge
            if entry?.linkedCheckInId != nil {
                Label("Linked to check-in", systemImage: "link")
                    .font(.caption)
                    .foregroundColor(.accentColor)
                    .padding(.horizontal, scaled(16))
                    .padding(.bottom, scaled(8))
            }

            Divider()

            // Main text editor
            TextEditor(text: $text)
                .font(.body)
                .padding(.horizontal, scaled(12))
                .padding(.vertical, scaled(8))
        }
        .navigationTitle(entry == nil ? "New Entry" : "")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            save()
        }
    }

    // MARK: - Helpers

    private var displayDate: String {
        if let entry = entry {
            return entry.displayDate
        }
        return todayFormatted
    }

    private static let todayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private var todayFormatted: String {
        JournalEntryView.todayFormatter.string(from: Date())
    }

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let existing = entry {
            // Only update if text changed
            guard trimmed != existing.text.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            try? appState.updateJournalEntry(id: existing.id, text: trimmed)
        } else {
            // Only create if non-empty
            guard !trimmed.isEmpty else { return }
            _ = try? appState.createJournalEntry(text: trimmed, linkedCheckInId: nil)
        }
    }
}

#Preview("New Entry") {
    NavigationStack {
        JournalEntryView(entry: nil)
    }
}
