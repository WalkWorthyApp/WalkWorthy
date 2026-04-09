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
                    .font(.newsreaderSemiBoldItalic(fixedSize: scaled(15)))
            }

            if let reflection {
                Text(reflection.reflection)
                    .font(.newsreader(fixedSize: scaled(17)))
                    .foregroundStyle(.primary)
                    .lineSpacing(scaled(4))
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            } else {
                // Shimmer placeholder — three lines of redacted text
                VStack(alignment: .leading, spacing: scaled(6)) {
                    Text("This is a placeholder reflection line for sizing purposes.")
                        .font(.newsreader(fixedSize: scaled(17)))
                    Text("Second line of the placeholder.")
                        .font(.newsreader(fixedSize: scaled(17)))
                    Text("Third shorter line.")
                        .font(.newsreader(fixedSize: scaled(17)))
                }
                .redacted(reason: .placeholder)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: scaled(16)).fill(Color("CardBackground")))
        .animation(.easeInOut(duration: 0.4), value: reflection != nil)
    }
}
