//
//  MoodLogView.swift
//  WalkWorthy
//
//  Settings → Check-in log deep-dive view. A day-grouped feed where each
//  check-in shows its mood data, emotion tags, impact categories, note,
//  and AI encouragement — with any linked journal entries nested beneath
//  it and standalone journal entries (no linkedCheckInId) shown as their
//  own cards under the same day header.
//
//  Distinct from the History tab (MoodHistoryView, which is aggregate /
//  chart-oriented) and the Journal tab (JournalListView, which is writing-
//  oriented). This screen is the "everything about my mood + journal in
//  one place" power-user view.
//

import SwiftUI
import SwiftData

// MARK: - Shared formatters

private let moodLogISODateFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd"
    f.locale = Locale(identifier: "en_US_POSIX")
    return f
}()

private let moodLogDayHeaderFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "EEEE, MMM d"
    f.locale = Locale.current
    return f
}()

private let moodLogTimeFormatter: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()

private let moodLogTimeFormatterFallback: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

private let moodLogTimeDisplayFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "h:mm a"
    f.locale = Locale.current
    return f
}()

// MARK: - Grouping model

private enum MoodLogEntry: Identifiable {
    case checkIn(MoodCheckIn, linkedJournals: [JournalEntry])
    case standaloneJournal(JournalEntry)

    var id: String {
        switch self {
        case .checkIn(let ci, _): return "ci-\(ci.id)"
        case .standaloneJournal(let j): return "j-\(j.id)"
        }
    }
}

private struct MoodLogDay: Identifiable {
    let date: String               // YYYY-MM-DD
    var entries: [MoodLogEntry]
    var id: String { date }
}

// MARK: - Main view

/// Thin wrapper that reads `authenticatedUserSub` from AppState and feeds it
/// into the content view so the journal `@Query` is scoped per-user at
/// view-build time. Prevents cross-user data leaks on shared devices.
struct MoodLogView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        MoodLogContent(userSub: appState.authenticatedUserSub)
            .id(appState.authenticatedUserSub ?? "__unauthenticated__")
    }
}

private struct MoodLogContent: View {
    @EnvironmentObject private var appState: AppState
    @Query private var allJournalEntries: [JournalEntry]

    @State private var checkIns: [MoodCheckIn] = []
    @State private var isLoading: Bool = false
    @State private var hasMore: Bool = true
    @State private var oldestLoadedDate: String? = nil
    @State private var errorMessage: String? = nil
    /// How many day-window pages are currently loaded. `loadFirstPage()`
    /// resets it to 1 (full first-page replacement); `loadOlder()` increments
    /// it. Drives the `.task` guard — item counts can't, because `pageSize`
    /// is a DAYS window (up to 3 check-ins per day, so page 1 alone can hold
    /// more than `pageSize` items).
    @State private var loadedPages: Int = 1

    private static let pageSize: Int = 14

    init(userSub: String?) {
        let sub = userSub ?? "__unauthenticated__"
        _allJournalEntries = Query(
            filter: #Predicate<JournalEntry> { $0.userSub == sub },
            sort: \JournalEntry.createdAt,
            order: .reverse
        )
    }

    var body: some View {
        ZStack {
            TimeOfDayTheme.current.backdrop
                .ignoresSafeArea()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: scaled(20)) {
                    intro
                    ForEach(logDays) { day in
                        MoodLogDaySection(day: day)
                    }
                    footer
                }
                .padding(.horizontal, scaled(10))
                .padding(.vertical, scaled(24))
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("Check-in log")
        .toolbarTitleDisplayMode(.inline)
        .task {
            // Only one page loaded — don't clobber a paged-back session.
            // Re-running .task on tab revisit refreshes page 1 (full
            // replacement), which would silently drop pages loaded via
            // loadOlder(), so skip the auto-refetch once the user has paged
            // back. Pull-to-refresh remains available in that state.
            if loadedPages <= 1 {
                await loadFirstPage()
            }
        }
        .refreshable { await loadFirstPage() }
    }

