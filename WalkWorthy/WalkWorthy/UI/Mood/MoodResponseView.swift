//
//  MoodResponseView.swift
//  WalkWorthy
//
//  MoodResponseContent — reusable card content (message bubble + verse card
//  + done button) with staggered spring animations. Used standalone via
//  MoodResponseView and as an overlay inside CinematicTransitionView.
//

import SwiftUI

// MARK: - Response Content (reusable overlay)

/// Card content only — no ScrollView or background. Used by both
/// MoodResponseView and CinematicTransitionView.
struct MoodResponseContent: View {
    let response: MoodCheckInResponse
    let onDismiss: () -> Void
    /// Optional so read-only presentations (history, the standalone wrapper)
    /// show no retry affordance — retrying only makes sense in the flow that
    /// just produced the encouragement.
    var onRetry: (() -> Void)?
    var isRetrying: Bool = false
    var retryErrorMessage: String?

    @State private var showMessage = false
    @State private var showVerse = false
    @State private var showVerseReference = false
    @State private var showVerseText = false
    @State private var showShareButton = false
    @State private var verseGlowOpacity: Double = 0
    @State private var showDoneButton = false

    var body: some View {
        VStack(spacing: scaled(24)) {
            if showMessage {
                messageBubble
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.8).combined(with: .opacity),
                        removal: .opacity
                    ))
            }

            if showVerse {
                verseCard
                    .transition(.asymmetric(
                        insertion: .modifier(
                            active: VerseCardTransitionModifier(scale: 0.92, yOffset: scaled(30), opacity: 0),
                            identity: VerseCardTransitionModifier(scale: 1, yOffset: 0, opacity: 1)
                        ),
                        removal: .opacity
                    ))
            }

            if showVerse, let resource = response.aiResponse.supportResource {
                supportResourceCard(resource)
                    .transition(.opacity)
            }

            Spacer(minLength: scaled(40))

            if showDoneButton {
                doneButton
                    .transition(.asymmetric(
                        insertion: .modifier(
                            active: SlideUpTransitionModifier(yOffset: scaled(40), opacity: 0),
                            identity: SlideUpTransitionModifier(yOffset: 0, opacity: 1)
                        ),
                        removal: .opacity
                    ))
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear { animateContentSequence() }
    }

    // MARK: - Subviews

    private var messageBubble: some View {
        HStack(alignment: .top, spacing: scaled(12)) {
            Circle()
                .fill(LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: scaled(40), height: scaled(40))
                .overlay(
                    Image(systemName: "heart.fill")
                        .foregroundColor(.white)
                        .font(.system(size: scaled(18)))
                        .accessibilityHidden(true)
                )
                .accessibilityLabel("WalkWorthy assistant")

            VStack(alignment: .leading, spacing: scaled(4)) {
                HStack(spacing: scaled(6)) {
                    Text("WalkWorthy")
                        .font(Font.newsreaderSemiBoldItalic(size: scaled(13)))
                        .foregroundColor(.accentColor)
                    if response.aiResponse.isModelGenerated {
                        AIGeneratedBadge()
                    }
                }

                Text(response.aiResponse.message)
                    .font(.body)
                    .foregroundColor(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(scaled(12))
                    .background(
                        RoundedRectangle(cornerRadius: scaled(16))
                            .fill(Color.wwCardBackground)
                    )

                // Both of these are true only of model output. A fixed
                // fallback is human-written (so the caveat would be false) and
                // deterministic (so retry would return the identical string
                // while still spending a daily budget slot).
                if response.aiResponse.isModelGenerated {
                    // HIG (Generative AI → Inputs): "it's important to clearly
                    // communicate that AI-generated content may contain
                    // errors." The badge names the source; this names the
                    // limitation.
                    Text("This is written by AI and can get things wrong.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let onRetry {
                        retryControl(onRetry)
                            .padding(.top, scaled(2))
                    }
                }

                if let retryErrorMessage {
                    Text(retryErrorMessage)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// HIG (Generative AI → Outputs): "surfacing controls like Edit, Undo,
    /// Retry, or Adjust near generated content preserves people's agency."
    /// Regeneration is a real backend call, so it consumes the same daily AI
    /// budget as the first generation — a spent budget surfaces as an ordinary
    /// usage-limit message rather than a silent no-op.
    @ViewBuilder
    private func retryControl(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: scaled(5)) {
                if isRetrying {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
                Text(isRetrying ? "Writing a new one…" : "Try a different encouragement")
            }
            .font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .disabled(isRetrying)
        .accessibilityHint("Replaces this encouragement with a newly generated one")
    }

    /// Renders an offered help resource. Nothing here dials or contacts
    /// anyone on its own — the user taps if they want it.
    @ViewBuilder
    private func supportResourceCard(_ resource: SupportResource) -> some View {
        VStack(alignment: .leading, spacing: scaled(10)) {
            Label(resource.title, systemImage: "lifepreserver.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.accentColor)

            Text(resource.body)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: scaled(12)) {
                if let phone = resource.phone,
                   let callURL = URL(string: "tel://\(phone)") {
                    Link(destination: callURL) {
                        Label("Call \(phone)", systemImage: "phone.fill")
                            .font(.footnote.weight(.semibold))
                    }
                }

                if let phone = resource.phone,
                   let textURL = URL(string: "sms:\(phone)") {
                    Link(destination: textURL) {
                        Label("Text \(phone)", systemImage: "message.fill")
                            .font(.footnote.weight(.semibold))
                    }
                }

                if let urlString = resource.url,
                   let webURL = URL(string: urlString) {
                    Link(destination: webURL) {
                        Label("Learn more", systemImage: "arrow.up.right")
                            .font(.footnote.weight(.semibold))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(scaled(16))
        .background(
            RoundedRectangle(cornerRadius: scaled(16))
                .fill(Color.wwCardBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: scaled(16))
                .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(resource.title). \(resource.body)"))
    }

    private var verseCard: some View {
        VStack(alignment: .leading, spacing: scaled(16)) {
            HStack {
                Text(response.aiResponse.verseRef)
                    .font(Font.newsreaderSemiBoldItalic(size: scaled(17)))
                    .foregroundColor(.accentColor)

                Spacer()

                Text(response.aiResponse.translation)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .padding(.horizontal, scaled(8))
                    .padding(.vertical, scaled(4))
                    .background(Capsule().fill(Color.accentColor))
            }
            .opacity(showVerseReference ? 1 : 0)
            .offset(y: showVerseReference ? 0 : scaled(8))

            Text(response.aiResponse.verseText)
                .font(Font.newsreader(size: scaled(17)))
                .foregroundColor(.primary)
                .lineSpacing(scaled(4))
                .opacity(showVerseText ? 1 : 0)
                .offset(y: showVerseText ? 0 : scaled(12))

            HStack {
                Spacer()
                ShareLink(
                    item: "\"\(response.aiResponse.verseText)\"\n\n- \(response.aiResponse.verseRef) (\(response.aiResponse.translation))\n\nShared from WalkWorthy"
                ) {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .font(.subheadline)
                        .foregroundColor(.accentColor)
                }
            }
            .opacity(showShareButton ? 1 : 0)
            .offset(y: showShareButton ? 0 : scaled(6))
        }
        .padding(scaled(20))
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: scaled(20))
                    .fill(Color.wwCardBackground)

                RoundedRectangle(cornerRadius: scaled(20))
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.accentColor.opacity(verseGlowOpacity * 0.3),
                                Color.accentColor.opacity(verseGlowOpacity * 0.1),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        )
        .background(
            RoundedRectangle(cornerRadius: scaled(20))
                .fill(Color.accentColor.opacity(verseGlowOpacity * 0.15))
                .blur(radius: scaled(20))
                .offset(y: scaled(4))
        )
        .shadow(color: .black.opacity(0.08), radius: scaled(10), y: scaled(5))
        .overlay(
            RoundedRectangle(cornerRadius: scaled(20))
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.2 + verseGlowOpacity * 0.3),
                            Color.accentColor.opacity(0.1 + verseGlowOpacity * 0.2)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }

    private var doneButton: some View {
        Button(action: onDismiss) {
            Text("Done")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, scaled(16))
                .background(RoundedRectangle(cornerRadius: scaled(14)).fill(Color.accentColor))
                .foregroundColor(.white)
        }
    }

    // MARK: - Animation

    private func animateContentSequence() {
        withAnimation(.spring(response: 0.6, dampingFraction: 0.75).delay(0.2)) {
            showMessage = true
        }
        withAnimation(.spring(response: 0.8, dampingFraction: 0.72).delay(0.8)) {
            showVerse = true
        }
        withAnimation(.easeOut(duration: 0.5).delay(1.1)) {
            showVerseReference = true
        }
        withAnimation(.easeOut(duration: 0.6).delay(1.3)) {
            showVerseText = true
        }
        withAnimation(.easeOut(duration: 0.4).delay(1.6)) {
            showShareButton = true
        }
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(1.9)) {
            showDoneButton = true
        }
        withAnimation(.easeInOut(duration: 1.2).delay(1.0)) {
            verseGlowOpacity = 0.4
        }
        withAnimation(.easeInOut(duration: 1.5).delay(2.2)) {
            verseGlowOpacity = 0
        }
    }
}

// MARK: - Standalone wrapper (preserves existing usage)

struct MoodResponseView: View {
    let response: MoodCheckInResponse
    let onDismiss: () -> Void

    var body: some View {
        ScrollView {
            MoodResponseContent(response: response, onDismiss: onDismiss)
                .padding(.vertical).padding(.horizontal, scaled(8))
        }
    }
}

// MARK: - Custom Transition Modifiers

private struct VerseCardTransitionModifier: ViewModifier {
    let scale: CGFloat
    let yOffset: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .offset(y: yOffset)
            .opacity(opacity)
    }
}

private struct SlideUpTransitionModifier: ViewModifier {
    let yOffset: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .offset(y: yOffset)
            .opacity(opacity)
    }
}


/// The "AI-generated" marker. Shared so every surface that displays model
/// output labels it identically — HIG (Generative AI → Transparency):
/// "Communicate where your app uses AI... Never trick someone into thinking
/// they're interacting with or viewing content authored by a human if they're
/// actually interacting with AI."
struct AIGeneratedBadge: View {
    var body: some View {
        Text("AI-generated")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }
}
