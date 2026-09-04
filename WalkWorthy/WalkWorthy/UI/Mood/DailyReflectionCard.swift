//
//  DailyReflectionCard.swift
//  WalkWorthy
//

import SwiftUI

struct DailyReflectionCard: View {
    let reflection: DailyReflection?

    var body: some View {
        VStack(alignment: .leading, spacing: scaled(12)) {
            HStack(spacing: scaled(8)) {
                Image(systemName: "cross.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Today's Reflection")
                    .font(.newsreaderSemiBoldItalic(size: scaled(15)))
                Spacer()
                Text("AI-generated")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let reflection {
                // HIG (Generative AI → Inputs): communicate that AI-generated
                // content may contain errors, not just that it is AI-authored.
                Text("Written by AI and can get things wrong.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(reflection.reflection)
                    .font(.newsreader(size: scaled(17)))
                    .foregroundStyle(.primary)
                    .lineSpacing(scaled(4))
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                // Shimmer placeholder — three lines of redacted text
                VStack(alignment: .leading, spacing: scaled(6)) {
                    Text("This is a placeholder reflection line for sizing purposes.")
                        .font(.newsreader(size: scaled(17)))
                    Text("Second line of the placeholder.")
                        .font(.newsreader(size: scaled(17)))
                    Text("Third shorter line.")
                        .font(.newsreader(size: scaled(17)))
                }
                .redacted(reason: .placeholder)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: scaled(16)).fill(Color.wwCardBackground))
        .animation(.easeInOut(duration: 0.4), value: reflection != nil)
    }
}
