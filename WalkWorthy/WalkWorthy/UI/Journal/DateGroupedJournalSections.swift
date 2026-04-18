//
//  DateGroupedJournalSections.swift
//  WalkWorthy
//
//  Pure helper that buckets journal entries into Apple Notes-style
//  date sections: Today / Yesterday / Previous 7 Days / Previous 30 Days /
//  month names (with year suffix only for prior years).
//

import Foundation

struct JournalSection: Identifiable {
    let id: String
    let title: String
    let entries: [JournalEntry]
}

enum DateGroupedJournalSections {
    /// Buckets non-pinned entries into date sections. Pinned entries are
    /// excluded; the caller renders them separately.
    static func make(
        entries: [JournalEntry],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [JournalSection] {
        let nonPinned = entries.filter { !$0.isPinned }
        guard !nonPinned.isEmpty else { return [] }

        var today: [JournalEntry] = []
        var yesterday: [JournalEntry] = []
        var previous7: [JournalEntry] = []
        var previous30: [JournalEntry] = []
        var monthBuckets: [MonthKey: [JournalEntry]] = [:]

        let nowDay = calendar.startOfDay(for: now)

        for entry in nonPinned.sorted(by: { $0.createdAt > $1.createdAt }) {
            let entryDay = calendar.startOfDay(for: entry.createdAt)
            let days = calendar.dateComponents([.day], from: entryDay, to: nowDay).day ?? 0
            switch days {
            case 0:       today.append(entry)
            case 1:       yesterday.append(entry)
            case 2...7:   previous7.append(entry)
            case 8...30:  previous30.append(entry)
            default:
                let comps = calendar.dateComponents([.year, .month], from: entry.createdAt)
                let key = MonthKey(year: comps.year ?? 0, month: comps.month ?? 0)
                monthBuckets[key, default: []].append(entry)
            }
        }

        var sections: [JournalSection] = []
        if !today.isEmpty     { sections.append(.init(id: "today",     title: "Today",            entries: today)) }
        if !yesterday.isEmpty { sections.append(.init(id: "yesterday", title: "Yesterday",        entries: yesterday)) }
        if !previous7.isEmpty { sections.append(.init(id: "prev7",     title: "Previous 7 Days",  entries: previous7)) }
        if !previous30.isEmpty{ sections.append(.init(id: "prev30",    title: "Previous 30 Days", entries: previous30)) }

        let sortedKeys = monthBuckets.keys.sorted {
            if $0.year != $1.year { return $0.year > $1.year }
            return $0.month > $1.month
        }
        let currentYear = calendar.component(.year, from: now)
        for key in sortedKeys {
            let title = Self.monthTitle(key: key, currentYear: currentYear, calendar: calendar)
            sections.append(.init(id: "m-\(key.year)-\(key.month)", title: title, entries: monthBuckets[key] ?? []))
        }
        return sections
    }

    private struct MonthKey: Hashable { let year: Int; let month: Int }

    private static let monthNameFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "LLLL"
        return f
    }()

    private static func monthTitle(key: MonthKey, currentYear: Int, calendar: Calendar) -> String {
        var comps = DateComponents(); comps.year = key.year; comps.month = key.month
        guard let date = calendar.date(from: comps) else { return "" }
        let monthName = monthNameFormatter.string(from: date)
        return key.year == currentYear ? monthName : "\(monthName) \(key.year)"
    }
}
