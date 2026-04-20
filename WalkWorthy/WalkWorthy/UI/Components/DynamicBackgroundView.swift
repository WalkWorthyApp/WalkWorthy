//
//  DynamicBackgroundView.swift
//  WalkWorthy
//
//  Full-screen background: time-of-day hero image pinned to the top,
//  fading into AppBackground below. Drop this as the bottom layer
//  of any screen's ZStack.
//

import SwiftUI

struct DynamicBackgroundView: View {
    private let timeOfDay = TimeOfDay.current
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .top) {
            Color("AppBackground")
                .ignoresSafeArea()

            Image(timeOfDay.imageName)
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
        let appBg = Color("AppBackground")
        if colorScheme == .dark {
            return [
                .init(color: .clear, location: 0.10),
                .init(color: appBg.opacity(0.4), location: 0.55),
                .init(color: appBg, location: 1.0)
            ]
        } else {
            return [
                .init(color: .clear, location: 0.10),
                .init(color: appBg.opacity(0.2), location: 0.65),
                .init(color: appBg, location: 1.0)
            ]
        }
    }
}

#Preview {
    DynamicBackgroundView()
}
