//
//  MoodResponseView.swift
//  WalkWorthy
//
//  Displays the AI encouragement response in a chat-like format.
//

import SwiftUI

struct MoodResponseView: View {
    let response: MoodCheckInResponse
    let moodLevel: MoodLevel?
    let onDismiss: () -> Void

    @State private var showVerse = false
    @State private var showMessage = false

    // Staggered verse card content animations
    @State private var showVerseReference = false
    @State private var showVerseText = false
    @State private var showShareButton = false
    @State private var verseGlowOpacity: Double = 0

    // Done button animation state
    @State private var showDoneButton = false

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Header
                headerSection

                // AI Message bubble
                if showMessage {
                    messageBubble
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.8).combined(with: .opacity),
                            removal: .opacity
                        ))
                }

                // Verse card with enhanced animation
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

                // Done button with slide-up animation
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
            .padding()
        }
        .onAppear {
            animateContentSequence()
        }
    }

    // MARK: - Animation Orchestration

    private func animateContentSequence() {
        // Step 1: Show message bubble with gentle spring
        withAnimation(.spring(response: 0.6, dampingFraction: 0.75).delay(0.2)) {
            showMessage = true
        }

        // Step 2: Reveal verse card with softer, more natural timing
        withAnimation(.spring(response: 0.8, dampingFraction: 0.72).delay(0.8)) {
            showVerse = true
        }

        // Step 3: Stagger the verse card's internal content
        withAnimation(.easeOut(duration: 0.5).delay(1.1)) {
            showVerseReference = true
        }

        withAnimation(.easeOut(duration: 0.6).delay(1.3)) {
            showVerseText = true
        }

        withAnimation(.easeOut(duration: 0.4).delay(1.6)) {
            showShareButton = true
        }

        // Step 4: Done button slides up from bottom
        withAnimation(.spring(response: 0.6, dampingFraction: 0.8).delay(1.9)) {
            showDoneButton = true
        }

        // Step 5: Subtle glow pulse to draw attention
        withAnimation(.easeInOut(duration: 1.2).delay(1.0)) {
            verseGlowOpacity = 0.4
        }
        // Fade glow back down
        withAnimation(.easeInOut(duration: 1.5).delay(2.2)) {
            verseGlowOpacity = 0
        }
    }

    private var headerSection: some View {
        VStack(spacing: 12) {
            if let level = moodLevel {
                MoodWeatherBackground(moodScore: moodLevelToScore(level), isCompact: true)
                    .frame(width: 80, height: 80)

                Text("You're feeling \(level.displayName.lowercased())")
                    .font(.headline)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.top, 20)
    }

    private var messageBubble: some View {
        HStack(alignment: .top, spacing: 12) {
            // Avatar
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

            // Message
            VStack(alignment: .leading, spacing: 4) {
                Text("WalkWorthy")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)

                Text(response.aiResponse.message)
                    .font(.body)
                    .foregroundColor(.primary)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color(.systemGray6))
                    )
            }

            Spacer()
        }
    }

    private var verseCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Verse reference - animated in first
            HStack {
                Text(response.aiResponse.verseRef)
                    .font(.headline)
                    .foregroundColor(.accentColor)

                Spacer()

                Text(response.aiResponse.translation)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(Color.accentColor)
                    )
            }
            .opacity(showVerseReference ? 1 : 0)
            .offset(y: showVerseReference ? 0 : 8)

            // Verse text - animated in second
            Text(response.aiResponse.verseText)
                .font(.body)
                .italic()
                .foregroundColor(.primary)
                .lineSpacing(4)
                .opacity(showVerseText ? 1 : 0)
                .offset(y: showVerseText ? 0 : 12)

            // Share button - animated in last
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
                // Base background
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(.systemBackground))

                // Animated glow layer
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
            // Outer glow shadow
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.accentColor.opacity(verseGlowOpacity * 0.15))
                .blur(radius: 20)
                .offset(y: 4)
        )
        .shadow(color: .black.opacity(0.1), radius: 10, y: 5)
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
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.accentColor)
                )
                .foregroundColor(.white)
        }
    }
}

// MARK: - Custom Transition Modifiers

/// A ViewModifier that creates a smooth entrance animation with scale, offset, and opacity
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

/// A ViewModifier for slide-up entrance animations (used by Done button)
private struct SlideUpTransitionModifier: ViewModifier {
    let yOffset: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .offset(y: yOffset)
            .opacity(opacity)
    }
}
