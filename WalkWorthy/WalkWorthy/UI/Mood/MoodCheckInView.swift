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

    // MARK: - Submission

    @State private var submissionResult: MoodCheckInResponse?
    @State private var errorTitle: String?
    @State private var errorMessage: String?
    @State private var submissionTask: Task<Void, Never>?
    @State private var regenerateTask: Task<Void, Never>?
    @State private var isRegenerating = false
    @State private var regenerateErrorMessage: String?
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
            .onDisappear {
                submissionTask?.cancel()
                regenerateTask?.cancel()
            }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .slider:
            MoodSliderView(sliderValue: $sliderValue, onNext: {
                step = .emotionTags
            }, onBack: {
                // The in-progress selections are memory-only and disappear
                // when the check-in sheet is dismissed.
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
                },
                onRegenerate: regenerateEncouragement,
                isRegenerating: isRegenerating,
                regenerateErrorMessage: regenerateErrorMessage
            )
        }
    }

    // MARK: - Submission

    /// Regenerates the encouragement for the check-in that was just submitted.
    ///
    /// Deliberately NOT a re-run of `submitCheckIn()`: that path also creates a
    /// journal entry from the note and logs the completion analytics event, and
    /// neither should happen twice for one check-in. This only swaps the AI
    /// response. A failure keeps the existing encouragement on screen and
    /// reports inline — losing the response the user already has would be a
    /// worse outcome than a failed retry.
    private func regenerateEncouragement() {
        guard !isRegenerating else { return }
        isRegenerating = true
        regenerateErrorMessage = nil

        regenerateTask?.cancel()
        regenerateTask = Task {
            do {
                let request = MoodCheckInRequest(
                    checkInType: checkInType.rawValue,
                    moodSpectrumData: makeSpectrumData(),
                    regenerate: true
                )
                let response = try await appState.submitMoodCheckIn(request)
                try Task.checkCancellation()
                await MainActor.run {
                    submissionResult = response
                    isRegenerating = false
                }
            } catch is CancellationError {
                await MainActor.run { isRegenerating = false }
            } catch {
                await MainActor.run {
                    let apiError = error as? APIError
                    regenerateErrorMessage = apiError?.errorDescription
                        ?? "Couldn't write a new one just now. Your encouragement above is unchanged."
                    isRegenerating = false
                }
            }
        }
    }

    /// The check-in payload built from current wizard state. Shared by the
    /// initial submit and by regeneration so a retry describes exactly the same
    /// check-in — the backend keys off it to find the document to overwrite.
    private func makeSpectrumData() -> MoodSpectrumData {
        let moodScore = Int(sliderValue * 9) + 1
        let noteValue = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return MoodSpectrumData(
            moodScore: moodScore,
            moodLevel: MoodLevel.from(score: moodScore).rawValue,
            emotionTags: selectedTags,
            impactCategories: selectedCategories,
            followUpScore: followUpScore,
            note: noteValue.isEmpty ? nil : noteValue
        )
    }

    private func submitCheckIn() {
        step = .cinematic

        let noteValue = note.trimmingCharacters(in: .whitespacesAndNewlines)

        submissionTask = Task {
            do {
                let spectrumData = makeSpectrumData()
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
                    // The open view retains the selections in memory for retry.
                    errorMessage = "\(baseMessage)\n\nYour selections are still here — you can retry without re-entering them."
                }
            }
        }
    }

}

#Preview {
    MoodCheckInView(checkInType: .morning, onComplete: {})
}
