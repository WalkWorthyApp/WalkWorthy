//
//  MoodSliderView.swift
//  WalkWorthy
//
//  Step 1 of the mood check-in wizard: full-screen weather background
//  with a slider to pick mood level.
//

import SwiftUI
import UIKit

struct MoodSliderView: View {
    @Binding var sliderValue: Double   // 0.0–1.0
    let onNext: () -> Void
    let onBack: () -> Void

    /// Tracks the last snap point for haptic feedback
    @State private var lastSnapIndex: Int = -1

    var body: some View {
        ZStack(alignment: .topLeading) {
            MoodWeatherBackground(moodScore: sliderValue)

            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white)
            }
            .accessibilityLabel("Back")
            .padding(.horizontal, scaled(20))
            .padding(.top, scaled(20))

            VStack {
                Spacer()

                // Current mood level label
                Text(currentMoodLevel.displayName)
                    .font(.newsreaderSemiBoldItalic(size: scaled(36)))
                    .foregroundColor(.white)
                    .animation(.easeInOut, value: sliderValue)
                    .padding(.bottom, scaled(16))

                // Mood slider — width-capped so the bar reads as a compact
                // control instead of spanning edge to edge; range labels
                // shrink with it since they describe the track's ends.
                VStack(spacing: 0) {
                    Slider(value: $sliderValue, in: 0...1)
                        .accentColor(.white)
                        .onChange(of: sliderValue) {
                            checkHapticSnap()
                        }
                        .accessibilityLabel("Mood level")
                        .accessibilityValue(currentMoodLevel.displayName)

                    HStack {
                        Text("Very Unpleasant")
                        Spacer()
                        Text("Very Pleasant")
                    }
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.8))
                    .padding(.top, scaled(4))
                }
                .frame(maxWidth: scaled(300))
                .padding(.horizontal, scaled(12))

                // Next button
                Button(action: onNext) {
                    Text("Next \u{2192}")
                        .font(.headline)
                        .foregroundColor(.black.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, scaled(14))
                        .background(Color.white)
                        .cornerRadius(scaled(30))
                }
                .padding(.horizontal, scaled(12))
                .padding(.top, scaled(24))
                .padding(.bottom, scaled(40))
            }
        }
    }

    // MARK: - Helpers

    private var currentMoodLevel: MoodLevel {
        MoodLevel.from(score: Int(sliderValue * 9) + 1)
    }

    /// Fires haptic feedback when the slider crosses one of the 5 snap points.
    private func checkHapticSnap() {
        let snapPoints: [Double] = [0.0, 0.25, 0.5, 0.75, 1.0]
        let threshold = 0.03

        for (index, snap) in snapPoints.enumerated() {
            if abs(sliderValue - snap) < threshold && index != lastSnapIndex {
                lastSnapIndex = index
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.impactOccurred()
                return
            }
        }
    }
}

#Preview {
    MoodSliderView(sliderValue: .constant(0.5), onNext: {}, onBack: {})
}
