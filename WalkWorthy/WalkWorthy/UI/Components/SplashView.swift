//
//  SplashView.swift
//  WalkWorthy
//
//  Instagram-style branded splash: the full-bleed `LaunchSplash` asset,
//  whose asset catalog provides light + dark variants picked by
//  `\Environment.colorScheme`.
//
//  The initial color scheme is captured at first render and applied
//  via `.environment(\.colorScheme, locked)` to the image subtree. This
//  prevents a mid-transition variant swap: when `RootView` flips its
//  `.preferredColorScheme` from `nil` → `.dark` as `isCheckingAuth`
//  resolves, the parent environment's scheme changes, but the splash
//  keeps rendering the variant it started with until it fades out.
//

import SwiftUI

struct SplashView: View {
    @Environment(\.colorScheme) private var environmentScheme
    @State private var lockedScheme: ColorScheme?

    var body: some View {
        Image("LaunchSplash")
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .ignoresSafeArea()
            .environment(\.colorScheme, lockedScheme ?? environmentScheme)
            .onAppear {
                if lockedScheme == nil {
                    lockedScheme = environmentScheme
                }
            }
    }
}
