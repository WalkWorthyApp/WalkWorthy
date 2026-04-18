//
//  JournalEditorView.swift
//  WalkWorthy
//
//  Full-screen push-navigated editor. Two visual input rows
//  (title + body) projected onto the single `text` field via
//  JournalTextSlicing. Save-on-back with empty-entry discard.
//

import SwiftUI
import SwiftData

struct JournalEditorView: View {
    enum Mode { case new, existing(JournalEntry) }
    let mode: Mode

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var text: String
    @State private var isMoodCardExpanded: Bool = false
    @State private var showMoodCard: Bool = true
    @State private var showDeleteConfirm: Bool = false
    @State private var showShareSheet: Bool = false
    @FocusState private var focus: Field?

    private let existing: JournalEntry?

    init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .new:
            self.existing = nil
            _text = State(initialValue: "")
        case .existing(let entry):
            self.existing = entry
            _text = State(initialValue: entry.text)
        }
    }

    private enum Field { case title, body }

    var body: some View {
        ZStack {
            DynamicBackgroundView()

            ScrollView {
                VStack(alignment: .leading, spacing: scaled(16)) {
                    TextField("Title", text: titleBinding)
                        .font(.system(size: scaled(26), weight: .bold))
                        .focused($focus, equals: .title)
                        .submitLabel(.next)
                        .onSubmit {
                            ensureNewlineBetweenTitleAndBody()
                            focus = .body
                        }
                        .padding(.horizontal, scaled(4))

                    if showMoodCard,
                       let moodLevelRaw = existing?.moodLevelRaw {
                        MoodSummaryCard(
                            moodLevelRaw: moodLevelRaw,
                            moodScore: existing?.moodScore,
                            emotionTags: existing?.emotionTags ?? [],
                            isExpanded: $isMoodCardExpanded
                        )
                    }

                    ZStack(alignment: .topLeading) {
                        if bodyBinding.wrappedValue.isEmpty {
                            Text("Start writing…")
                                .font(.system(size: scaled(17)))
                                .foregroundStyle(.tertiary)
                                .padding(.top, scaled(8))
                                .padding(.leading, scaled(5))
                        }
                        TextEditor(text: bodyBinding)
                            .font(.system(size: scaled(17)))
                            .focused($focus, equals: .body)
                            .frame(minHeight: scaled(300))
                            .scrollContentBackground(.hidden)
                    }
                }
                .padding(.horizontal, scaled(32))
                .padding(.top, scaled(8))
                .padding(.bottom, scaled(16))
            }
        .scrollContentBackground(.hidden)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if existing?.moodLevelRaw != nil {
                        Button {
                            showMoodCard.toggle()
                        } label: {
                            Label(showMoodCard ? "Hide mood card" : "Show mood card",
                                  systemImage: JournalIcons.moodLinkedIndicator)
                        }
                    }
                    if let existing {
                        Button {
                            appState.togglePin(existing)
                        } label: {
                            Label(existing.isPinned ? "Unpin" : "Pin",
                                  systemImage: existing.isPinned ? JournalIcons.pinSlashed : JournalIcons.pinFilled)
                        }
                    }
                    Button {
                        showShareSheet = true
                    } label: {
                        Label("Share…", systemImage: JournalIcons.share)
                    }
                    if existing != nil {
                        Divider()
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Label("Delete", systemImage: JournalIcons.trash)
                        }
                    }
                } label: {
                    Image(systemName: JournalIcons.overflowMenu)
                }
            }
            ToolbarItem(placement: .keyboard) {
                Spacer()
            }
            ToolbarItem(placement: .keyboard) {
                Button("Done") { focus = nil }
            }
        }
        .confirmationDialog("Delete this note?",
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let existing {
                    try? appState.deleteJournalEntry(id: existing.id)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showShareSheet) {
            ActivityView(items: [text])
        }
        .onAppear {
            if case .new = mode { focus = .title }
        }
        .onDisappear { save() }
        }  // close ZStack
    }

    // MARK: - Bindings

    private var titleBinding: Binding<String> {
        Binding(
            get: { JournalTextSlicing.editorSplit(text).title },
            set: { newTitle in
                let body = JournalTextSlicing.editorSplit(text).body
                text = JournalTextSlicing.editorJoin(title: newTitle, body: body)
            }
        )
    }

    private var bodyBinding: Binding<String> {
        Binding(
            get: { JournalTextSlicing.editorSplit(text).body },
            set: { newBody in
                let title = JournalTextSlicing.editorSplit(text).title
                text = JournalTextSlicing.editorJoin(title: title, body: newBody)
            }
        )
    }

    private func ensureNewlineBetweenTitleAndBody() {
        if !text.contains("\n") { text.append("\n") }
    }

    // MARK: - Save

    private func save() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .new:
            guard !trimmed.isEmpty else { return }
            _ = try? appState.createJournalEntry(text: text)
        case .existing(let entry):
            guard !trimmed.isEmpty else {
                try? appState.deleteJournalEntry(id: entry.id)
                return
            }
            guard text != entry.text else { return }
            try? appState.updateJournalEntry(id: entry.id, text: text)
        }
    }
}

/// Thin `UIActivityViewController` wrapper for the Share sheet.
private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