    // MARK: Subviews

    private var intro: some View {
        Text("Your check-ins, tags, and journal entries together.")
            .font(.body)
            .foregroundStyle(.secondary)
            .padding(.bottom, scaled(4))
    }

    @ViewBuilder
    private var footer: some View {
        if isLoading && checkIns.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.top, scaled(40))
        } else if checkIns.isEmpty && allJournalEntries.isEmpty {
            emptyState
        } else if let errorMessage {
            VStack(spacing: scaled(10)) {
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                Button("Try again") {
                    Task { await loadFirstPage() }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, scaled(12))
        } else if hasMore {
            Button {
                Task { await loadOlder() }
            } label: {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, scaled(4))
                } else {
                    Label("Load older (\(Self.pageSize) more days)", systemImage: "arrow.down.circle")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .padding(.top, scaled(8))
            .disabled(isLoading)
        } else {
            Text("That's the beginning of your log.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.top, scaled(12))
        }
    }

    private var emptyState: some View {
        VStack(spacing: scaled(12)) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: scaled(36)))
                .foregroundStyle(.secondary)
            Text("No check-ins yet")
                .font(.newsreaderSemiBoldItalic(size: scaled(20)))
            Text("Your log will appear here after your first check-in.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, scaled(60))
    }

    // MARK: Grouping

    /// Merge loaded check-ins with SwiftData journal entries into day sections.
    /// Check-ins come first within a day (morning → midday → evening), then
    /// any standalone journal entries (no linkedCheckInId, or whose link points
    /// to a check-in outside the loaded window).
    private var logDays: [MoodLogDay] {
        let windowStart = oldestLoadedDate ?? Self.dateString(daysAgo: Self.pageSize)
        let journalsInWindow = allJournalEntries.filter { $0.date >= windowStart }
        let checkInIds = Set(checkIns.map { $0.id })

        var byDate: [String: MoodLogDay] = [:]

        for checkIn in checkIns {
            let linked = journalsInWindow.filter { $0.linkedCheckInId == checkIn.id }
            byDate[checkIn.date, default: MoodLogDay(date: checkIn.date, entries: [])]
                .entries.append(.checkIn(checkIn, linkedJournals: linked))
        }

        for journal in journalsInWindow {
            let isStandalone: Bool = {
                guard let link = journal.linkedCheckInId else { return true }
                // Treat as standalone if the linked check-in isn't in the current window
                return !checkInIds.contains(link)
            }()
            if isStandalone {
                byDate[journal.date, default: MoodLogDay(date: journal.date, entries: [])]
                    .entries.append(.standaloneJournal(journal))
            }
        }

        // Sort entries within each day: check-ins first by type order, then standalones by createdAt desc
        for date in byDate.keys {
            byDate[date]?.entries.sort { a, b in
                switch (a, b) {
                case (.checkIn(let lhs, _), .checkIn(let rhs, _)):
                    return Self.typeOrder(lhs.checkInType) < Self.typeOrder(rhs.checkInType)
                case (.checkIn, .standaloneJournal):
                    return true
                case (.standaloneJournal, .checkIn):
                    return false
                case (.standaloneJournal(let lhs), .standaloneJournal(let rhs)):
                    return lhs.createdAt > rhs.createdAt
                }
            }
        }

        // Days: newest first
        return byDate.keys.sorted(by: >).compactMap { byDate[$0] }
    }

    private static func typeOrder(_ raw: String) -> Int {
        switch raw {
        case "morning": return 0
        case "midday":  return 1
        case "evening": return 2
        default:        return 3
        }
    }

    private static func dateString(daysAgo: Int) -> String {
        let d = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return moodLogISODateFormatter.string(from: d)
    }

    private static func dateByOffsetting(_ dateString: String, days: Int) -> String? {
        guard let date = moodLogISODateFormatter.date(from: dateString),
              let shifted = Calendar.current.date(byAdding: .day, value: days, to: date)
        else { return nil }
        return moodLogISODateFormatter.string(from: shifted)
    }

    // MARK: Loading

    private func loadFirstPage() async {
        // Lazily hydrate the AppState cache from disk on first visit. This
        // snapshot is the largest one (up to 14 check-ins with full AI text),
        // and this screen is a Settings deep-dive most sessions never open —
        // so the sync decode happens here, not on the cold-launch path in
        // `AppState.hydrateFromSnapshots`.
        if checkIns.isEmpty && appState.moodLogFirstPage.isEmpty,
           let sub = appState.authenticatedUserSub,
           let snapshot: Snapshot<[MoodCheckIn]> = SnapshotStore.shared.readSync(
               [MoodCheckIn].self, kind: .moodLogFirstPage, userSub: sub
           ) {
            appState.moodLogFirstPage = snapshot.payload
        }

        // Seed from the last-known snapshot so the ProgressView doesn't flash
        // on cold launch. The fetch below then replaces the whole first page.
        // Note (offline-only cosmetic case): the seeded page may span fewer
        // days than the journal window, so a linked journal can render
        // standalone until the refetch lands.
        if checkIns.isEmpty && !appState.moodLogFirstPage.isEmpty {
            checkIns = appState.moodLogFirstPage
            oldestLoadedDate = Self.dateString(daysAgo: Self.pageSize)
            hasMore = true
        }

        // Capture the account that owns this fetch before the await, so a
        // sign-out + another sign-in mid-fetch can't persist this user's log
        // into the next user's cache (publishMoodLogFirstPage re-checks it).
        let requestSub = appState.authenticatedUserSub
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let response = try await appState.loadMoodLog(days: Self.pageSize, endDate: nil)
            checkIns = response.checkIns
            oldestLoadedDate = Self.dateString(daysAgo: Self.pageSize)
            // If the backend returned fewer docs than we asked for, assume there may still
            // be older data in Firestore — only mark hasMore=false when user has paged back
            // and explicitly gets an empty response.
            hasMore = true
            // Full first-page replacement — back to a single loaded page.
            loadedPages = 1

            // Publish to AppState + snapshot so the next cold launch renders
            // instantly. Guarded on the captured account.
            let page = Array(response.checkIns.prefix(Self.pageSize))
            if let requestSub {
                await appState.publishMoodLogFirstPage(page, requestSub: requestSub)
            }
        } catch {
            #if DEBUG
            print("[MoodLogView] loadFirstPage failed: \(error)")
            #endif
            errorMessage = "Couldn't load your check-in log."
        }
    }

    private func loadOlder() async {
        guard let oldest = oldestLoadedDate,
              let priorEnd = Self.dateByOffsetting(oldest, days: -1)
        else { return }

        isLoading = true
        defer { isLoading = false }
        do {
            let response = try await appState.loadMoodLog(days: Self.pageSize, endDate: priorEnd)
            if response.checkIns.isEmpty {
                hasMore = false
            } else {
                // Dedup by id in case of overlap
                let existingIds = Set(checkIns.map { $0.id })
                let additions = response.checkIns.filter { !existingIds.contains($0.id) }
                checkIns.append(contentsOf: additions)
                if let newOldest = Self.dateByOffsetting(oldest, days: -Self.pageSize) {
                    oldestLoadedDate = newOldest
                }
                loadedPages += 1
            }
        } catch {
            #if DEBUG
            print("[MoodLogView] loadOlder failed: \(error)")
            #endif
            errorMessage = "Couldn't load older entries."
        }
    }
}

