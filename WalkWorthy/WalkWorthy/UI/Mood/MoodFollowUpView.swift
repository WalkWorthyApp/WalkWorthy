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
        ZStack(alignment: .topLeading) {
            DynamicBackgroundView()

            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, scaled(42))
            .padding(.top, scaled(20))

            VStack(spacing: 0) {
                // Spacer to push content below the back button
                Color.clear.frame(height: scaled(56))

                // Header — outside ScrollView so shadow/gradient isn't clipped.
                VStack(spacing: scaled(12)) {
                    MoodWeatherBackground(moodScore: moodLevelToScore(moodLevel), isCompact: true)

                    Text(moodLevel.displayName)
                        .font(Font.newsreaderSemiBoldItalic(fixedSize: scaled(26)))

                    Text(checkInType.followUpQuestion)
                        .font(Font.newsreader(fixedSize: scaled(17)))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, scaled(16))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, scaled(8))
                .padding(.bottom, scaled(8))

                ScrollView {
                    VStack(spacing: scaled(16)) {
                        // Follow-up options (vertical stack)
                        VStack(spacing: scaled(10)) {
                            ForEach(Array(checkInType.followUpOptions.enumerated()), id: \.offset) { index, option in
                                let score = index + 1
                                let isSelected = followUpScore == score
                                Button {
                                    followUpScore = score
                                } label: {
                                    Text(option)
                                        .font(.body)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, scaled(14))
                                        .foregroundColor(isSelected ? .white : .primary)
                                        .background(
                                            RoundedRectangle(cornerRadius: scaled(12))
                                                .fill(isSelected ? TimeOfDayTheme.current.accent : Color.clear)
                                        )
                                        .overlay(
                                            RoundedRectangle(cornerRadius: scaled(12))
                                                .stroke(
                                                    isSelected ? Color.clear : Color.secondary.opacity(0.3),
                                                    lineWidth: 1
                                                )
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, scaled(24))

                        // Note section
                        Text("Anything you want to jot down?")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.top, scaled(16))

                        ZStack(alignment: .topLeading) {
                            TextEditor(text: $note)
                                .frame(minHeight: scaled(100))
                                .scrollContentBackground(.hidden)
                                .padding(scaled(4))

                            if note.isEmpty {
                                Text("Write a quick thought...")
                                    .foregroundColor(.secondary.opacity(0.5))
                                    .padding(.horizontal, scaled(8))
                                    .padding(.vertical, scaled(12))
                                    .allowsHitTesting(false)
                            }
                        }
                        .overlay(
                            RoundedRectangle(cornerRadius: scaled(12))
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                        )
                        .padding(.horizontal, scaled(24))
                    }
                    .padding(.bottom, scaled(24))
                }
                .scrollContentBackground(.hidden)

                // Done button
                Button(action: onDone) {
                    Text("Done")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, scaled(14))
                        .background(
                            followUpScore > 0
                                ? TimeOfDayTheme.current.accent
                                : Color.secondary.opacity(0.3)
                        )
                        .cornerRadius(scaled(30))
                }
                .disabled(followUpScore == 0)
                .padding(.horizontal, scaled(24))
                .padding(.bottom, scaled(40))
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
