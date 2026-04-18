//
//  JournalListView.swift
//  WalkWorthy
//
//  Apple Notes-style Journal list: pull-to-reveal search,
//  Pinned section, date-grouped sections, floating compose button.
//

import SwiftUI
import SwiftData

struct JournalListView: View {
    @EnvironmentObject private var appState: AppState
    @Query(sort: \JournalEntry.createdAt, order: .reverse) private var allEntries: [JournalEntry]
    @State private var searchText: String = ""
    @State private var isComposingNew: Bool = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            DynamicBackgroundView()

            List {
                if searchText.isEmpty {
                    pinnedSection
                    ForEach(dateSections) { section in
                        Section(section.title) {
                            ForEach(section.entries, id: \.id) { entry in
                                row(for: entry)
                            }
                        }
                    }
                } else {
                    Section("Results") {
                        let results = filtered(allEntries, query: searchText)
                        if results.isEmpty {
                            Text("No Results").foregroundStyle(.secondary)
                        } else {
                            ForEach(results, id: \.id) { entry in
                                row(for: entry)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .navigationTitle("Journal")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $searchText,
                        placement: .navigationBarDrawer(displayMode: .automatic))
            .overlay { if allEntries.isEmpty { emptyState } }
            .navigationDestination(isPresented: $isComposingNew) {
                JournalEditorView(mode: .new)
            }

            Button {
                isComposingNew = true
            } label: {
                Image(systemName: JournalIcons.compose)
                    .font(.system(size: scaled(22), weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(scaled(18))
                    .background(Circle().fill(Color.accentColor))
                    .shadow(radius: scaled(4), y: scaled(2))
            }
            .padding(.trailing, scaled(20))
            .padding(.bottom, scaled(24))
            .accessibilityLabel("New note")
        }
        .onAppear { appState.loadJournalEntries(date: nil) }
    }

    // MARK: - Sections

    @ViewBuilder private var pinnedSection: some View {
        let pinned = allEntries.filter(\.isPinned)
        if !pinned.isEmpty {
            Section("Pinned") {
                ForEach(pinned, id: \.id) { entry in
                    row(for: entry)
                }
            }
        }
    }

    private var dateSections: [JournalSection] {
        DateGroupedJournalSections.make(entries: allEntries, now: Date(), calendar: .current)
    }

    // MARK: - Row + actions

    @ViewBuilder private func row(for entry: JournalEntry) -> some View {
        NavigationLink(destination: JournalEditorView(mode: .existing(entry))) {
            JournalRow(entry: entry, now: Date())
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                appState.togglePin(entry)
            } label: {
                Label(entry.isPinned ? "Unpin" : "Pin",
                      systemImage: entry.isPinned ? JournalIcons.pinSlashed : JournalIcons.pinFilled)
            }
            .tint(.orange)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                try? appState.deleteJournalEntry(id: entry.id)
            } label: {
                Label("Delete", systemImage: JournalIcons.trash)
            }
        }
    }

    // MARK: - Search

    private func filtered(_ entries: [JournalEntry], query: String) -> [JournalEntry] {
        let q = query.lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { entry in
            entry.text.lowercased().contains(q)
                || entry.emotionTags.contains { $0.lowercased().contains(q) }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: JournalIcons.emptyState)
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("No journal entries yet")
                .font(.system(size: 17, weight: .semibold))
            Text("Tap ✎ to start")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        }
    }
}
