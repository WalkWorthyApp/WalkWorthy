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

            // The fill image lives in an overlay so its cropped-off width never
            // leaks into layout: a bare `.scaledToFill().frame(height:)` reports
            // width = height × aspect (wider than the screen), which inflates
            // the enclosing ZStack and pushes trailing-aligned siblings —
            // like Journal's compose button — off the screen edge.
            Color.clear
                .frame(height: scaled(280))
                .overlay(
                    Image(theme.timeOfDay.imageName)
                        .resizable()
                        .scaledToFill()
                )
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
