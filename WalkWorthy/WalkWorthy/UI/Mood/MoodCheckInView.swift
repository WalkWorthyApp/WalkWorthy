//
//  MoodCheckInView.swift
//  WalkWorthy
//
//  4-step mood check-in wizard coordinator.
//  Steps: slider → emotion tags → impact categories → follow-up → cinematic
//

import SwiftUI
import FirebaseAnalytics

struct MoodCheckInView: View {
    let checkInType: CheckInType
    let onComplete: () -> Void

    @EnvironmentObject private var appState: AppState

    // MARK: - Step

    private enum CheckInStep: Equatable {
        case slider, emotionTags, impactCategories, followUp, cinematic
    }

    @State private var step: CheckInStep = .slider

    // MARK: - Accumulated Data

    @State private var sliderValue: Double = 0.5
    @State private var selectedTags: [String] = []
    @State private var selectedCategories: [String] = []
    @State private var followUpScore: Int = 0
    @State private var note: String = ""

    // MARK: - Draft Persistence

    /// On-device representation of an in-progress check-in. Persisted per-user
    /// and per-check-in-type so a network failure mid-wizard doesn't erase the
    /// user's selections. Cleared on successful submission.
    ///
    /// The slider position is deliberately NOT persisted: the wizard always
    /// reopens on the slider step, and the mood should start at dead-center
    /// neutral each time rather than wherever the user last left it.
    private struct Draft: Codable {
        var selectedTags: [String]
        var selectedCategories: [String]
        var followUpScore: Int
        var note: String
    }

    private static let draftEncoder = JSONEncoder()
    private static let draftDecoder = JSONDecoder()

    // MARK: - Submission

    @State private var submissionResult: MoodCheckInResponse?
    @State private var errorTitle: String?
    @State private var errorMessage: String?
    @State private var submissionTask: Task<Void, Never>?
    /// Debounced draft persistence. Text input (the `note` field) can fire a
    /// save on every keystroke; 400ms collapses rapid typing into a single
    /// UserDefaults write. Non-text inputs (slider, tags, step) are saved
    /// through the same path for consistency. Cancelled on view disappear
    /// (with a final flush save) and on successful submission.
    @State private var draftSaveTask: Task<Void, Never>?

    // MARK: - Derived

    private var currentMoodLevel: MoodLevel {
        MoodLevel.from(score: Int(sliderValue * 9) + 1)
    }

    // MARK: - Body

    var body: some View {
        // AI-consent gate (Guideline 5.1.2(i)): check-in data goes to OpenAI,
        // so the very first check-in starts with the consent screen. Declining
        // dismisses the wizard without sending anything. Once granted, the
        // flag flips and this body re-evaluates straight into the wizard.
        if appState.aiConsentGiven {
            checkInFlow
        } else {
            AIConsentView(
                onContinue: { appState.setAIConsentGiven(true) },
                onDecline: onComplete
            )
        }
    }

    private var checkInFlow: some View {
        stepContent
            .animation(.easeInOut(duration: 0.35), value: step)
            .onAppear {
                restoreDraft()
            }
            .onDisappear {
                submissionTask?.cancel()
                // Cancel the pending debounced write and flush-save immediately
                // so a draft the user typed milliseconds before dismissing
                // isn't lost.
                draftSaveTask?.cancel()
                draftSaveTask = nil
                saveDraft()
            }
            // Persist on every meaningful input change. Cheap — a single
            // UserDefaults write per edit — and avoids needing to plumb
            // "save draft" callbacks through every step view.
            .onChange(of: step) { _, _ in saveDraft() }
            .onChange(of: selectedTags) { _, _ in saveDraft() }
            .onChange(of: selectedCategories) { _, _ in saveDraft() }
            .onChange(of: followUpScore) { _, _ in saveDraft() }
            // `note` fires on every keystroke — debounce to avoid a
            // UserDefaults write per character. onDisappear flush-saves any
            // pending draft so a fast dismiss after typing doesn't lose work.
            .onChange(of: note) { _, _ in scheduleDebouncedDraftSave() }
    }

    /// Cancels the current pending debounced save and schedules a new one
    /// 400ms out. Matches the debounce pattern used by `AppState.profileSyncTask`.
    private func scheduleDebouncedDraftSave() {
        draftSaveTask?.cancel()
        draftSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            await MainActor.run {
                saveDraft()
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .slider:
            MoodSliderView(sliderValue: $sliderValue, onNext: {
                step = .emotionTags
            }, onBack: {
                // User backed out without submitting — the draft stays on
                // disk so they can resume on the next launch.
                onComplete()
            })

        case .emotionTags:
            EmotionTagsView(
                moodLevel: currentMoodLevel,
                selectedTags: $selectedTags,
                onNext: { step = .impactCategories },
                onBack: { step = .slider }
            )

        case .impactCategories:
            ImpactCategoriesView(
                moodLevel: currentMoodLevel,
                selectedCategories: $selectedCategories,
                onNext: { step = .followUp },
                onBack: { step = .emotionTags }
            )

        case .followUp:
            MoodFollowUpView(
                checkInType: checkInType,
                moodLevel: currentMoodLevel,
                followUpScore: $followUpScore,
                note: $note,
                onDone: submitCheckIn,
                onBack: { step = .impactCategories }
            )

        case .cinematic:
            CinematicTransitionView(
                response: submissionResult,
                errorTitle: errorTitle,
                errorMessage: errorMessage,
                onDone: onComplete,
                onRetry: {
                    errorTitle = nil
                    errorMessage = nil
                    submissionResult = nil
                    step = .followUp
                }
            )
        }
    }

