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

    @State private var showMessage = false
    @State private var showVerse = false
    @State private var showVerseReference = false
    @State private var showVerseText = false
    @State private var showShareButton = false
    @State private var verseGlowOpacity: Double = 0
    @State private var showDoneButton = false

    var body: some View {
        VStack(spacing: 24) {
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
                            active: VerseCardTransitionModifier(scale: 0.92, yOffset: 30, opacity: 0),
                            identity: VerseCardTransitionModifier(scale: 1, yOffset: 0, opacity: 1)
                        ),
                        removal: .opacity
                    ))
            }

            Spacer(minLength: 40)

            if showDoneButton {
                doneButton
                    .transition(.asymmetric(
                        insertion: .modifier(
                            active: SlideUpTransitionModifier(yOffset: 40, opacity: 0),
                            identity: SlideUpTransitionModifier(yOffset: 0, opacity: 1)
                        ),
                        removal: .opacity
                    ))
            }
        }
        .onAppear { animateContentSequence() }
    }

    // MARK: - Subviews

    private var messageBubble: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(LinearGradient(
                    colors: [Color.accentColor, Color.accentColor.opacity(0.7)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
                .frame(width: 40, height: 40)
                .overlay(
                    Image(systemName: "heart.fill")
                        .foregroundColor(.white)
                        .font(.system(size: 18))
                        .accessibilityHidden(true)
                )
                .accessibilityLabel("WalkWorthy assistant")

            VStack(alignment: .leading, spacing: 4) {
                Text("WalkWorthy")
                    .font(.newsreaderSemiBoldItalic(fixedSize: 13))
                    .foregroundColor(.secondary)

                Text(response.aiResponse.message)
                    .font(.body)
                    .foregroundColor(.primary)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.white.opacity(0.92))
                    )
            }

            Spacer()
        }
    }

    private var verseCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(response.aiResponse.verseRef)
                    .font(.newsreaderSemiBoldItalic(fixedSize: 17))
                    .foregroundColor(.accentColor)

                Spacer()

                Text(response.aiResponse.translation)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor))
            }
            .opacity(showVerseReference ? 1 : 0)
            .offset(y: showVerseReference ? 0 : 8)

            Text(response.aiResponse.verseText)
                .font(.newsreader(fixedSize: 17))
                .foregroundColor(.primary)
                .lineSpacing(4)
                .opacity(showVerseText ? 1 : 0)
                .offset(y: showVerseText ? 0 : 12)

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
            .offset(y: showShareButton ? 0 : 6)
        }
        .padding(20)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.white.opacity(0.92))

                RoundedRectangle(cornerRadius: 20)
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
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.accentColor.opacity(verseGlowOpacity * 0.15))
                .blur(radius: 20)
                .offset(y: 4)
        )
        .shadow(color: .black.opacity(0.08), radius: 10, y: 5)
        .overlay(
            RoundedRectangle(cornerRadius: 20)
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
                .padding(.vertical, 16)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.accentColor))
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
    let moodLevel: MoodLevel?
    let onDismiss: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                MoodResponseContent(response: response, onDismiss: onDismiss)
            }
            .padding()
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
