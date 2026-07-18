//
//  MoodHistoryView.swift
//  WalkWorthy
//
//  Shows mood history and trends over time.
//

import SwiftUI
import Charts

enum DateRangeSelection: Equatable {
    case days(Int)
    case thisMonth
}

// MARK: - Shared Date Formatters

private let isoDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

private let dayOfWeekFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "E"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

private let dayNumberFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "d"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

private let monthDayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMM d"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

private let displayDateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "EEEE, MMM d"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

private let monthYearFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "MMMM yyyy"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

struct MoodHistoryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedRange: DateRangeSelection = .days(7)
    @State private var summaries: [DailyMoodSummary] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var periodOffset: Int = 0

    // Calculate total days in current month for the given date
    private func daysInCurrentMonth(for date: Date) -> Int {
        let calendar = Calendar.current
        return calendar.range(of: .day, in: .month, for: date)?.count ?? 30
    }

    // Compute the start and end date for the current window.
    private var currentWindow: (startDate: String, endDate: String) {
        window(for: selectedRange, offset: periodOffset)
    }

    // Compute the start and end date for an explicit range + offset. Split out
    // from `currentWindow` so `loadHistoryAsync` can derive the request window
    // from values captured BEFORE its first await — reading live @State after
    // the await would let a mid-flight range-picker change redirect the
    // response into the wrong window.
    // All Calendar math guards against nil — non-Gregorian calendars (Japanese,
    // Buddhist) and DST edges can return nil from `calendar.date(byAdding:)`
    // and `calendar.range(of:)`. Fall back to today's window on failure.
    private func window(for range: DateRangeSelection, offset: Int) -> (startDate: String, endDate: String) {
        let calendar = Calendar.current
        let today = Date()
        let todayString = isoDateFormatter.string(from: today)

        switch range {
        case .days(let count):
            // endDate = today shifted by (offset * count) days
            // startDate = endDate minus (count - 1) days
            guard let endDate = calendar.date(
                byAdding: .day,
                value: offset * count,
                to: today
            ) else {
                return (todayString, todayString)
            }
            guard let startDate = calendar.date(
                byAdding: .day,
                value: -(count - 1),
                to: endDate
            ) else {
                let endString = isoDateFormatter.string(from: endDate)
                return (endString, endString)
            }
            return (isoDateFormatter.string(from: startDate),
                    isoDateFormatter.string(from: endDate))

        case .thisMonth:
            // Shift by 'offset' whole calendar months
            guard let targetMonth = calendar.date(
                byAdding: .month,
                value: offset,
                to: today
            ) else {
                return (todayString, todayString)
            }
            guard let startOfMonth = calendar.date(
                from: calendar.dateComponents([.year, .month], from: targetMonth)
            ) else {
                return (todayString, todayString)
            }
            // Assume 30 days if calendar range lookup fails.
            let daysInMonth = calendar.range(of: .day, in: .month, for: targetMonth)?.count ?? 30
            guard let endOfMonth = calendar.date(
                byAdding: .day,
                value: daysInMonth - 1,
                to: startOfMonth
            ) else {
                let startString = isoDateFormatter.string(from: startOfMonth)
                return (startString, startString)
            }
            return (isoDateFormatter.string(from: startOfMonth),
                    isoDateFormatter.string(from: endOfMonth))
        }
    }

    var body: some View {
        ZStack {
            DynamicBackgroundView()

            ScrollView {
                VStack(spacing: scaled(24)) {
                    // Days selector
                    daysSelector

                    // Error message display
                    if let errorMessage = errorMessage {
                        VStack(alignment: .leading, spacing: scaled(6)) {
                            Text("Error Loading History")
                                .font(.subheadline.bold())
                                .foregroundStyle(.red)

                            Text(errorMessage)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .lineLimit(nil)
                        }
                        .padding(scaled(12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: scaled(12), style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: scaled(12), style: .continuous)
                                .stroke(Color.red.opacity(0.2), lineWidth: 1)
                        )
                    }

                    // Week overview - always show so empty periods still display the calendar
                    weekOverview

                    // Latest encouragement
                    if let checkIn = appState.currentMoodStatus?.checkIn {
                        latestEncouragementCard(checkIn)
                    }

                    SentimentChartView(
                        summaries: summaries,
                        daysToDisplay: daysToDisplay
                    )
                }
                .padding(.vertical)
                .padding(.horizontal, scaled(8))
            }
            .refreshable {
                await loadHistoryAsync()
            }
            .gesture(
                DragGesture(minimumDistance: 40, coordinateSpace: .local)
                    .onEnded { value in
                        let horizontal = value.translation.width
                        let vertical = value.translation.height
                        guard abs(horizontal) > abs(vertical) else { return }  // horizontal swipe only
                        if horizontal < 0 {
                            // Swipe left → go back
                            periodOffset -= 1
                            loadHistory()
                        } else if horizontal > 0 && periodOffset < 0 {
                            // Swipe right → go forward, but not past present
                            periodOffset += 1
                            loadHistory()
                        }
                    }
            )
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Mood History")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Mood History")
                    .font(.newsreaderSemiBoldItalic(size: scaled(20)))
            }
        }
        .onAppear {
            // Seed the week grid from the last-known snapshot before the
            // network call so cold launch renders bars instantly. Only for
            // the default (7-day, offset 0) window — other windows always
            // fetch fresh.
            if selectedRange == .days(7) && periodOffset == 0 && summaries.isEmpty {
                summaries = appState.weekSummary
            }
            loadHistory()
            Task { await appState.loadMoodStatus() }
        }
    }

    private var daysSelector: some View {
        HStack(spacing: scaled(12)) {
            // 7 days button
            Button(action: {
                selectedRange = .days(7)
                periodOffset = 0
                loadHistory()
            }) {
                Text("7 days")
                    .font(.subheadline)
                    .fontWeight(selectedRange == .days(7) ? .semibold : .regular)
                    .foregroundColor(selectedRange == .days(7) ? .white : .primary)
                    .padding(.horizontal, scaled(16))
                    .padding(.vertical, scaled(8))
                    .background(
                        Capsule()
                            .fill(selectedRange == .days(7) ? Color.accentColor : Color(.systemGray6))
                    )
            }

            // 14 days button
            Button(action: {
                selectedRange = .days(14)
                periodOffset = 0
                loadHistory()
            }) {
                Text("14 days")
                    .font(.subheadline)
                    .fontWeight(selectedRange == .days(14) ? .semibold : .regular)
                    .foregroundColor(selectedRange == .days(14) ? .white : .primary)
                    .padding(.horizontal, scaled(16))
                    .padding(.vertical, scaled(8))
                    .background(
                        Capsule()
                            .fill(selectedRange == .days(14) ? Color.accentColor : Color(.systemGray6))
                    )
            }

            // This Month button
            Button(action: {
                selectedRange = .thisMonth
                periodOffset = 0
                loadHistory()
            }) {
                Text("This Month")
                    .font(.subheadline)
                    .fontWeight(selectedRange == .thisMonth ? .semibold : .regular)
                    .foregroundColor(selectedRange == .thisMonth ? .white : .primary)
                    .padding(.horizontal, scaled(16))
                    .padding(.vertical, scaled(8))
                    .background(
                        Capsule()
                            .fill(selectedRange == .thisMonth ? Color.accentColor : Color(.systemGray6))
                    )
            }
        }
    }

    private var weekOverview: some View {
        VStack(alignment: .leading, spacing: scaled(20)) {
            // Header with navigation
            HStack {
                // Previous button
                Button {
                    periodOffset -= 1
                    loadHistory()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.subheadline.weight(.semibold))
                }
                .accessibilityLabel("Previous period")

                Spacer()

                VStack(alignment: .center, spacing: scaled(4)) {
                    Text(overviewTitle)
                        .font(.newsreaderSemiBoldItalic(size: scaled(19)))

                    Text(dateRangeString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Next button — disabled at offset 0
                Button {
                    periodOffset += 1
                    loadHistory()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                }
                .accessibilityLabel("Next period")
                .disabled(periodOffset == 0)
                .opacity(periodOffset == 0 ? 0.3 : 1)
            }

            // Streak or completion indicator
            if !summaries.isEmpty {
                let completedDays = summaries.filter { $0.completedCount > 0 }.count
                HStack(spacing: scaled(4)) {
                    Image(systemName: "flame.fill")
                        .foregroundColor(.orange)
                    Text("\(completedDays) days")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, scaled(10))
                .padding(.vertical, scaled(6))
                .background(
                    Capsule()
                        .fill(Color.orange.opacity(0.12))
                )
            }

            // Day indicators - use grid for 14 days/This Month, HStack for 7 days
            if selectedRange == .days(7) {
                // Single row for 7 days
                HStack(spacing: 0) {
                    ForEach(daysToDisplay, id: \.self) { date in
                        dayIndicator(for: date)
                            .frame(maxWidth: .infinity)
                    }
                }
            } else {
                // Grid layout for 14 days or This Month
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: scaled(4)), count: 7), spacing: scaled(12)) {
                    ForEach(daysToDisplay, id: \.self) { date in
                        dayIndicator(for: date, compact: selectedRange == .thisMonth)
                    }
                }
            }
        }
        .padding(scaled(20))
        .background(
            RoundedRectangle(cornerRadius: scaled(20))
                .fill(Color.wwCardBackground)
                .shadow(color: .black.opacity(0.06), radius: scaled(12), x: 0, y: scaled(4))
        )
        .overlay(
            RoundedRectangle(cornerRadius: scaled(20))
                .stroke(Color(.separator).opacity(0.15), lineWidth: 1)
        )
    }

    private var overviewTitle: String {
        guard periodOffset != 0 else {
            // Current period labels
            switch selectedRange {
            case .days(7): return "This Week"
            case .days(14): return "Last 2 Weeks"
            case .thisMonth: return "This Month"
            default: return "Overview"
            }
        }
        // Past period labels
        switch selectedRange {
        case .thisMonth:
            guard let start = isoDateFormatter.date(from: currentWindow.startDate) else { return "Past Month" }
            return monthYearFormatter.string(from: start)
        default:
            return "Past Period"
        }
    }

    private var dateRangeString: String {
        guard let firstDate = daysToDisplay.first,
              let lastDate = daysToDisplay.last else { return "" }

        guard let start = isoDateFormatter.date(from: firstDate),
              let end = isoDateFormatter.date(from: lastDate) else { return "" }

        return "\(monthDayFormatter.string(from: start)) - \(monthDayFormatter.string(from: end))"
    }

    private var daysToDisplay: [String] {
        let calendar = Calendar.current
        let window = currentWindow

        guard let start = isoDateFormatter.date(from: window.startDate),
              let end = isoDateFormatter.date(from: window.endDate) else { return [] }

        var dates: [String] = []
        var cursor = start
        // Defensive: prevents an infinite loop if calendar.date(byAdding:) ever
        // returns nil (non-Gregorian calendars / DST edges) or `cursor` somehow
        // fails to advance past `end`. 400 ≈ 12 months of daily entries, far
        // above the largest configured window (currently 31 days). If this
        // limit trips, calendar math has regressed — surface it loudly in DEBUG.
        let maxIterations = 400
        var iterations = 0
        while cursor <= end && iterations < maxIterations {
            dates.append(isoDateFormatter.string(from: cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else {
                break
            }
            cursor = next
            iterations += 1
        }
        if iterations >= maxIterations {
            assertionFailure("daysToDisplay iteration limit hit — review calendar math")
        }
        return dates
    }

    private func dayIndicator(for dateString: String, compact: Bool = false) -> some View {
        let summary = summaries.first { $0.date == dateString }
        let date = isoDateFormatter.date(from: dateString)

        let dayOfWeek: String = {
            guard let date = date else { return "" }
            return dayOfWeekFormatter.string(from: date)
        }()

        let dayNumber: String = {
            guard let date = date else { return "" }
            return dayNumberFormatter.string(from: date)
        }()

        let isToday = dateString == isoDateFormatter.string(from: Date())
        let hasMoodData = (summary?.completedCount ?? 0) > 0
        let sentimentColor = sentimentColor(for: summary)

        // Sizes based on compact mode
        let circleSize: CGFloat = compact ? scaled(32) : scaled(40)
        let fontSize: CGFloat = compact ? scaled(12) : scaled(15)
        let ringSize: CGFloat = compact ? scaled(36) : scaled(44)
        let ringWidth: CGFloat = compact ? scaled(2) : scaled(2.5)
        let dotSize: CGFloat = compact ? scaled(4) : scaled(5)

        return Button(action: {}) {
            VStack(spacing: compact ? scaled(4) : scaled(8)) {
                // Day of week label - hide in compact mode except for first row
                if !compact {
                    Text(dayOfWeek)
                        .font(.system(size: scaled(11), weight: .medium))
                        .foregroundColor(isToday ? .accentColor : .secondary)
                        .textCase(.uppercase)
                }

                // Main day indicator
                ZStack {
                    // Background circle with gradient
                    if hasMoodData {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        sentimentColor,
                                        sentimentColor.opacity(0.85)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .shadow(color: sentimentColor.opacity(0.35), radius: compact ? scaled(2) : scaled(4), x: 0, y: compact ? scaled(1) : scaled(2))
                    } else {
                        Circle()
                            .fill(Color(.systemGray6))
                        Circle()
                            .strokeBorder(Color(.systemGray4), lineWidth: 1)
                    }

                    // Day number - sized to fit properly
                    Text(dayNumber)
                        .font(.system(size: fontSize, weight: hasMoodData ? .semibold : .medium, design: .rounded))
                        .foregroundColor(hasMoodData ? .white : .secondary)
                        .minimumScaleFactor(0.8)
                        .lineLimit(1)
                }
                .frame(width: circleSize, height: circleSize)
                .overlay(
                    // Today ring indicator
                    Circle()
                        .strokeBorder(Color.accentColor, lineWidth: ringWidth)
                        .opacity(isToday ? 1 : 0)
                        .frame(width: ringSize, height: ringSize)
                )

                // Check-in completion dots
                HStack(spacing: compact ? scaled(2) : scaled(3)) {
                    ForEach(0..<3) { index in
                        Circle()
                            .fill(checkInDotColor(for: summary, index: index))
                            .frame(width: dotSize, height: dotSize)
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .opacity(summary != nil || isToday ? 1 : 0.6)
    }

    private func checkInDotColor(for summary: DailyMoodSummary?, index: Int) -> Color {
        guard let summary = summary else {
            return Color(.systemGray5)
        }

        let checkIns = [summary.morning, summary.midday, summary.evening]
        if index < checkIns.count, checkIns[index] != nil {
            // Use the mood color for completed check-ins
            if let moodLevel = checkIns[index]?.moodLevelEnum {
                return moodLevel.sentiment.color
            }
            return Color.accentColor
        }
        return Color(.systemGray5)
    }

    private func sentimentColor(for summary: DailyMoodSummary?) -> Color {
        guard let summary = summary else {
            return Color(.systemGray4)
        }

        if let sentiment = summary.sentiment {
            return sentiment.color
        }

        // Calculate from moods if no overall sentiment
        if summary.completedCount == 0 {
            return Color(.systemGray4)
        }

        return Color(.systemGray3)
    }

    private func latestEncouragementCard(_ checkIn: MoodCheckIn) -> some View {
        VStack(alignment: .leading, spacing: scaled(16)) {
            HStack {
                Text("Latest Encouragement")
                    .font(.newsreaderSemiBoldItalic(size: scaled(17)))

                Spacer()

                Text(checkIn.aiResponse.verseRef)
                    .font(.newsreaderSemiBoldItalic(size: scaled(13)))
                    .foregroundColor(.accentColor)
            }

            Text(checkIn.aiResponse.message)
                .font(.newsreader(size: scaled(15)))
                .foregroundColor(.secondary)

            Divider()

            Text(checkIn.aiResponse.verseText)
                .font(.newsreader(size: scaled(15)))
                .lineSpacing(scaled(3))
                .foregroundColor(.primary)
        }
        .padding(scaled(20))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: scaled(20), style: .continuous)
                .fill(Color.wwCardBackground)
                .shadow(color: .black.opacity(0.05), radius: scaled(10), y: scaled(5))
        )
    }

    private func loadHistory() {
        isLoading = true
        errorMessage = nil
        Task {
            await loadHistoryAsync()
        }
    }

    private func loadHistoryAsync() async {
        // Capture the request window BEFORE the first await. The @State values
        // can change mid-flight (user taps the range picker while a fetch is
        // in the air); re-reading them after the await would let a stale
        // month-sized response pass the "default window" guard below and
        // pollute the weekSummary cache with non-week data.
        let requestedRange = selectedRange
        let requestedOffset = periodOffset
        let window = window(for: requestedRange, offset: requestedOffset)

        do {
            // Compute days to fetch based on the requested range
            let daysToFetch: Int
            switch requestedRange {
            case .days(let count):
                daysToFetch = count
            case .thisMonth:
                guard let startDate = isoDateFormatter.date(from: window.startDate) else {
                    await MainActor.run { isLoading = false }
                    return
                }
                daysToFetch = daysInCurrentMonth(for: startDate)
            }

            // Only pass explicit bounds when navigating away from the current period
            let startDate: String? = requestedOffset == 0 ? nil : window.startDate
            let endDate: String? = requestedOffset == 0 ? nil : window.endDate

            let response = try await appState.loadMoodHistory(
                days: daysToFetch,
                startDate: startDate,
                endDate: endDate
            )
            let fetched = response.summaries
            await MainActor.run {
                // Only display the response if the user is still on the window
                // it was requested for — a stale response must not overwrite
                // the grid the user is now looking at.
                if requestedRange == selectedRange && requestedOffset == periodOffset {
                    summaries = fetched
                }
                errorMessage = nil
                isLoading = false
            }
            // Only cache the default window so range-picker changes don't
            // overwrite the "instant launch" snapshot with a non-week view.
            // Guarded on the CAPTURED window, not live @State — see above.
            if requestedRange == .days(7) && requestedOffset == 0 {
                await MainActor.run { appState.weekSummary = fetched }
                if let sub = appState.authenticatedUserSub {
                    await SnapshotStore.shared.write(fetched, kind: .weekSummary, userSub: sub)
                }
            }
        } catch {
            let errorDescription = error.localizedDescription
            #if DEBUG
            print("[MoodHistoryView] Failed to load mood history: \(errorDescription)")
            #endif

            await MainActor.run {
                errorMessage = errorDescription
                isLoading = false
            }
        }
    }
}

