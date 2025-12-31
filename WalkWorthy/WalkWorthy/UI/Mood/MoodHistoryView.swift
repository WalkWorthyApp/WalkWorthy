//
//  MoodHistoryView.swift
//  WalkWorthy
//
//  Shows mood history and trends over time.
//

import SwiftUI

enum DateRangeSelection: Equatable {
    case days(Int)
    case thisMonth
}

struct MoodHistoryView: View {
    @EnvironmentObject private var appState: AppState
    @State private var selectedRange: DateRangeSelection = .days(7)
    @State private var summaries: [DailyMoodSummary] = []
    @State private var isLoading = false
    @State private var expandedDate: String?
    @State private var errorMessage: String?

    // Calculate total days in current month
    private var daysInCurrentMonth: Int {
        let calendar = Calendar.current
        let today = Date()
        return calendar.range(of: .day, in: .month, for: today)?.count ?? 30
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Days selector
                daysSelector

                // Error message display
                if let errorMessage = errorMessage {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Error Loading History")
                            .font(.subheadline.bold())
                            .foregroundStyle(.red)

                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .lineLimit(nil)
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.red.opacity(0.2), lineWidth: 1)
                    )
                }

                // Week overview
                if !summaries.isEmpty {
                    weekOverview
                }

                // Daily entries
                dailyEntries
            }
            .padding()
        }
        .navigationTitle("Mood History")
        .onAppear {
            loadHistory()
        }
        .refreshable {
            await loadHistoryAsync()
        }
    }

    private var daysSelector: some View {
        HStack(spacing: 12) {
            // 7 days button
            Button(action: {
                selectedRange = .days(7)
                loadHistory()
            }) {
                Text("7 days")
                    .font(.subheadline)
                    .fontWeight(selectedRange == .days(7) ? .semibold : .regular)
                    .foregroundColor(selectedRange == .days(7) ? .white : .primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(selectedRange == .days(7) ? Color.accentColor : Color(.systemGray6))
                    )
            }

            // 14 days button
            Button(action: {
                selectedRange = .days(14)
                loadHistory()
            }) {
                Text("14 days")
                    .font(.subheadline)
                    .fontWeight(selectedRange == .days(14) ? .semibold : .regular)
                    .foregroundColor(selectedRange == .days(14) ? .white : .primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(selectedRange == .days(14) ? Color.accentColor : Color(.systemGray6))
                    )
            }

            // This Month button
            Button(action: {
                selectedRange = .thisMonth
                loadHistory()
            }) {
                Text("This Month")
                    .font(.subheadline)
                    .fontWeight(selectedRange == .thisMonth ? .semibold : .regular)
                    .foregroundColor(selectedRange == .thisMonth ? .white : .primary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(
                        Capsule()
                            .fill(selectedRange == .thisMonth ? Color.accentColor : Color(.systemGray6))
                    )
            }
        }
    }

    private var weekOverview: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Header with date range
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(overviewTitle)
                        .font(.title3)
                        .fontWeight(.semibold)

                    Text(dateRangeString)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Streak or completion indicator
                if !summaries.isEmpty {
                    let completedDays = summaries.filter { $0.completedCount > 0 }.count
                    HStack(spacing: 4) {
                        Image(systemName: "flame.fill")
                            .foregroundColor(.orange)
                        Text("\(completedDays) days")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.orange.opacity(0.12))
                    )
                }
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
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 12) {
                    ForEach(daysToDisplay, id: \.self) { date in
                        dayIndicator(for: date, compact: selectedRange == .thisMonth)
                    }
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.06), radius: 12, x: 0, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(Color(.separator).opacity(0.15), lineWidth: 1)
        )
    }

    private var overviewTitle: String {
        switch selectedRange {
        case .days(7): return "This Week"
        case .days(14): return "Last 2 Weeks"
        case .thisMonth: return "This Month"
        default: return "Overview"
        }
    }

    private var dateRangeString: String {
        guard let firstDate = daysToDisplay.first,
              let lastDate = daysToDisplay.last else { return "" }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        guard let start = formatter.date(from: firstDate),
              let end = formatter.date(from: lastDate) else { return "" }

        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "MMM d"

        return "\(displayFormatter.string(from: start)) - \(displayFormatter.string(from: end))"
    }

    private var daysToDisplay: [String] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        switch selectedRange {
        case .thisMonth:
            // Special handling for "This Month" - show full calendar month
            let today = Date()
            let startOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: today))!

            return (0..<daysInCurrentMonth).compactMap { dayOffset in
                guard let date = calendar.date(byAdding: .day, value: dayOffset, to: startOfMonth) else {
                    return nil
                }
                return formatter.string(from: date)
            }

        case .days(let count):
            // Default behavior for 7 days, 14 days - go backwards from today
            return (0..<count).reversed().compactMap { daysAgo in
                // Safely unwrap the computed date; compactMap skips any nil values
                guard let date = calendar.date(byAdding: .day, value: -daysAgo, to: Date()) else {
                    return nil
                }
                return formatter.string(from: date)
            }
        }
    }

    private func dayIndicator(for dateString: String, compact: Bool = false) -> some View {
        let summary = summaries.first { $0.date == dateString }
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let date = dayFormatter.date(from: dateString)

        let dayOfWeek: String = {
            guard let date = date else { return "" }
            let formatter = DateFormatter()
            formatter.dateFormat = "E" // Single letter abbreviation
            return formatter.string(from: date)
        }()

        let dayNumber: String = {
            guard let date = date else { return "" }
            let formatter = DateFormatter()
            formatter.dateFormat = "d"
            return formatter.string(from: date)
        }()

        let isToday = dateString == dayFormatter.string(from: Date())
        let hasMoodData = summary != nil && summary!.completedCount > 0
        let sentimentColor = sentimentColor(for: summary)

        // Sizes based on compact mode
        let circleSize: CGFloat = compact ? 32 : 40
        let fontSize: CGFloat = compact ? 12 : 15
        let ringSize: CGFloat = compact ? 36 : 44
        let ringWidth: CGFloat = compact ? 2 : 2.5
        let dotSize: CGFloat = compact ? 4 : 5

        return Button(action: {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                if expandedDate == dateString {
                    expandedDate = nil
                } else if summary != nil {
                    expandedDate = dateString
                }
            }
        }) {
            VStack(spacing: compact ? 4 : 8) {
                // Day of week label - hide in compact mode except for first row
                if !compact {
                    Text(dayOfWeek)
                        .font(.system(size: 11, weight: .medium))
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
                            .shadow(color: sentimentColor.opacity(0.35), radius: compact ? 2 : 4, x: 0, y: compact ? 1 : 2)
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
                HStack(spacing: compact ? 2 : 3) {
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
            if let moodOption = checkIns[index]?.moodOption {
                return moodOption.color
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

    private var dailyEntries: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Daily Check-ins")
                .font(.headline)

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
            } else if summaries.isEmpty {
                emptyState
            } else {
                ForEach(summaries) { summary in
                    DailySummaryCard(
                        summary: summary,
                        isExpanded: expandedDate == summary.date,
                        onTap: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                if expandedDate == summary.date {
                                    expandedDate = nil
                                } else {
                                    expandedDate = summary.date
                                }
                            }
                        }
                    )
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "heart.text.square")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No check-ins yet")
                .font(.headline)

            Text("Start tracking your mood to see your history here.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func loadHistory() {
        isLoading = true
        errorMessage = nil
        Task {
            await loadHistoryAsync()
        }
    }

    private func loadHistoryAsync() async {
        do {
            // Compute days to fetch based on selected range
            let daysToFetch: Int
            switch selectedRange {
            case .days(let count):
                daysToFetch = count
            case .thisMonth:
                daysToFetch = daysInCurrentMonth
            }

            let response = try await appState.apiClient.fetchMoodHistory(days: daysToFetch)
            await MainActor.run {
                summaries = response.summaries
                errorMessage = nil
                isLoading = false
            }
        } catch {
            let errorDescription = error.localizedDescription
            print("[MoodHistoryView] Failed to load mood history: \(errorDescription)")

            await MainActor.run {
                errorMessage = errorDescription
                isLoading = false
            }
        }
    }
}

struct DailySummaryCard: View {
    let summary: DailyMoodSummary
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            Button(action: onTap) {
                HStack {
                    // Date
                    VStack(alignment: .leading, spacing: 2) {
                        Text(formattedDate)
                            .font(.headline)

                        Text("\(summary.completedCount)/3 check-ins")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    // Sentiment indicator
                    if let sentiment = summary.sentiment {
                        Circle()
                            .fill(sentiment.color)
                            .frame(width: 12, height: 12)
                    }

                    // Mood emojis
                    HStack(spacing: 4) {
                        if let morning = summary.morning?.moodOption {
                            Text(morning.emoji)
                        }
                        if let midday = summary.midday?.moodOption {
                            Text(midday.emoji)
                        }
                        if let evening = summary.evening?.moodOption {
                            Text(evening.emoji)
                        }
                    }
                    .font(.title3)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
            }
            .buttonStyle(.plain)

            // Expanded details
            if isExpanded {
                VStack(spacing: 8) {
                    checkInRow(type: .morning, summary: summary.morning)
                    checkInRow(type: .midday, summary: summary.midday)
                    checkInRow(type: .evening, summary: summary.evening)
                }
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.05), radius: 5, y: 2)
        )
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: summary.date) else {
            return summary.date
        }

        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "EEEE, MMM d"
        return displayFormatter.string(from: date)
    }

    private func checkInRow(type: CheckInType, summary: CheckInSummary?) -> some View {
        HStack {
            Image(systemName: type.iconName)
                .foregroundColor(type.color)
                .frame(width: 24)

            Text(type.displayName)
                .font(.subheadline)

            Spacer()

            if let summary = summary, let mood = summary.moodOption {
                HStack(spacing: 4) {
                    Text(mood.emoji)
                    Text(mood.displayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } else {
                Text("Not completed")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
