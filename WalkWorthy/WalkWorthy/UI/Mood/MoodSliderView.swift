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
            .padding(.horizontal, scaled(20))
            .padding(.top, scaled(20))

            VStack {
                Spacer()

                // Current mood level label
                Text(currentMoodLevel.displayName)
                    .font(.newsreaderSemiBoldItalic(fixedSize: scaled(36)))
                    .foregroundColor(.white)
                    .animation(.easeInOut, value: sliderValue)
                    .padding(.bottom, scaled(16))

                // Mood slider
                Slider(value: $sliderValue, in: 0...1)
                    .accentColor(.white)
                    .padding(.horizontal, scaled(24))
                    .onChange(of: sliderValue) {
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
                .padding(.horizontal, scaled(24))
                .padding(.top, scaled(4))

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
                .padding(.horizontal, scaled(24))
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
