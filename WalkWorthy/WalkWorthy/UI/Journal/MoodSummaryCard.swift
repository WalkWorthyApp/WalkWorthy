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
        VStack(alignment: .leading, spacing: scaled(10)) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isExpanded.toggle() }
            } label: {
                HStack(spacing: scaled(8)) {
                    Image(systemName: JournalIcons.moodGlyph(for: moodLevelRaw))
                        .foregroundStyle(.tint)
                    Text(Self.displayName(for: moodLevelRaw))
                        .font(.system(size: scaled(15), weight: .semibold))
                    Spacer()
                    Image(systemName: isExpanded ? JournalIcons.chevronUp : JournalIcons.chevronDown)
                        .font(.system(size: scaled(12)))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded && !emotionTags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: scaled(8)) {
                        ForEach(emotionTags, id: \.self) { tag in
                            Text(tag)
                                .font(.system(size: scaled(13)))
                                .padding(.horizontal, scaled(10))
                                .padding(.vertical, scaled(5))
                                .background(
                                    Capsule().fill(Color.secondary.opacity(0.15))
                                )
                        }
                    }
                }
            }
        }
        .padding(scaled(12))
        .background(
            RoundedRectangle(cornerRadius: scaled(20), style: .continuous)
                .fill(Color("CardBackground"))
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
