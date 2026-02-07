//
//  MoodCheckInView.swift
//  WalkWorthy
//
//  Main mood check-in flow with mood selection and follow-up questions.
//

import SwiftUI

struct MoodCheckInView: View {
    let checkInType: CheckInType
    let onComplete: (MoodCheckInResponse, MoodOption?) -> Void

    @EnvironmentObject private var appState: AppState
    @State private var selectedMood: MoodOption?
    @State private var selectedFollowUp: String?
    @State private var showFollowUp = false
    @State private var isSubmitting = false
    @State private var errorMessage: String?
    @State private var submissionTask: Task<Void, Never>?
    @State private var autoAdvanceWorkItem: DispatchWorkItem?

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Header with greeting
                headerSection

                if !showFollowUp {
                    // Mood selection
                    moodSelectionSection
                } else {
                    // Follow-up question
                    followUpSection
                }

                if let error = errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding()
                }
            }
            .padding()
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: showFollowUp)
        .onDisappear {
            // Cancel any pending tasks to prevent completion handlers on dismissed view
            submissionTask?.cancel()
            autoAdvanceWorkItem?.cancel()
        }
    }

    private var headerSection: some View {
        VStack(spacing: 16) {
            // Time-of-day icon
            Image(systemName: checkInType.iconName)
                .font(.system(size: 48))
                .foregroundColor(checkInType.color)
                .padding(.top, 20)

            // Greeting
            Text(showFollowUp ? checkInType.followUpQuestion : checkInType.greeting)
                .font(.title2)
                .fontWeight(.semibold)
                .multilineTextAlignment(.center)
                .foregroundColor(.primary)
                .padding(.horizontal)

            if showFollowUp, let mood = selectedMood {
                // Show selected mood as context
                HStack(spacing: 8) {
                    Text(mood.emoji)
                    Text(mood.displayName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color(.systemGray6))
                )
            }
        }
    }

    private var moodSelectionSection: some View {
        VStack(spacing: 20) {
            // Mood options grid
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 12) {
                ForEach(checkInType.moodOptions) { mood in
                    MoodOptionButton(
                        mood: mood,
                        isSelected: selectedMood == mood,
                        action: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                selectedMood = mood
                            }
                            // Cancel any pending auto-advance
                            autoAdvanceWorkItem?.cancel()

                            // Auto-advance after brief delay
                            let workItem = DispatchWorkItem {
                                withAnimation {
                                    showFollowUp = true
                                }
                            }
                            autoAdvanceWorkItem = workItem
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
                        }
                    )
                }
            }
        }
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        ))
    }

    private var followUpSection: some View {
        VStack(spacing: 24) {
            // Follow-up options
            VStack(spacing: 12) {
                ForEach(checkInType.followUpOptions, id: \.self) { option in
                    FollowUpOptionButton(
                        option: option,
                        isSelected: selectedFollowUp == option,
                        action: {
                            selectedFollowUp = option
                        }
                    )
                }
            }

            // Submit button
            Button(action: submitCheckIn) {
                HStack {
                    if isSubmitting {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                    } else {
                        Text("Get Encouragement")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(selectedFollowUp != nil ? Color.accentColor : Color.gray)
                )
                .foregroundColor(.white)
            }
            .disabled(selectedFollowUp == nil || isSubmitting)

            // Back button
            Button(action: {
                withAnimation {
                    showFollowUp = false
                    selectedFollowUp = nil
                }
            }) {
                Text("Back")
                    .foregroundColor(.secondary)
            }
        }
        .transition(.asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        ))
    }

    private func submitCheckIn() {
        guard let mood = selectedMood,
              let followUp = selectedFollowUp else { return }

        isSubmitting = true
        errorMessage = nil

        // Store the task so we can cancel it if the view disappears
        submissionTask = Task {
            do {
                let request = MoodCheckInRequest(
                    checkInType: checkInType.rawValue,
                    primaryMood: mood.rawValue,
                    followUpResponse: followUp.lowercased()
                )

                let response = try await appState.submitMoodCheckIn(request)

                // Check if task was cancelled before calling completion
                try Task.checkCancellation()

                await MainActor.run {
                    isSubmitting = false
                    onComplete(response, selectedMood)
                }
            } catch is CancellationError {
                // Task was cancelled - don't show error
                await MainActor.run {
                    isSubmitting = false
                }
            } catch {
                #if DEBUG
                print("[MoodCheckIn] Error: \(error)")
                print("[MoodCheckIn] Error type: \(type(of: error))")
                if let apiError = error as? APIError {
                    print("[MoodCheckIn] APIError: \(apiError)")
                }
                #endif
                await MainActor.run {
                    isSubmitting = false
                    #if DEBUG
                    // Show detailed error in debug builds
                    if let apiError = error as? APIError {
                        switch apiError {
                        case .server(let statusCode, let message):
                            errorMessage = "Server error \(statusCode): \(message ?? "no message")"
                        case .network(let underlyingError):
                            errorMessage = "Network error: \(underlyingError.localizedDescription)"
                        default:
                            errorMessage = "Error: \(error.localizedDescription)"
                        }
                    } else {
                        errorMessage = "Error: \(error.localizedDescription)"
                    }
                    #else
                    errorMessage = "Something went wrong. Please try again."
                    #endif
                }
            }
        }
    }
}
