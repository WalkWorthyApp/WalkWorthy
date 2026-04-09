//
//  GlassCard.swift
//  WalkWorthy
//
//  Shared modifier for the liquid glass aesthetic.
//

import SwiftUI

struct GlassCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(scaled(24))
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: scaled(24), style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: scaled(24), style: .continuous)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.15), radius: scaled(16), x: 0, y: scaled(12))
    }
}

extension View {
    func glassCard() -> some View {
        modifier(GlassCardModifier())
    }
}
