//
//  ConfigurationErrorView.swift
//  WalkWorthy
//
//  Shown when app startup failed to load a valid configuration
//  (missing API base URL, SwiftData store creation failed, etc.).
//  Blocks all other UI via `RootView` so the user can reach support.
//

import SwiftUI

struct ConfigurationErrorView: View {
    let message: String

    private static let supportEmail = "walkworthyofficial@gmail.com"

    private var supportURL: URL? {
        URL(string: "mailto:\(Self.supportEmail)")
    }

    var body: some View {
        ZStack {
            Color(.systemBackground)
                .ignoresSafeArea()

            VStack(spacing: scaled(20)) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: scaled(56), weight: .semibold))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)

                Text("Something went wrong")
                    .font(.newsreaderSemiBoldItalic(fixedSize: scaled(26)))
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                if let supportURL {
                    VStack(spacing: scaled(8)) {
                        Link(destination: supportURL) {
                            Text("Contact Support")
                                .font(.headline)
                                .foregroundStyle(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, scaled(14))
                                .background(
                                    LinearGradient(
                                        colors: [Color.accentColor.opacity(0.85), Color.accentColor],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    ),
                                    in: RoundedRectangle(cornerRadius: scaled(16), style: .continuous)
                                )
                        }
                        .accessibilityLabel(Text("Contact Support"))
                        .accessibilityHint(Text("Opens your email app to contact WalkWorthy support"))

                        // Fallback for users with no default mail client configured
                        // (simulator, some iPads, Gmail-only users). Long-press → Copy.
                        Text(Self.supportEmail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .accessibilityLabel(Text("Support email address: \(Self.supportEmail)"))
                            .accessibilityHint(Text("Long press to copy"))
                    }
                    .padding(.top, scaled(8))
                }
            }
            .padding(.horizontal, scaled(28))
            .padding(.vertical, scaled(24))
            .frame(maxWidth: scaled(420))
        }
    }
}

#Preview {
    ConfigurationErrorView(message: "Unable to load configuration. Please reinstall the app or contact support.")
}
