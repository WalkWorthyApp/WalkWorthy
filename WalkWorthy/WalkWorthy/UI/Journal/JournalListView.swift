//
//  JournalListView.swift
//  WalkWorthy
//
//  Apple Notes-style Journal list: pull-to-reveal search,
//  Pinned section, date-grouped sections, floating compose button.
//

import SwiftUI
import SwiftData
import UIKit

struct JournalListView: View {
    @EnvironmentObject private var appState: AppState
    @Query(sort: \JournalEntry.createdAt, order: .reverse) private var allEntries: [JournalEntry]
    @State private var searchText: String = ""
    @State private var isComposingNew: Bool = false
    @State private var entryPendingDelete: JournalEntry?

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
            .background(
                NavigationBarTitleFontConfigurator(
                    largeTitleFontName: "Newsreader-SemiBoldItalic",
                    largeTitleSize: 34,
                    inlineTitleFontName: "Newsreader-SemiBoldItalic",
                    inlineTitleSize: 17
                )
            )
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
        .confirmationDialog(
            "Delete this note?",
            isPresented: Binding(
                get: { entryPendingDelete != nil },
                set: { if !$0 { entryPendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let entry = entryPendingDelete {
                    try? appState.deleteJournalEntry(id: entry.id)
                }
                entryPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                entryPendingDelete = nil
            }
        }
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
        .listRowBackground(Color.wwCardBackground)
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
                entryPendingDelete = entry
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

/// Applies a custom font to the enclosing UINavigationController's
/// nav bar title attributes. Scoped to the current navigation stack,
/// so sibling tabs retain the system font.
private struct NavigationBarTitleFontConfigurator: UIViewControllerRepresentable {
    let largeTitleFontName: String
    let largeTitleSize: CGFloat
    let inlineTitleFontName: String
    let inlineTitleSize: CGFloat

    func makeUIViewController(context: Context) -> UIViewController {
        UIViewController()
    }

    func updateUIViewController(_ vc: UIViewController, context: Context) {
        DispatchQueue.main.async {
            guard let navBar = vc.navigationController?.navigationBar else { return }
            apply(to: navBar)
        }
    }

    private func apply(to navBar: UINavigationBar) {
        let appearance = UINavigationBarAppearance(barAppearance: navBar.standardAppearance)

        if let font = UIFont(name: largeTitleFontName, size: largeTitleSize) {
            var attrs = appearance.largeTitleTextAttributes
            attrs[.font] = font
            appearance.largeTitleTextAttributes = attrs
        }
        if let font = UIFont(name: inlineTitleFontName, size: inlineTitleSize) {
            var attrs = appearance.titleTextAttributes
            attrs[.font] = font
            appearance.titleTextAttributes = attrs
        }

        navBar.standardAppearance = appearance
        navBar.scrollEdgeAppearance = appearance
        navBar.compactAppearance = appearance
    }
}