// MARK: - Day section

private struct MoodLogDaySection: View {
    let day: MoodLogDay

    var body: some View {
        VStack(alignment: .leading, spacing: scaled(12)) {
            Text(dayHeaderText)
                .font(.newsreaderSemiBoldItalic(size: scaled(20)))
                .foregroundStyle(.primary)

            ForEach(day.entries) { entry in
                switch entry {
                case .checkIn(let checkIn, let linkedJournals):
                    MoodLogCheckInCard(checkIn: checkIn, linkedJournals: linkedJournals)
                case .standaloneJournal(let journal):
                    MoodLogStandaloneJournalCard(journal: journal)
                }
            }
        }
    }

    private var dayHeaderText: String {
        if let d = moodLogISODateFormatter.date(from: day.date) {
            return moodLogDayHeaderFormatter.string(from: d)
        }
        return day.date
    }
}

// MARK: - Check-in card

private struct MoodLogCheckInCard: View {
    let checkIn: MoodCheckIn
    let linkedJournals: [JournalEntry]

    private var typeEnum: CheckInType? {
        CheckInType(rawValue: checkIn.checkInType)
    }

    private var moodLevelEnum: MoodLevel? {
        guard let raw = checkIn.moodSpectrumData?.moodLevel else { return nil }
        return MoodLevel(rawValue: raw)
    }

