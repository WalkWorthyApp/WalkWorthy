//
//  AIConsentView.swift
//  WalkWorthy
//
//  One-time AI data-sharing consent, required by App Review Guideline
//  5.1.2(i): personal data shared with a third-party AI (OpenAI) needs
//  explicit, in-app consent naming the provider — a privacy-policy link
//  alone is not sufficient. Shown as the first step of the user's first
//  mood check-in (see MoodCheckInView); declining returns without any
//  AI call. Also carries the analytics disclosure and the mental-health
//  disclaimer (Guideline 1.4).
//

import SwiftUI

struct AIConsentView: View {
    @EnvironmentObject private var appState: AppState

    let onContinue: () -> Void
    let onDecline: () -> Void

    var body: some View {
        ZStack {
            TimeOfDayTheme.current.backdrop
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: scaled(20)) {
                    Text("Before your first check-in")
                        .font(.newsreaderSemiBoldItalic(size: scaled(30)))
                        .foregroundStyle(.white)
                        .padding(.top, scaled(24))
                        .accessibilityAddTraits(.isHeader)

                    VStack(alignment: .leading, spacing: scaled(14)) {
                        Label {
                            Text("WalkWorthy uses **OpenAI** to write your encouragement and daily reflection.")
                        } icon: {
                            Image(systemName: "sparkles")
                        }

                        Text("When AI sharing is on, we send OpenAI:")
                            .fontWeight(.semibold)

                        VStack(alignment: .leading, spacing: scaled(6)) {
                            bulletRow("Your mood score and level, follow-up rating, emotion tags, and check-in period")
                            bulletRow("The life areas you select")
                            bulletRow("Your optional note, if you write one")
                            bulletRow("For daily reflections: a seven-day summary of check-in dates, mood levels, and overall sentiment")
                            bulletRow("If personalization is on: your age range, occupation or major, and hobbies — never your name or gender")
                        }

                        Text("OpenAI processes this information to generate a response. WalkWorthy disables API response storage and AI tracing, and OpenAI says API data is not used to train its models unless a customer opts in. Your generated responses are saved in your WalkWorthy account.")
                            .foregroundStyle(.white.opacity(0.85))

                        // HIG (Generative AI → Transparency): "Set clear
                        // expectations about what your AI-powered feature can
                        // and can't do." Every Scripture quotation comes from a
                        // reviewed server-side catalog, so the passage itself is
                        // never model-written — only the surrounding words are.
                        Text("What to expect: the encouragement is written by AI, so it can be off or occasionally get something wrong — you can ask for a different one any time. Scripture quotations are not written by AI; they come from a reviewed ESV list. This is general spiritual encouragement, not medical or mental-health care.")
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .glassCard()

                    VStack(alignment: .leading, spacing: scaled(10)) {
                        Toggle(isOn: Binding(
                            get: { appState.analyticsEnabled },
                            set: { appState.setAnalyticsEnabled($0) }
                        )) {
                            Text("Share app usage analytics")
                                .fontWeight(.semibold)
                        }
                        Text("Optional and off by default. Firebase Analytics uses an app-instance identifier to count feature use, but never receives your check-ins, notes, or profile details. You can change this anytime in Settings.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .glassCard()

                    VStack(alignment: .leading, spacing: scaled(8)) {
                        Label("A gentle reminder", systemImage: "heart.text.square")
                            .fontWeight(.semibold)
                        Text("WalkWorthy offers Scripture-based encouragement, not medical or mental-health care. If you're struggling, please talk to a professional — in the U.S., you can call or text 988 anytime.")
                            .font(.footnote)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .glassCard()

                    Link(destination: URL(string: "https://walkworthy-app.web.app/privacy")!) {
                        Text("Read the full Privacy Policy")
                            .font(.footnote)
                            .underline()
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .padding(.horizontal, scaled(4))

                    Link(destination: URL(string: "https://walkworthy-app.web.app/health-data")!) {
                        Text("Read the Consumer Health Data Policy")
                            .font(.footnote)
                            .underline()
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .padding(.horizontal, scaled(4))

                    VStack(spacing: scaled(12)) {
                        Button(action: onContinue) {
                            Text("Continue")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, scaled(14))
                                .background(Color.white, in: Capsule())
                                .foregroundStyle(.black)
                        }
                        .accessibilityHint("Agrees to share check-in data with OpenAI to generate encouragement")

                        Button(action: onDecline) {
                            Text("Not now")
                                .fontWeight(.medium)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, scaled(10))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                        .accessibilityHint("Returns without sharing anything or generating encouragement")
                    }
                    .padding(.top, scaled(4))
                    .padding(.bottom, scaled(32))
                }
                .padding(.horizontal, scaled(24))
                .foregroundStyle(.white)
            }
        }
    }

    private func bulletRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: scaled(8)) {
            Text("•")
            Text(text)
        }
        .font(.subheadline)
        .foregroundStyle(.white.opacity(0.9))
    }
}
