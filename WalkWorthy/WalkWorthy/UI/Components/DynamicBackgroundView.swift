//
//  DynamicBackgroundView.swift
//  WalkWorthy
//
//  Full-screen background: time-of-day hero image pinned to the top,
//  fading into the time-of-day backdrop gradient below. Drop this as
//  the bottom layer of any screen's ZStack.
//

import SwiftUI

struct DynamicBackgroundView: View {
    private let theme = TimeOfDayTheme.current

    var body: some View {
        ZStack(alignment: .top) {
            theme.backdrop
                .ignoresSafeArea()

            Image(theme.timeOfDay.imageName)
                .resizable()
                .scaledToFill()
                .frame(height: scaled(280))
                .clipped()
                .overlay(
                    LinearGradient(
                        stops: gradientStops,
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .ignoresSafeArea(edges: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var gradientStops: [Gradient.Stop] {
        let fade = theme.heroFadeTarget
        return [
            .init(color: .clear, location: 0.10),
            .init(color: fade.opacity(0.4), location: 0.55),
            .init(color: fade, location: 1.0)
        ]
    }
}

#Preview {
    DynamicBackgroundView()
}
