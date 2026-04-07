//
//  MoodCheckInView.swift
//  WalkWorthy
//
//  4-step mood check-in wizard coordinator.
//  Steps: slider → emotion tags → impact categories → follow-up
//         → cross transition → AI response.
//

import SwiftUI

struct MoodCheckInView: View {
    let checkInType: CheckInType
    let onComplete: () -> Void

    @EnvironmentObject private var appState: AppState

    // MARK: - Step

    private enum CheckInStep: Equatable {
        case slider, emotionTags, impactCategories, followUp, transitioning, response
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
    @State private var errorMessage: String?
    @State private var submissionTask: Task<Void, Never>?

    // MARK: - Derived

    private var currentMoodLevel: MoodLevel {
        MoodLevel.from(score: Int(sliderValue * 9) + 1)
    }

    // MARK: - Body

    var body: some View {
        stepContent
            .animation(.easeInOut(duration: 0.35), value: step)
            .onDisappear {
                submissionTask?.cancel()
            }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case .slider:
            MoodSliderView(sliderValue: $sliderValue) {
                step = .emotionTags
            }

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

        case .transitioning:
            ZStack {
                MoodWeatherBackground(moodScore: sliderValue)
                CrossTransitionView(moodLevel: currentMoodLevel) {
                    step = .response
                }
            }
            .ignoresSafeArea()

        case .response:
            responseContent
        }
    }

    // MARK: - Response Content

    @ViewBuilder
    private var responseContent: some View {
        if let result = submissionResult {
            MoodResponseView(
                response: result,
                moodLevel: currentMoodLevel,
                onDismiss: onComplete
            )
        } else if let error = errorMessage {
            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 48))
                    .foregroundColor(.orange)

                Text("Something went wrong")
                    .font(.title2.weight(.semibold))

                Text(error)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Button("Try Again") {
                    errorMessage = nil
                    step = .followUp
                }
                .buttonStyle(.bordered)

                Spacer()
            }
        } else {
            // API still in-flight when animation finished — brief loading
            VStack {
                Spacer()
                ProgressView()
                    .scaleEffect(1.5)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemBackground))
        }
    }

    // MARK: - Submission

    private func submitCheckIn() {
        step = .transitioning

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

                await MainActor.run {
                    submissionResult = response
                    // CrossTransitionView.onComplete sets step = .response
                    // when the animation finishes; responseContent then shows
                    // the result. If the animation already completed, step is
                    // already .response and the @State update re-renders it.
                }
            } catch is CancellationError {
                // View was dismissed during submission — no-op
            } catch {
                await MainActor.run {
                    #if DEBUG
                    if let apiError = error as? APIError {
                        switch apiError {
                        case .server(let code, let msg):
                            errorMessage = "Server error \(code): \(msg ?? "no message")"
                        case .network(let err):
                            errorMessage = "Network: \(err.localizedDescription)"
                        default:
                            errorMessage = error.localizedDescription
                        }
                    } else {
                        errorMessage = error.localizedDescription
                    }
                    #else
                    errorMessage = "Something went wrong. Please try again."
                    #endif
                    step = .response
                }
            }
        }
    }
}

#Preview {
    MoodCheckInView(checkInType: .morning, onComplete: {})
}
