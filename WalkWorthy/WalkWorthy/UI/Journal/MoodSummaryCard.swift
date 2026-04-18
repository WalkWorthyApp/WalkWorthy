//
//  MoodSummaryCard.swift
//  WalkWorthy
//
//  Collapsible inline card shown at the top of JournalEditorView
//  when the entry has denormalized mood data. Minimal form only:
//  sentiment glyph + mood level + score, plus emotion chips when expanded.
//

import SwiftUI

struct MoodSummaryCard: View {
    let moodLevelRaw: String
    let moodScore: Int?
    let emotionTags: [String]
    @Binding var isExpanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: JournalIcons.moodGlyph(for: moodLevelRaw))
                        .foregroundStyle(.tint)
                    Text(Self.displayName(for: moodLevelRaw))
                        .font(.system(size: 15, weight: .semibold))
                    if let score = moodScore {
                        Text("· \(score)")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? JournalIcons.chevronUp : JournalIcons.chevronDown)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded && !emotionTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(emotionTags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: 13))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    Capsule().fill(Color.secondary.opacity(0.15))
                                )
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary)
        )
    }

    private static func displayName(for moodLevelRaw: String) -> String {
        switch moodLevelRaw {
        case "very_unpleasant": return "Very Unpleasant"
        case "unpleasant":      return "Unpleasant"
        case "neutral":         return "Neutral"
        case "pleasant":        return "Pleasant"
        case "very_pleasant":   return "Very Pleasant"
        default:                return moodLevelRaw.capitalized
        }
    }
}
