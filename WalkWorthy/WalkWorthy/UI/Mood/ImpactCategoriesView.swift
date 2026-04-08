//
//  ImpactCategoriesView.swift
//  WalkWorthy
//
//  Step 3 of the mood check-in wizard: select what's having
//  the biggest impact on the user's mood.
//

import SwiftUI

struct ImpactCategoriesView: View {
    let moodLevel: MoodLevel
    @Binding var selectedCategories: [String]
    let onNext: () -> Void
    let onBack: () -> Void

    private let allCategories = [
        "Faith", "Scripture", "Prayer", "Church", "Community",
        "Health", "Self-Care", "Hobbies", "Identity", "Fitness",
        "Family", "Friends", "Dating", "Partner",
        "Education", "Tasks", "Work", "Money",
        "Weather", "Current Events", "Travel"
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            DynamicBackgroundView()

            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 42)
            .padding(.top, 20)

            VStack(spacing: 0) {
                // Spacer to push content below the back button
                Color.clear.frame(height: 56)

                // Header — outside ScrollView so shadow/gradient isn't clipped.
                // .frame(maxWidth: .infinity) ensures the outer VStack stays full-width.
                VStack(spacing: 12) {
                    MoodWeatherBackground(moodScore: moodLevelToScore(moodLevel), isCompact: true)

                    Text(moodLevel.displayName)
                        .font(Font.newsreaderSemiBoldItalic(fixedSize: 26))

                    Text("What\u{2019}s having the biggest impact on you?")
                        .font(Font.newsreader(fixedSize: 17))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                .padding(.bottom, 8)

                ScrollView {
                    VStack(spacing: 16) {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 100), spacing: 14)],
                            spacing: 14
                        ) {
                            ForEach(allCategories, id: \.self) { category in
                                ChipButton(
                                    label: category,
                                    isSelected: selectedCategories.contains(category),
                                    selectedColor: chipColor(for: moodLevel)
                                ) {
                                    toggleCategory(category)
                                }
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                    .padding(.bottom, 24)
                }
                .scrollContentBackground(.hidden)

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
        }
    }

    // MARK: - Helpers

    private func toggleCategory(_ category: String) {
        if selectedCategories.contains(category) {
            selectedCategories.removeAll { $0 == category }
        } else {
            selectedCategories.append(category)
        }
    }
}

#Preview {
    ImpactCategoriesView(
        moodLevel: .neutral,
        selectedCategories: .constant(["Faith", "Health"]),
        onNext: {},
        onBack: {}
    )
}
