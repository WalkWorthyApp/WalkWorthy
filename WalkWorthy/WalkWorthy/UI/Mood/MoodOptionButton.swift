//
//  MoodOptionButton.swift
//  WalkWorthy
//
//  Animated mood selection button with emoji and label.
//

import SwiftUI

struct MoodOptionButton: View {
    let mood: MoodOption
    let isSelected: Bool
    let action: () -> Void

    @State private var isPressed = false
    private let impactFeedback = UIImpactFeedbackGenerator(style: .medium)

    var body: some View {
        VStack(spacing: 8) {
            Text(mood.emoji)
                .font(.system(size: 36))
                .scaleEffect(isSelected ? 1.1 : 1.0)

            Text(mood.displayName)
                .font(.subheadline)
                .fontWeight(isSelected ? .semibold : .regular)
                .foregroundColor(isSelected ? .white : .primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(isSelected ? mood.color : Color(.systemGray6))
                .shadow(color: isSelected ? mood.color.opacity(0.4) : .clear, radius: 8, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(isSelected ? mood.color : Color.clear, lineWidth: 2)
        )
        .scaleEffect(isPressed ? 0.95 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isPressed)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSelected)
        .contentShape(Rectangle())
        .onAppear {
            // Prepare feedback generator for low-latency response on first tap
            impactFeedback.prepare()
        }
        .onTapGesture {
            impactFeedback.impactOccurred()
            action()
        }
        .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
            isPressed = pressing
        }, perform: {})
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(mood.displayName) \(mood.emoji)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityHint("Double tap to select this mood")
        .accessibilityAddTraits(.isButton)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction {
            impactFeedback.impactOccurred()
            action()
        }
    }
}

struct FollowUpOptionButton: View {
    let option: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isPressed = false
    private let impactFeedback = UIImpactFeedbackGenerator(style: .light)

    var body: some View {
        Text(option)
            .font(.body)
            .fontWeight(isSelected ? .semibold : .regular)
            .foregroundColor(isSelected ? .white : .primary)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? Color.accentColor : Color(.systemGray6))
            )
            .scaleEffect(isPressed ? 0.95 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isPressed)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isSelected)
            .contentShape(Rectangle())
            .onAppear {
                // Prepare feedback generator for low-latency response on first tap
                impactFeedback.prepare()
            }
            .onTapGesture {
                impactFeedback.impactOccurred()
                action()
            }
            .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
                isPressed = pressing
            }, perform: {})
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(option)
            .accessibilityValue(isSelected ? "Selected" : "Not selected")
            .accessibilityHint("Double tap to select this option")
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityAction {
                impactFeedback.impactOccurred()
                action()
            }
    }
}
