//
//  TagChip.swift
//  WalkWorthy
//
//  Simple selectable chip button used for multi-select hobbies.
//

import SwiftUI
import UIKit

struct TagChip: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: trigger) {
            Text(label)
                .font(.callout.weight(.semibold))
                // Single-line pills: long labels (including user-typed custom
                // hobbies) hyphen-break mid-word inside the grid cell on
                // 402pt-wide iPhones. Shrink slightly instead of wrapping.
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, scaled(16))
                .padding(.vertical, scaled(10))
                .frame(minWidth: scaled(90))
                .background(background)
                .foregroundColor(foreground)
                .clipShape(Capsule())
                .accessibilityLabel(label)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .buttonStyle(.plain)
    }

    private var background: Color {
        isSelected ? Color.accentColor.opacity(0.25) : Color.white.opacity(0.12)
    }

    private var foreground: Color {
        isSelected ? Color.accentColor : Color.primary
    }

    private func trigger() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        action()
    }
}