    private var displayTime: String {
        let parsed = moodLogTimeFormatter.date(from: checkIn.timestamp)
            ?? moodLogTimeFormatterFallback.date(from: checkIn.timestamp)
        guard let date = parsed else { return "" }
        return moodLogTimeDisplayFormatter.string(from: date)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: scaled(14)) {
            header

            if let data = checkIn.moodSpectrumData {
                if !data.emotionTags.isEmpty {
                    pillRow(title: "Feelings", items: data.emotionTags, style: .emotion)
                }
                if !data.impactCategories.isEmpty {
                    pillRow(title: "Impacting", items: data.impactCategories, style: .impact)
                }
                if let note = data.note, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    noteBlock(note)
                }
            }

            aiResponseBlock

            if !linkedJournals.isEmpty {
                linkedJournalsBlock
            }
        }
        .padding(scaled(18))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: scaled(18), style: .continuous)
                .fill(Color.wwCardBackground)
        )
        .overlay(alignment: .leading) {
            // Subtle check-in-type accent stripe on the leading edge.
            if let type = typeEnum {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(type.color.opacity(0.7))
                    .frame(width: 3)
                    .padding(.vertical, scaled(14))
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: scaled(10)) {
            if let type = typeEnum {
                Image(systemName: type.iconName)
                    .font(.system(size: scaled(18), weight: .semibold))
                    .foregroundStyle(type.color)
                    .frame(width: scaled(32), height: scaled(32))
                    .background(Circle().fill(type.color.opacity(0.15)))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(typeEnum?.displayName ?? checkIn.checkInType.capitalized)
                    .font(.newsreaderSemiBoldItalic(size: scaled(17)))
                    .foregroundStyle(.primary)
                if !displayTime.isEmpty {
                    Text(displayTime)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if let moodLevel = moodLevelEnum {
                moodPill(moodLevel)
            }

            if let score = checkIn.moodSpectrumData?.moodScore {
                Text("\(score)/10")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, scaled(8))
                    .padding(.vertical, scaled(4))
                    .background(
                        Capsule().fill(Color.secondary.opacity(0.15))
                    )
            }
        }
    }

    private func moodPill(_ level: MoodLevel) -> some View {
        Text(level.displayName)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, scaled(10))
            .padding(.vertical, scaled(4))
            .background(
                Capsule().fill(pillColor(for: level).opacity(0.25))
            )
            .overlay(
                Capsule().stroke(pillColor(for: level).opacity(0.5), lineWidth: 1)
            )
    }

    private func pillColor(for level: MoodLevel) -> Color {
        switch level {
        case .veryUnpleasant, .unpleasant: return .red
        case .neutral:                     return .gray
        case .pleasant, .veryPleasant:     return .green
        }
    }

    private enum PillStyle { case emotion, impact }

    private func pillRow(title: String, items: [String], style: PillStyle) -> some View {
        VStack(alignment: .leading, spacing: scaled(6)) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            FlowLayout(spacing: scaled(6)) {
                ForEach(items, id: \.self) { item in
                    Text(item)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, scaled(10))
                        .padding(.vertical, scaled(4))
                        .background(
                            Capsule().fill(
                                style == .emotion
                                    ? Color.accentColor.opacity(0.15)
                                    : Color.secondary.opacity(0.15)
                            )
                        )
                }
            }
        }
    }

    private func noteBlock(_ note: String) -> some View {
        HStack(alignment: .top, spacing: scaled(10)) {
            Image(systemName: "quote.opening")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(note)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(scaled(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: scaled(12), style: .continuous)
                .fill(Color.wwRecessedBackground)
        )
    }

    private var aiResponseBlock: some View {
        VStack(alignment: .leading, spacing: scaled(8)) {
            HStack(spacing: scaled(6)) {
                Image(systemName: "sparkles")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Encouragement")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Text(checkIn.aiResponse.message)
                .font(.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Text(checkIn.aiResponse.verseText)
                .font(.newsreader(size: scaled(15)))
                .foregroundStyle(.primary)
                .lineSpacing(scaled(3))
                .fixedSize(horizontal: false, vertical: true)

            Text("— \(checkIn.aiResponse.verseRef) · \(checkIn.aiResponse.translation)")
                .font(.newsreaderSemiBoldItalic(size: scaled(12)))
                .foregroundStyle(.secondary)
        }
        .padding(.top, scaled(4))
    }

    private var linkedJournalsBlock: some View {
        VStack(alignment: .leading, spacing: scaled(8)) {
            HStack(spacing: scaled(6)) {
                Image(systemName: "link")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Journal entries")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            ForEach(linkedJournals) { journal in
                NavigationLink {
                    JournalEditorView(mode: .existing(journal))
                } label: {
                    MoodLogJournalRow(journal: journal)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, scaled(4))
    }
}

// MARK: - Journal rows

private struct MoodLogJournalRow: View {
    let journal: JournalEntry

    var body: some View {
        HStack(alignment: .top, spacing: scaled(10)) {
            if journal.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
            } else {
                Image(systemName: "book")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 1)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(previewText)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(timeString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary.opacity(0.6))
        }
        .padding(scaled(12))
        .background(
            RoundedRectangle(cornerRadius: scaled(12), style: .continuous)
                .fill(Color.wwRecessedBackground)
        )
    }

    private var previewText: String {
        let trimmed = journal.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(empty entry)" : trimmed
    }

    private var timeString: String {
        moodLogTimeDisplayFormatter.string(from: journal.createdAt)
    }
}

private struct MoodLogStandaloneJournalCard: View {
    let journal: JournalEntry

    var body: some View {
        NavigationLink {
            JournalEditorView(mode: .existing(journal))
        } label: {
            VStack(alignment: .leading, spacing: scaled(8)) {
                HStack(spacing: scaled(8)) {
                    Image(systemName: journal.isPinned ? "pin.fill" : "book.fill")
                        .font(.caption)
                        .foregroundStyle(journal.isPinned ? .orange : .secondary)
                    Text("Journal entry")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(timeString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Text(previewText)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(scaled(16))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: scaled(18), style: .continuous)
                    .fill(Color.wwCardBackground)
            )
        }
        .buttonStyle(.plain)
    }

    private var previewText: String {
        let trimmed = journal.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(empty entry)" : trimmed
    }

    private var timeString: String {
        moodLogTimeDisplayFormatter.string(from: journal.createdAt)
    }
}

// MARK: - Simple flow layout for pill rows

/// Minimal wrap-to-next-line layout used for emotion/impact pill rows.
/// Avoids pulling in a third-party library for a single use case.
private struct FlowLayout: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var totalHeight: CGFloat = 0
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width + (rowWidth > 0 ? spacing : 0) > maxWidth {
                totalHeight += rowHeight + (totalHeight > 0 ? spacing : 0)
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += size.width + (rowWidth > 0 ? spacing : 0)
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        return CGSize(width: maxWidth.isFinite ? maxWidth : rowWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
