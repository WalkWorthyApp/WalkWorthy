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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Step

    /// Declaration order is wizard order, so `Comparable` tells Next from Back.
    private enum CheckInStep: Comparable {
        case slider, emotionTags, impactCategories, followUp, cinematic
    }

    @State private var step: CheckInStep = .slider
    /// Whether the latest step change went backwards. Picks the edge the
    /// incoming step slides in from.
    @State private var isMovingBack = false

    /// Shared by step changes and the consent swap so the wizard moves at one pace.
    private static let stepAnimation: Animation = .smooth(duration: 0.35)

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
        // flag flips and this body re-evaluates into the wizard.
        //
        // The ZStack exists so the swap can cross-fade. A bare if/else in
        // `body` has no container to transition within, so granting consent
        // hard-cut straight to the mood slider. The timing matches the
        // between-step animation below, so the whole wizard reads as one
        // continuous flow rather than a gate bolted onto its front.
        ZStack {
            if appState.aiConsentGiven {
                checkInFlow
            } else {
                AIConsentView(
                    onContinue: {},
                    onDecline: onComplete
                )
            }
        }
        .animation(Self.stepAnimation, value: appState.aiConsentGiven)
    }

    private var checkInFlow: some View {
        // The cinematic replaces the wizard with a short, gentle crossfade,
        // both on submit and on retry. It choreographs its own entrance, so
        // the step drift is kept out of this swap. Movement here would stack
        // a second motion on top of the cinematic's own.
        ZStack {
            if step == .cinematic {
                cinematic
            } else {
                wizardSteps
            }
        }
        .animation(.easeInOut(duration: 0.4), value: step == .cinematic)
        .onDisappear {
            submissionTask?.cancel()
            regenerateTask?.cancel()
            // Consent can temporarily remove this flow without dismissing
            // its owner. Never restore a loading step with no running task.
            if step == .cinematic && submissionResult == nil && errorMessage == nil {
                step = .followUp
            }
        }
    }

    /// The mood, emotion, impact and follow-up screens.
    private var wizardSteps: some View {
        // Same container fix as the consent swap: a bare `switch` hard-cuts
        // even under `.animation`. The backdrop sits outside the transition
        // so only the step content moves. Fading full-screen copies of it
        // would dim the screen mid-swap.
        ZStack {
            DynamicBackgroundView()
            stepContent
                .transition(stepTransition)
                // A leaving view loses its implicit ZStack order and would
                // animate out hidden behind the opaque backdrop.
                .zIndex(1)
        }
        .animation(Self.stepAnimation, value: step)
    }

    /// The new step fades in while drifting a short way from the side it
    /// comes from (the right on Next, the left on Back). The old step fades
    /// in place, quickly enough that its text doesn't ghost through the new
    /// one. Reduce Motion gets a plain crossfade.
    ///
    /// Only the incoming step moves because a leaving view keeps the
    /// transition from its last render. A direction-dependent exit would
    /// replay the previous direction: Back after Next moved both steps the
    /// same way, on top of each other.
    private var stepTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        let drift = scaled(40)
        return .asymmetric(
            insertion: .offset(x: isMovingBack ? -drift : drift).combined(with: .opacity),
            removal: .opacity.animation(.easeOut(duration: 0.15))
        )
    }

    private func go(to next: CheckInStep) {
        isMovingBack = next < step
        step = next
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .slider:
            MoodSliderView(sliderValue: $sliderValue, onNext: {
                go(to: .emotionTags)
            }, onBack: {
                // The in-progress selections are memory-only and disappear
                // when the check-in sheet is dismissed.
                onComplete()
            })

        case .emotionTags:
            EmotionTagsView(
                moodLevel: currentMoodLevel,
                selectedTags: $selectedTags,
                onNext: { go(to: .impactCategories) },
                onBack: { go(to: .slider) }
            )

        case .impactCategories:
            ImpactCategoriesView(
                moodLevel: currentMoodLevel,
                selectedCategories: $selectedCategories,
                onNext: { go(to: .followUp) },
                onBack: { go(to: .emotionTags) }
            )

        case .followUp:
            MoodFollowUpView(
                checkInType: checkInType,
                moodLevel: currentMoodLevel,
                followUpScore: $followUpScore,
                note: $note,
                onDone: submitCheckIn,
                onBack: { go(to: .impactCategories) }
            )

        case .cinematic:
            // `checkInFlow` shows the cinematic in place of the wizard.
            EmptyView()
        }
    }

    private var cinematic: some View {
        CinematicTransitionView(
            response: submissionResult,
            errorTitle: errorTitle,
            errorMessage: errorMessage,
            onDone: onComplete,
            onRetry: {
                errorTitle = nil
                errorMessage = nil
                submissionResult = nil
                go(to: .followUp)
            },
            onRegenerate: regenerateEncouragement,
            isRegenerating: isRegenerating,
            regenerateErrorMessage: regenerateErrorMessage,
            showsSupportLine: currentMoodLevel == .veryUnpleasant
        )
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
        guard !isRegenerating, let checkInId = submissionResult?.checkInId else { return }
        isRegenerating = true
        regenerateErrorMessage = nil

        regenerateTask?.cancel()
        regenerateTask = Task {
            do {
                let request = MoodCheckInRequest(
                    checkInType: checkInType.rawValue,
                    moodSpectrumData: makeSpectrumData(),
                    regenerate: true,
                    expectedCheckInId: checkInId
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
        go(to: .cinematic)

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
                // Neutral name: analytics goes to Google, so the event itself should not
                // describe mood/health activity (FTC and Washington MHMDA sensitivity).
                Analytics.logEvent("checkin_completed", parameters: ["check_in_type": checkInType.rawValue])

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
