//
//  EmotionTagsView.swift
//  WalkWorthy
//
//  Step 2 of the mood check-in wizard: select emotion words
//  that describe the current feeling.
//

import SwiftUI

struct EmotionTagsView: View {
    let moodLevel: MoodLevel
    @Binding var selectedTags: [String]
    let onNext: () -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Navigation bar
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.title3.weight(.semibold))
                        .foregroundColor(.primary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            ScrollView {
                VStack(spacing: 16) {
                    // Compact mood orb
                    MoodWeatherBackground(moodScore: moodLevelToScore(moodLevel), isCompact: true)
                        .padding(.top, 8)

                    // Mood level name
                    Text(moodLevel.displayName)
                        .font(.system(size: 24, weight: .bold))

                    // Prompt
                    Text("What best describes this feeling?")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .padding(.bottom, 8)

                    // Emotion tag chips
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 100), spacing: 10)],
                        spacing: 10
                    ) {
                        ForEach(emotionTags(for: moodLevel), id: \.self) { tag in
                            ChipButton(
                                label: tag,
                                isSelected: selectedTags.contains(tag),
                                selectedColor: chipColor(for: moodLevel)
                            ) {
                                toggleTag(tag)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.bottom, 24)
            }

            // Next button
            Button(action: onNext) {
                Text("Next \u{2192}")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(chipColor(for: moodLevel))
                    .cornerRadius(30)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 40)
        }
        .background(Color(.systemBackground))
    }

    // MARK: - Helpers

    private func toggleTag(_ tag: String) {
        if selectedTags.contains(tag) {
            selectedTags.removeAll { $0 == tag }
        } else {
            selectedTags.append(tag)
        }
    }

    private func emotionTags(for level: MoodLevel) -> [String] {
        switch level {
        case .veryUnpleasant:
            return ["Angry", "Anxious", "Scared", "Overwhelmed", "Ashamed",
                    "Frustrated", "Stressed", "Worried", "Hopeless", "Lonely",
                    "Discouraged", "Drained", "Sad", "Guilty", "Irritated", "Disappointed"]
        case .unpleasant:
            return ["Anxious", "Worried", "Tired", "Stressed", "Sad",
                    "Uncertain", "Drained", "Frustrated", "Overwhelmed"]
        case .neutral:
            return ["Content", "Calm", "Peaceful", "Indifferent",
                    "Drained", "Uncertain", "Steady", "Okay"]
        case .pleasant:
            return ["Hopeful", "Grateful", "Peaceful", "Confident",
                    "Relieved", "Encouraged", "Joyful", "Satisfied"]
        case .veryPleasant:
            return ["Amazed", "Excited", "Joyful", "Grateful", "Hopeful",
                    "Blessed", "Faithful", "Proud", "Confident", "Thankful",
                    "Inspired", "Energized"]
        }
    }
}

// MARK: - Shared Helpers

/// Converts a MoodLevel to a 0.0–1.0 score for the weather background.
func moodLevelToScore(_ level: MoodLevel) -> Double {
    switch level {
    case .veryUnpleasant: return 0.1
    case .unpleasant: return 0.3
    case .neutral: return 0.5
    case .pleasant: return 0.7
    case .veryPleasant: return 0.9
    }
}

/// Returns the chip fill color for a given mood level.
func chipColor(for level: MoodLevel) -> Color {
    switch level {
    case .veryUnpleasant: return Color(red: 0.45, green: 0.25, blue: 0.60) // purple
    case .unpleasant:     return Color(red: 0.44, green: 0.50, blue: 0.56) // slate
    case .neutral:        return Color(red: 0.25, green: 0.60, blue: 0.58) // teal
    case .pleasant:       return Color(red: 0.85, green: 0.65, blue: 0.20) // amber
    case .veryPleasant:   return Color(red: 0.42, green: 0.68, blue: 0.30) // green
    }
}

// MARK: - Chip Button

/// Reusable pill-shaped chip button for tag selection.
struct ChipButton: View {
    let label: String
    let isSelected: Bool
    let selectedColor: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.subheadline)
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .frame(minWidth: 0)
                .foregroundColor(isSelected ? .white : .primary)
                .background(
                    Capsule()
                        .fill(isSelected ? selectedColor : Color.clear)
                )
                .overlay(
                    Capsule()
                        .stroke(isSelected ? Color.clear : Color.secondary.opacity(0.4), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    EmotionTagsView(
        moodLevel: .pleasant,
        selectedTags: .constant(["Hopeful", "Grateful"]),
        onNext: {},
        onBack: {}
    )
}
