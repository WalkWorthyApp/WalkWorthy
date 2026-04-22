//
//  SplashView.swift
//  WalkWorthy
//
//  Instagram-style branded splash: the full-bleed `LaunchSplash` asset
//  (light + dark variants, picked by the asset catalog based on the
//  device's color scheme since `RootView` passes `nil` to
//  `preferredColorScheme` during `isCheckingAuth`).
//
//  Shown only during cold-start auth resolution. `AppState` unblocks
//  `isCheckingAuth` as soon as the auth state is known, so this covers
//  the brief window between the system `UILaunchScreen` and the main UI
//  — users see the same branded composition start-to-finish instead of
//  a flat color flash.
//

import SwiftUI

struct SplashView: View {
    var body: some View {
        Image("LaunchSplash")
            .resizable()
            .scaledToFill()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .ignoresSafeArea()
    }
}
