import SwiftUI

struct TodaysAgendaView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        NavigationStack {
            agendaContent
                .navigationTitle("Weekly Agenda")
                .task {
                    appState.refreshCalendarAgenda()
                }
        }
    }

    @ViewBuilder
    private var agendaContent: some View {
        let weeklyItems = appState.weeklyCalendarAgenda
        if weeklyItems.isEmpty {
            VStack(spacing: 16) {
                Image(systemName: "calendar")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Nothing scheduled this week")
                    .font(.headline)
                Text("Once Canvas has assignments or events for this week, they’ll appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .padding()
            .background(Color(.systemGroupedBackground))
        } else {
            List {
                Section(header: Text(appState.currentWeekLabel).font(.subheadline.weight(.semibold))) {
                    ForEach(weeklyItems) { item in
                        AgendaRow(item: item)
                    }
                }

                LegendView()
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 12, trailing: 16))
                    .listRowBackground(Color.clear)
            }
            .listStyle(.insetGrouped)
        }
    }
}

private struct AgendaRow: View {
    let item: CalendarAgendaItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: item.kind.iconName)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(colorForKind(item.kind))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.headline)
                    if let course = item.course, !course.isEmpty {
                        Text(course)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    if let detail = scheduleDescription(for: item) {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let location = item.location, !location.isEmpty {
                        Label(location, systemImage: "mappin.and.ellipse")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            if let url = item.url {
                Link(destination: url) {
                    Label("Open in Canvas", systemImage: "arrow.up.right.square")
                        .font(.caption.bold())
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func scheduleDescription(for item: CalendarAgendaItem) -> String? {
        let calendar = Calendar.current
        let dateFormatter = DateFormatter()
        dateFormatter.setLocalizedDateFormatFromTemplate("MMM d")
        dateFormatter.timeZone = .current
        let timeFormatter = DateFormatter()
        timeFormatter.setLocalizedDateFormatFromTemplate("h:mm a")
        timeFormatter.amSymbol = "am"
        timeFormatter.pmSymbol = "pm"
        timeFormatter.timeZone = .current

        switch item.kind {
        case .event:
            guard let rawStart = item.startAt ?? item.dueAt ?? item.endAt else { return nil }
            let start = displayDate(rawStart, for: item)
            let dateString = dateFormatter.string(from: start)
            if let rawEnd = item.endAt {
                let end = displayDate(rawEnd, for: item)
                if !calendar.isDate(start, equalTo: end, toGranularity: .minute) {
                    let startTime = timeFormatter.string(from: start)
                    let endTime = timeFormatter.string(from: end)
                    return "\(dateString) · \(startTime) – \(endTime)"
                }
            }
            return dateString
        case .assignment, .exam:
            guard let due = mostRelevantDate(for: item) else { return nil }
            let localizedDue = displayDate(due, for: item)
            let dateString = dateFormatter.string(from: localizedDue)
            return "Due: \(dateString)"
        }
    }

    private func mostRelevantDate(for item: CalendarAgendaItem) -> Date? {
        let calendar = Calendar.current

        if let due = item.dueAt {
            return due
        }

        if let start = item.startAt {
            return start
        }

        if let end = item.endAt {
            if isExclusiveEnd(end: end, calendar: calendar) {
                return calendar.date(byAdding: .day, value: -1, to: end)
            }
            return end
        }

        return nil
    }

    private func colorForKind(_ kind: CalendarAgendaKind) -> Color {
        switch kind {
        case .assignment: return .accentColor
        case .exam: return .red
        case .event: return .blue
        }
    }

    private func isExclusiveEnd(end: Date, calendar: Calendar) -> Bool {
        let components = calendar.dateComponents([.hour, .minute, .second], from: end)
        let isMidnight = (components.hour ?? 0) == 0 && (components.minute ?? 0) == 0 && (components.second ?? 0) == 0

        if !isMidnight {
            return false
        }

        return true
    }

    private func displayDate(_ date: Date, for item: CalendarAgendaItem) -> Date {
        guard isFloating(item.timeZoneId) else {
            return date
        }

        guard let utc = TimeZone(secondsFromGMT: 0) else { return date }
        var components = Calendar(identifier: .gregorian).dateComponents(in: utc, from: date)
        components.timeZone = TimeZone.current
        return Calendar.current.date(from: components) ?? date
    }

    private func isFloating(_ timeZoneId: String?) -> Bool {
        guard let id = timeZoneId else { return true }
        return id == "floating"
    }
}

private struct LegendView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Icon legend")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            HStack(spacing: 20) {
                legendRow(symbol: "doc.text", color: .accentColor, label: "Assignment")
                legendRow(symbol: "checkmark.seal", color: .red, label: "Quiz/Exam")
                legendRow(symbol: "calendar", color: .blue, label: "General Event")
            }
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private func legendRow(symbol: String, color: Color, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(label)
                .foregroundStyle(.secondary)
        }
    }
}
