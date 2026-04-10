//
//  JournalTabView.swift
//  WalkWorthy
//
//  Standalone Journal tab: list of journal entries sorted newest first.
//  Tap to edit; swipe to delete; + button creates a new entry.
//

import SwiftUI

struct JournalTabView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isShowingNewEntry = false
    @State private var errorMessage: String?
    @State private var selectedTab: JournalViewMode = .journal

    private enum JournalViewMode: String, CaseIterable {
        case journal = "Journal"
        case insights = "Insights"
    }

    var body: some View {
        VStack(spacing: 0) {
            // Segmented picker
            Picker("View", selection: $selectedTab) {
                ForEach(JournalViewMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, scaled(16))
            .padding(.vertical, scaled(8))

            // Content
            switch selectedTab {
            case .journal:
                journalListView
            case .insights:
                InsightsGraphView()
            }
        }
        .navigationTitle("Journal")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(selectedTab.rawValue)
                    .font(.newsreaderSemiBoldItalic(fixedSize: scaled(20)))
            }
            if selectedTab == .journal {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isShowingNewEntry = true
                    } label: {
                        Image(systemName: "square.and.pencil")
                    }
                }
            }
        }
        .sheet(isPresented: $isShowingNewEntry) {
            NavigationStack {
                JournalEntryView(entry: nil)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                isShowingNewEntry = false
                            }
                        }
                    }
            }
        }
    }

    // MARK: - Journal List

    private var journalListView: some View {
        List {
            ForEach(appState.journalEntries) { entry in
                NavigationLink(destination: JournalEntryView(entry: entry)) {
                    JournalRowView(entry: entry)
                }
            }
            .onDelete(perform: deleteEntries)
        }
        .listStyle(.insetGrouped)
        .onAppear {
            appState.loadJournalEntries(date: nil)
        }
        .overlay {
            if appState.journalEntries.isEmpty {
                emptyState
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: scaled(16)) {
            Image(systemName: "book.closed")
                .font(.system(size: scaled(48)))
                .foregroundColor(.secondary)

            Text("No Journal Entries")
                .font(.newsreaderSemiBoldItalic(fixedSize: scaled(20)))

            Text("Tap the pencil icon to jot down a thought or Bible study note.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, scaled(40))
        }
    }

    // MARK: - Delete

    private func deleteEntries(at offsets: IndexSet) {
        let entriesToDelete = offsets.map { appState.journalEntries[$0] }
        for entry in entriesToDelete {
            try? appState.deleteJournalEntry(id: entry.id)
        }
    }
}

// MARK: - Row

private struct JournalRowView: View {
    let entry: JournalEntry

    var body: some View {
        VStack(alignment: .leading, spacing: scaled(4)) {
            Text(entry.displayDate)
                .font(.caption)
                .foregroundColor(.secondary)

            Text(previewText)
                .font(.body)
                .lineLimit(2)
                .foregroundColor(.primary)
        }
        .padding(.vertical, scaled(4))
    }

    private var previewText: String {
        let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Empty note"
        }
        return trimmed.count > 80 ? String(trimmed.prefix(80)) + "…" : trimmed
    }
}

#Preview {
    NavigationStack {
        JournalTabView()
    }
}
