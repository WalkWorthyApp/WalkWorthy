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

    var body: some View {
        ZStack(alignment: .top) {
            Color("AppBackground")
                .ignoresSafeArea()

            Image(timeOfDay.imageName)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .overlay(
                    LinearGradient(
                        colors: [.clear, Color("AppBackground")],
                        startPoint: UnitPoint(x: 0.5, y: 0.55), // fade begins 55% down the screen
                        endPoint: .bottom
                    )
                )
                .ignoresSafeArea(edges: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    DynamicBackgroundView()
}
