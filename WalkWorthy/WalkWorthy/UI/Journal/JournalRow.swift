//
//  JournalRow.swift
//  WalkWorthy
//
//  Single row in the Apple Notes-style journal list.
//

import SwiftUI

struct JournalRow: View {
    let entry: JournalEntry
    let now: Date

    var body: some View {
        let slice = JournalTextSlicing.titleAndPreview(from: entry.text)

        HStack(alignment: .top, spacing: 8) {
            if entry.isPinned {
                Image(systemName: JournalIcons.pinFilled)
                    .font(.caption)
                    .foregroundStyle(.tint)
                    .padding(.top, 2)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(slice.title.isEmpty ? "New Note" : slice.title)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if entry.moodLevelRaw != nil {
                        Image(systemName: JournalIcons.moodLinkedIndicator)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }

                HStack(spacing: 6) {
                    Text(slice.preview.isEmpty ? " " : slice.preview)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 0)

                    Text(Self.timestamp(for: entry.createdAt, now: now))
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = .init(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"; return f
    }()
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = .init(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE"; return f
    }()
    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = .init(identifier: "en_US_POSIX")
        f.dateFormat = "M/d/yy"; return f
    }()

    static func timestamp(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        switch days {
        case 0:      return timeFormatter.string(from: date)
        case 1:      return "Yesterday"
        case 2...7:  return weekdayFormatter.string(from: date)
        default:     return shortDateFormatter.string(from: date)
        }
    }
}