    // MARK: - Submission

    private func submitCheckIn() {
        step = .cinematic

        let moodScore = Int(sliderValue * 9) + 1
        let noteValue = note.trimmingCharacters(in: .whitespacesAndNewlines)

        submissionTask = Task {
            do {
                let spectrumData = MoodSpectrumData(
                    moodScore: moodScore,
                    moodLevel: MoodLevel.from(score: moodScore).rawValue,
                    emotionTags: selectedTags,
                    impactCategories: selectedCategories,
                    followUpScore: followUpScore,
                    note: noteValue.isEmpty ? nil : noteValue
                )
                let request = MoodCheckInRequest(
                    checkInType: checkInType.rawValue,
                    moodSpectrumData: spectrumData
                )
                let response = try await appState.submitMoodCheckIn(request)
                try Task.checkCancellation()
                // Type only (morning/midday/evening) — no mood data in analytics.
                Analytics.logEvent("mood_checkin_completed", parameters: ["check_in_type": checkInType.rawValue])

                if !noteValue.isEmpty {
                    // Journal creation is best-effort. Surface a failure as a
                    // debug log so we notice it — the check-in itself already
                    // succeeded and is the user-visible source of truth.
                    do {
                        _ = try appState.createJournalEntry(
                            text: noteValue,
                            linkedCheckInId: response.checkInId,
                            moodLevelRaw: spectrumData.moodLevel,
                            moodScore: spectrumData.moodScore,
                            emotionTags: spectrumData.emotionTags
                        )
                    } catch {
                        #if DEBUG
                        print("[MoodCheckInView] Failed to create journal entry from note: \(error)")
                        #endif
                    }
                }

                await MainActor.run {
                    submissionResult = response
                    // Draft is only safe to delete once the backend has
                    // accepted the check-in. A cancelled task below leaves
                    // the draft intact.
                    draftSaveTask?.cancel()
                    draftSaveTask = nil
                    clearDraft()
                }
            } catch is CancellationError {
                // View was dismissed during submission — no-op
            } catch {
                await MainActor.run {
                    let apiError = error as? APIError
                    errorTitle = apiError?.errorTitle
                    let baseMessage: String
                    #if DEBUG
                    if let apiError {
                        switch apiError {
                        case .server(let code, let msg):
                            baseMessage = "Server error \(code): \(msg ?? "no message")"
                        case .network(let err):
                            baseMessage = "Network: \(err.localizedDescription)"
                        default:
                            baseMessage = apiError.errorDescription ?? error.localizedDescription
                        }
                    } else {
                        baseMessage = error.localizedDescription
                    }
                    #else
                    baseMessage = apiError?.errorDescription ?? error.localizedDescription
                    #endif
                    // Reassure the user — their selections are safe on-device
                    // and they can retry without re-entering anything.
                    errorMessage = "\(baseMessage)\n\nSaved on your device — we'll sync when you're back online."
                }
            }
        }
    }

    // MARK: - Draft Persistence

    /// UserDefaults key scoped by the authenticated user's Firebase sub claim
    /// and the current check-in type. Returns nil if the user isn't signed in
    /// yet, in which case we skip persistence entirely.
    private func draftKey() -> String? {
        guard let userSub = appState.authenticatedUserSub else { return nil }
        return "walkworthy.moodCheckIn.draft.\(userSub).\(checkInType.rawValue)"
    }

    private func saveDraft() {
        // Skip while the cinematic submission sequence is running — any state
        // updates there should not overwrite the draft we're about to clear.
        guard step != .cinematic, let key = draftKey() else { return }

        let draft = Draft(
            selectedTags: selectedTags,
            selectedCategories: selectedCategories,
            followUpScore: followUpScore,
            note: note
        )

        do {
            let data = try Self.draftEncoder.encode(draft)
            UserDefaults.standard.set(data, forKey: key)
        } catch {
            #if DEBUG
            print("[MoodCheckInView] Failed to encode check-in draft: \(error)")
            #endif
        }
    }

    private func restoreDraft() {
        guard let key = draftKey(),
              let data = UserDefaults.standard.data(forKey: key),
              let draft = try? Self.draftDecoder.decode(Draft.self, from: data)
        else { return }

        selectedTags = draft.selectedTags
        selectedCategories = draft.selectedCategories
        followUpScore = draft.followUpScore
        note = draft.note
    }

    private func clearDraft() {
        guard let key = draftKey() else { return }
        UserDefaults.standard.removeObject(forKey: key)
    }
}

#Preview {
    MoodCheckInView(checkInType: .morning, onComplete: {})
}
