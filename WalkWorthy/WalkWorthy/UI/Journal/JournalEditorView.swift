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
import FirebaseCrashlytics

struct JournalEditorView: View {
    enum Mode { case new, existing(JournalEntry) }
    let mode: Mode

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    /// Drives the `.background` save trigger. Force-quit from the app switcher
    /// fires `.background` just before suspension, which gives us our last
    /// chance to persist in-progress text.
    @Environment(\.scenePhase) private var scenePhase

    @State private var text: String
    @State private var isMoodCardExpanded: Bool = false
    @State private var showMoodCard: Bool = true
    @State private var showDeleteConfirm: Bool = false
    @State private var showShareSheet: Bool = false
    /// In-flight debounced auto-save. Cancelled on every keystroke (to restart
    /// the 1.5s timer) and on view disappear.
    @State private var autoSaveTask: Task<Void, Never>?
    /// User-visible save failure. Presented via `.alert` and nil'd on dismiss.
    @State private var saveError: String?
    /// Tracks the entry created during a `.new`-mode session so that subsequent
    /// saves (from `.background` scenephase, `.onDisappear`, or the debounced
    /// auto-save) become updates rather than duplicate inserts. Without this,
    /// typing + backgrounding the app before navigating away creates one row
    /// per lifecycle trigger.
    @State private var createdEntryId: String?
    @FocusState private var focus: Field?

    /// Debounce interval for auto-save. Long enough to avoid thrashing the
    /// store on every keystroke, short enough that a force-quit rarely loses
    /// more than the last ~1-2 seconds of text.
    private static let autoSaveDebounce: Duration = .seconds(1.5)

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
                VStack(alignment: .leading, spacing: scaled(24)) {
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
                .padding(.top, scaled(24))
                .padding(.bottom, scaled(16))
            }
        .scrollContentBackground(.hidden)
        .navigationBarTitleDisplayMode(.inline)
        .navigationTitle("")
        .animation(nil, value: focus)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if focus != nil {
                    Button("Done") { focus = nil }
                        .transaction { $0.animation = nil }
                }
            }
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
                .accessibilityLabel("More options")
            }
        }
        .confirmationDialog("Delete this note?",
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let existing {
                    do {
                        try appState.deleteJournalEntry(id: existing.id)
                        dismiss()
                    } catch {
                        saveError = "Couldn't delete this note. Please try again."
                        #if DEBUG
                        print("[JournalEditorView] delete failed: \(error)")
                        #else
                        Crashlytics.crashlytics().record(error: error)
                        #endif
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showShareSheet) {
            ActivityView(items: [text])
        }
        .alert(
            "Couldn't save",
            isPresented: Binding(
                get: { saveError != nil },
                set: { if !$0 { saveError = nil } }
            ),
            presenting: saveError
        ) { _ in
            Button("OK", role: .cancel) { saveError = nil }
        } message: { msg in
            Text(msg)
        }
        .onAppear {
            if case .new = mode { focus = .title }
        }
        // Debounced auto-save: cancels the in-flight task on every keystroke
        // and re-schedules. If the user stops typing for `autoSaveDebounce`
        // we persist; otherwise the existing task is simply replaced with no
        // write. `Task.sleep` is cancellation-aware so this is safe.
        .onChange(of: text) { _, _ in
            autoSaveTask?.cancel()
            autoSaveTask = Task {
                do {
                    try await Task.sleep(for: Self.autoSaveDebounce)
                } catch {
                    return // cancelled — newer keystroke replaced us
                }
                if Task.isCancelled { return }
                save()
            }
        }
        // Force-quit / app-switcher kill saves text before iOS suspends us.
        // `.background` fires synchronously during this transition, giving
        // us one last chance to persist. Keep `.onDisappear` as a fallback.
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .background {
                autoSaveTask?.cancel()
                save()
            }
        }
        .onDisappear {
            autoSaveTask?.cancel()
            save()
        }
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
        do {
            switch mode {
            case .new:
                guard !trimmed.isEmpty else { return }
                // First save in a .new-mode session: create and remember the id.
                // Subsequent saves (scenephase .background, .onDisappear,
                // debounced auto-save) update that same row instead of
                // inserting duplicates.
                if let createdId = createdEntryId {
                    try appState.updateJournalEntry(id: createdId, text: text)
                } else {
                    let created = try appState.createJournalEntry(text: text)
                    createdEntryId = created.id
                }
            case .existing(let entry):
                guard !trimmed.isEmpty else {
                    try appState.deleteJournalEntry(id: entry.id)
                    return
                }
                guard text != entry.text else { return }
                try appState.updateJournalEntry(id: entry.id, text: text)
            }
        } catch {
            // Surface to the user so they know the text wasn't persisted and
            // can retry / copy the text out before navigating away.
            saveError = "Couldn't save — please try again."
            #if DEBUG
            print("[JournalEditorView] save failed: \(error)")
            #else
            Crashlytics.crashlytics().record(error: error)
            #endif
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
