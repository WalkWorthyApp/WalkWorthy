//
//  BirthDate.swift
//  WalkWorthy
//
//  The user's birthday as a calendar day. It is a date, not an instant, so it
//  carries no time or time zone; the backend stores it as "YYYY-MM-DD".
//

import Foundation

/// Marked `nonisolated` because the project defaults actor isolation to
/// `@MainActor`; this plain value type is safe to use from any isolation.
nonisolated struct BirthDate: Equatable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    /// Birthdays are always read and written in the Gregorian calendar, in the
    /// device's current time zone. Using `Calendar.current` would let a
    /// Buddhist or Japanese device calendar change the stored year.
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .autoupdatingCurrent
        return calendar
    }()

    /// Rejects impossible days such as February 30.
    init?(year: Int, month: Int, day: Int) {
        guard (1900...9999).contains(year),
              DateComponents(year: year, month: month, day: day).isValidDate(in: Self.calendar) else {
            return nil
        }
        self.year = year
        self.month = month
        self.day = day
    }

    /// The local calendar day of `date`, e.g. a date picker selection.
    init?(date: Date) {
        let parts = Self.calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
        self.init(year: year, month: month, day: day)
    }

    /// Parses the backend's "YYYY-MM-DD" form.
    init?(isoString: String) {
        let parts = isoString.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else {
            return nil
        }
        self.init(year: year, month: month, day: day)
    }

    var isoString: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Noon on the birthday, for a date picker selection. Noon avoids the
    /// midnight daylight-saving gaps some time zones have.
    var date: Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .now
    }

    /// Completed years on the local day of `date`. A February 29 birthday
    /// counts from March 1 in common years.
    func age(on date: Date = .now) -> Int {
        let today = Self.calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = today.year, let month = today.month, let day = today.day else { return 0 }
        let hadBirthdayThisYear = (month, day) >= (self.month, self.day)
        return year - self.year - (hadBirthdayThisYear ? 0 : 1)
    }

    /// Whether the local day of `date` is the day this birthday is celebrated.
    func isBirthday(on date: Date = .now) -> Bool {
        let today = Self.calendar.dateComponents([.year, .month, .day], from: date)
        guard let year = today.year else { return false }
        let celebration = celebrationDay(in: year)
        return today.month == celebration.month && today.day == celebration.day
    }

    /// The first birthday celebration at `hour`:00 local time after `date`.
    func nextCelebration(after date: Date = .now, atHour hour: Int) -> Date? {
        let year = Self.calendar.component(.year, from: date)
        for candidateYear in [year, year + 1] {
            var parts = celebrationDay(in: candidateYear)
            parts.hour = hour
            if let celebration = Self.calendar.date(from: parts), celebration > date {
                return celebration
            }
        }
        return nil
    }

    /// The day the birthday falls on in `year`: February 29 is celebrated on
    /// February 28 in common years.
    private func celebrationDay(in year: Int) -> DateComponents {
        let birthday = DateComponents(year: year, month: month, day: day)
        guard birthday.isValidDate(in: Self.calendar) else {
            return DateComponents(year: year, month: 2, day: 28)
        }
        return birthday
    }
}
