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
        ZStack(alignment: .topLeading) {
            DynamicBackgroundView()

            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, scaled(21))
            .padding(.top, scaled(20))

            VStack(spacing: 0) {
                // Spacer to push content below the back button
                Color.clear.frame(height: scaled(56))

                // Header — outside ScrollView so shadow/gradient isn't clipped.
                // .frame(maxWidth: .infinity) ensures the outer VStack stays full-width.
                VStack(spacing: scaled(12)) {
                    MoodWeatherBackground(moodScore: moodLevelToScore(moodLevel), isCompact: true)

                    Text(moodLevel.displayName)
                        .font(Font.newsreaderSemiBoldItalic(fixedSize: scaled(26)))

                    Text("What best describes this feeling?")
                        .font(Font.newsreader(fixedSize: scaled(17)))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, scaled(8))
                .padding(.bottom, scaled(24))

                ScrollView {
                    VStack(spacing: scaled(16)) {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: scaled(100)), spacing: scaled(10))],
                            spacing: scaled(10)
                        ) {
                            ForEach(emotionTags(for: moodLevel), id: \.self) { tag in
                                ChipButton(
                                    label: tag,
                                    isSelected: selectedTags.contains(tag),
                                    selectedColor: TimeOfDayTheme.current.accent
                                ) {
                                    toggleTag(tag)
                                }
                            }
                        }
                        .padding(.horizontal, scaled(12))
                    }
                    .padding(.bottom, scaled(24))
                }
                .scrollContentBackground(.hidden)

                // Next button
                Button(action: onNext) {
                    Text("Next \u{2192}")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, scaled(14))
                        .background(TimeOfDayTheme.current.accent)
                        .cornerRadius(scaled(30))
                }
                .padding(.horizontal, scaled(12))
                .padding(.bottom, scaled(40))
            }
        }
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
                .multilineTextAlignment(.center)
                // Single-line pills: long labels ("Overwhelmed", "Disappointed")
                // hyphen-break mid-word inside the grid cell on 402pt-wide
                // iPhones. Shrink slightly instead of wrapping.
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, scaled(14))
                .padding(.vertical, scaled(8))
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
