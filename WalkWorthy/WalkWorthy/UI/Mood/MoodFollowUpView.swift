//
//  MoodFollowUpView.swift
//  WalkWorthy
//
//  Step 4 of the mood check-in wizard: follow-up question
//  with selectable options and an optional note.
//

import SwiftUI

struct MoodFollowUpView: View {
    let checkInType: CheckInType
    let moodLevel: MoodLevel
    @Binding var followUpScore: Int    // 1–4, 0 = not selected
    @Binding var note: String
    let onDone: () -> Void
    let onBack: () -> Void

    var body: some View {
        ZStack {
            DynamicBackgroundView()
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
                .padding(.horizontal, 42)
                .padding(.top, 20)

                ScrollView {
                    VStack(spacing: 16) {
                        // Compact mood orb
                        MoodWeatherBackground(moodScore: moodLevelToScore(moodLevel), isCompact: true)
                            .padding(.top, 8)

                        // Mood level name
                        Text(moodLevel.displayName)
                            .font(Font.newsreaderSemiBoldItalic(fixedSize: 26))

                        // Follow-up question
                        Text(checkInType.followUpQuestion)
                            .font(Font.newsreader(fixedSize: 17))
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)

                        // Follow-up options (vertical stack)
                        VStack(spacing: 10) {
                            ForEach(Array(checkInType.followUpOptions.enumerated()), id: \.offset) { index, option in
                                let score = index + 1
                                let isSelected = followUpScore == score
                                Button {
                                    followUpScore = score
                                } label: {
                                    Text(option)
                                        .font(.body)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 14)
                                        .foregroundColor(isSelected ? .white : .primary)
                                        .background(
                                            RoundedRectangle(cornerRadius: 12)
                                                .fill(isSelected ? chipColor(for: moodLevel) : Color.clear)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 12)
                                                .stroke(
                                                    isSelected ? Color.clear : Color.secondary.opacity(0.3),
                                                    lineWidth: 1
                                                )
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 24)

                        // Note section
                        Text("Anything you want to jot down?")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.top, 16)

                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $note)
                                .frame(minHeight: 100)
                                .scrollContentBackground(.hidden)
                                .padding(4)

                            if note.isEmpty {
                                Text("Write a quick thought...")
                                    .foregroundColor(.secondary.opacity(0.5))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 12)
                                    .allowsHitTesting(false)
                            }
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                        .padding(.horizontal, 24)
                    }
                    .padding(.bottom, 24)
                }
                .scrollContentBackground(.hidden)

                // Done button
                Button(action: onDone) {
                    Text("Done")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            followUpScore > 0
                                ? chipColor(for: moodLevel)
                                : Color.secondary.opacity(0.3)
                        )
                        .cornerRadius(30)
                }
                .disabled(followUpScore == 0)
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
    }
}

#Preview {
    MoodFollowUpView(
        checkInType: .morning,
        moodLevel: .pleasant,
        followUpScore: .constant(0),
        note: .constant(""),
        onDone: {},
        onBack: {}
    )
}
