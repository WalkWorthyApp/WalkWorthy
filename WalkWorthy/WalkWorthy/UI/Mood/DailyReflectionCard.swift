//
//  DailyReflectionCard.swift
//  WalkWorthy
//

import SwiftUI

struct DailyReflectionCard: View {
    let reflection: DailyReflection?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "cross.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Today's Reflection")
                    .font(.headline)
            }

            if let reflection {
                Text(reflection.reflection)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                // Shimmer placeholder — three lines of redacted text
                VStack(alignment: .leading, spacing: 6) {
                    Text("This is a placeholder reflection line for sizing purposes.")
                        .font(.body)
                    Text("Second line of the placeholder.")
                        .font(.body)
                    Text("Third shorter line.")
                        .font(.body)
                }
                .redacted(reason: .placeholder)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.systemBackground)))
        .animation(.easeInOut(duration: 0.4), value: reflection != nil)
    }
}
