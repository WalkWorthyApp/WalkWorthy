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

    /// Tracks the last snap point for haptic feedback
    @State private var lastSnapIndex: Int = -1

    var body: some View {
        ZStack {
            MoodWeatherBackground(moodScore: sliderValue)

            VStack {
                Spacer()

                // Current mood level label
                Text(currentMoodLevel.displayName)
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(.white)
                    .animation(.easeInOut, value: sliderValue)
                    .padding(.bottom, 16)

                // Mood slider
                Slider(value: $sliderValue, in: 0...1)
                    .accentColor(.white)
                    .padding(.horizontal, 24)
                    .onChange(of: sliderValue) { _ in
                        checkHapticSnap()
                    }

                // Range labels
                HStack {
                    Text("Very Unpleasant")
                    Spacer()
                    Text("Very Pleasant")
                }
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 24)
                .padding(.top, 4)

                // Next button
                Button(action: onNext) {
                    Text("Next \u{2192}")
                        .font(.headline)
                        .foregroundColor(.black.opacity(0.85))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.white)
                        .cornerRadius(30)
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 40)
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
    MoodSliderView(sliderValue: .constant(0.5), onNext: {})
}
