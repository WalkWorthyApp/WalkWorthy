//
//  AIConsentView.swift
//  WalkWorthy
//
//  One-time AI data-sharing consent, required by App Review Guideline
//  5.1.2(i): personal data shared with a third-party AI (OpenAI) needs
//  explicit, in-app consent naming the provider — a privacy-policy link
//  alone is not sufficient. Shown as the first step of the user's first
//  mood check-in (see MoodCheckInView); declining returns without any
//  AI call. Also carries the mental-health disclaimer (Guideline 1.4).
//
//  It is also WalkWorthy's own sensitive-data consent: check-ins can reveal
//  mental health and religious beliefs, which Connecticut's privacy law (and
//  similar state laws) only allow processing with opt-in consent — accepting
//  the Terms at sign-in does not count. Changing this wording requires
//  bumping the notice version (backend `NOTICE_VERSION`) so users re-consent.
//

import SwiftUI

struct AIConsentView: View {
    @EnvironmentObject private var appState: AppState

    @State private var ageGroup = ""

    let onContinue: () -> Void
    let onDecline: () -> Void

    var body: some View {
        ZStack {
            TimeOfDayTheme.current.backdrop
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: scaled(20)) {
                    Text("Your check-ins and AI")
                        .font(.newsreaderSemiBoldItalic(size: scaled(30)))
                        .foregroundStyle(.white)
                        .padding(.top, scaled(24))
                        .accessibilityAddTraits(.isHeader)

                    VStack(alignment: .leading, spacing: scaled(14)) {
                        Label {
                            Text("WalkWorthy saves each check-in (everything listed below), daily mood summaries and the responses written for you to your private account, so you can see your history. Life areas can include faith, so this can reveal your mental health and religious beliefs.")
                        } icon: {
                            Image(systemName: "lock.shield")
                        }

                        Label {
                            Text("**OpenAI** writes your encouragement and daily reflection and screens text for safety. With AI sharing on, it receives:")
                        } icon: {
                            Image(systemName: "sparkles")
                        }

                        VStack(alignment: .leading, spacing: scaled(6)) {
                            bulletRow("Mood score and level, follow-up rating, emotions, life areas and check-in period")
                            bulletRow("Your note, if you write one (leave out names and contact details)")
                            bulletRow("For daily reflections, a seven-day summary of dates, moods and overall sentiment")
                        }

                        // HIG (Generative AI → Transparency): "Set clear
                        // expectations about what your AI-powered feature can
                        // and can't do." Every Scripture quotation comes from a
                        // reviewed server-side catalog, so the passage itself is
                        // never model-written — only the surrounding words are.
                        Text("OpenAI says it doesn't train on this data and may keep safety logs for up to 30 days, or longer if the law requires. AI can get things wrong; Scripture comes from a fixed ESV list, never from AI.")
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .glassCard()

                    // A one-option picker is not a control. With WalkWorthy
                    // adults-only, this is a single affirmative declaration,
                    // so a Toggle states it plainly and leaves "Agree and
                    // continue" disabled until it is switched on.
                    Toggle(isOn: Binding(
                        get: { ageGroup == "18+" },
                        set: { ageGroup = $0 ? "18+" : "" }
                    )) {
                        Text("I am 18 or older").fontWeight(.semibold)
                    }
                    .accessibilityHint("Required. WalkWorthy is available only to adults.")
                    .glassCard()

                    Label("Scripture-based encouragement, not medical or mental-health care. If you're struggling, talk to a professional or, in the U.S., call or text 988.", systemImage: "heart.text.square")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.85))
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

                    Text("By agreeing, you let WalkWorthy store and use your check-ins as described above and share the items listed with OpenAI. You can turn off OpenAI sharing in Settings; deleting your account removes your check-ins.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, scaled(4))

                    VStack(spacing: scaled(12)) {
                        if let error = appState.aiConsentError {
                            Text(error).font(.footnote).accessibilityLabel(error)
                            Button("Retry connection") { appState.retryAIConsent() }
                                .disabled(appState.aiConsentBusy)
                        }
                        Button {
                            Task {
                                if await appState.grantAIConsent(ageGroup: ageGroup) { onContinue() }
                            }
                        } label: {
                            Text(appState.aiConsentBusy ? "Saving permission…" : "Agree and continue")
                                .fontWeight(.semibold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, scaled(14))
                                .background(Color.white, in: Capsule())
                                .foregroundStyle(.black)
                        }
                        .disabled(ageGroup.isEmpty || appState.aiConsentBusy)
                        .accessibilityHint("Agrees to WalkWorthy storing your check-ins and sharing check-in data with OpenAI for generation and safety screening")

                        Button {
                            if appState.aiConsentBusy { appState.withdrawAIConsent() }
                            onDecline()
                        } label: {
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
