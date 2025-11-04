//
//  CanvasLinkView.swift
//  WalkWorthy
//
//  Guides students through pasting their Canvas calendar feed (read-only iCal).
//

import SwiftUI
import UIKit

struct CanvasLinkView: View {
    @EnvironmentObject private var appState: AppState
    private let config = Config.shared

    @State private var showInstructions = false
    @State private var calendarUrl = ""
    @State private var isSaving = false
    @State private var saveError: String?
    @State private var saveSuccess: String?
    @State private var hasLoadedStatus = false
    @FocusState private var isURLFieldFocused: Bool

    private let videoURL = URL(string: "https://embed.app.guidde.com/playbooks/dWssxANX5cthPMjTysXfia")

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if shouldUseLiveFlow {
                liveContent
            } else {
                mockContent
            }
        }
        .glassCard()
        .animation(.spring(response: 0.45, dampingFraction: 0.85), value: appState.isCanvasLinked)
        .sheet(isPresented: $showInstructions) {
            CalendarInstructionsSheet(videoURL: videoURL)
        }
        .onAppear(perform: syncFromState)
        .onChange(of: appState.calendarLinkStatus) { _ in
            syncInputFromStatus()
        }
    }

    private var shouldUseLiveFlow: Bool {
        config.apiMode == "live" && !appState.useFakeCanvas
    }

    // MARK: - Live flow

    private var liveContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            liveHeader

            if let host = config.canvasBaseURL?.host {
                Text("Canvas domain: \(host)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let status = appState.calendarLinkStatus {
                LiveStatusDetail(status: status)
            } else {
                Text("Paste the same read-only calendar link you would add to Outlook or Google Calendar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button {
                showInstructions = true
            } label: {
                Label("See step-by-step guide", systemImage: "list.bullet.rectangle")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding()
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            if let videoURL {
                Link(destination: videoURL) {
                    Label("Watch the walkthrough video", systemImage: "play.rectangle.fill")
                        .font(.footnote.bold())
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Paste your Canvas calendar link (.ics)")
                    .font(.subheadline.bold())
                TextField("https://school.instructure.com/feeds/calendars/user_123.ics", text: $calendarUrl, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled(true)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .focused($isURLFieldFocused)
                    .lineLimit(1...3)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1.2)
                    )
            }

            if let saveError {
                Text(saveError)
                    .font(.footnote)
                    .foregroundStyle(Color.red)
            }

            if let saveSuccess {
                Text(saveSuccess)
                    .font(.footnote)
                    .foregroundStyle(Color.green)
            }

            Button(action: saveLink) {
                HStack {
                    if isSaving {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                        Text(appState.isCanvasLinked ? "Update calendar link" : "Save calendar link")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.85), Color.accentColor],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .foregroundStyle(Color.white)
            }
            .buttonStyle(.plain)
            .disabled(isSaving)

            if appState.calendarLinkStatus != nil {
                Button(role: .destructive, action: removeLink) {
                    Label("Remove calendar link", systemImage: "trash")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .disabled(isSaving)
            }

            Text("WalkWorthy only reads this feed — it never writes to Canvas and requires no developer key.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var liveHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: statusIconName)
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(statusAccentColor)
            VStack(alignment: .leading, spacing: 6) {
                Text(statusHeadline)
                    .font(.headline)
                Text(statusSubheadline)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var statusHeadline: String {
        switch linkState {
        case .active: return "Canvas calendar linked"
        case .pending: return "Connect your Canvas calendar"
        case .error: return "Calendar link needs attention"
        case .migrationRequired: return "Update required"
        }
    }

    private var statusSubheadline: String {
        if let error = appState.calendarLinkStatus?.lastError, !error.isEmpty {
            return error
        }

        switch linkState {
        case .active:
            return "We’ll keep your assignments and exams in sync automatically."
        case .pending:
            return "Paste your personal Canvas calendar feed to unlock tailored encouragement."
        case .migrationRequired:
            return "Canvas OAuth tokens are no longer supported. Paste your read-only calendar feed instead."
        case .error:
            return "Try copying the Calendar Feed link again from Canvas."
        }
    }

    private var statusIconName: String {
        switch linkState {
        case .active: return "checkmark.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        case .migrationRequired: return "arrow.triangle.2.circlepath.circle.fill"
        case .pending: return "link"
        }
    }

    private var statusAccentColor: Color {
        switch linkState {
        case .active: return Color.green
        case .error: return Color.red
        case .migrationRequired: return Color.orange
        case .pending: return Color.accentColor
        }
    }

    private var linkState: CalendarLinkStatus.LinkState {
        appState.calendarLinkStatus?.status ?? .pending
    }

    private func saveLink() {
        guard !isSaving else { return }

        let value = calendarUrl
        isSaving = true
        saveError = nil
        saveSuccess = nil

        Task {
            do {
                let status = try await appState.submitCalendarLink(value)
                await MainActor.run {
                    isSaving = false
                    calendarUrl = status.calendarUrl ?? value
                    saveSuccess = status.status == .active
                        ? "Calendar link saved. We’ll refresh your schedule shortly."
                        : "Calendar link received. We’ll validate it and keep you posted."
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            } catch let inputError as AppState.CalendarLinkInputError {
                await MainActor.run {
                    isSaving = false
                    saveError = inputError.errorDescription ?? "Unable to save the calendar link."
                }
            } catch let apiError as APIError {
                await MainActor.run {
                    isSaving = false
                    saveError = apiError.errorDescription ?? "Unable to save the calendar link."
                }
            } catch {
                await MainActor.run {
                    isSaving = false
                    saveError = error.localizedDescription
                }
            }
        }
    }

    private func removeLink() {
        guard !isSaving else { return }

        isSaving = true
        saveError = nil
        saveSuccess = nil

        Task {
            await appState.removeCalendarLink()
            await MainActor.run {
                isSaving = false
                calendarUrl = ""
                saveSuccess = "Calendar link removed."
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
        }
    }

    private func syncFromState() {
        syncInputFromStatus()

        guard shouldUseLiveFlow, !hasLoadedStatus else { return }
        hasLoadedStatus = true
        Task {
            await appState.refreshCalendarLinkStatus(force: false)
        }
    }

    private func syncInputFromStatus() {
        guard !isSaving, !isURLFieldFocused else { return }
        let statusURL = appState.calendarLinkStatus?.calendarUrl ?? ""
        if calendarUrl.isEmpty || calendarUrl == statusURL {
            calendarUrl = statusURL
        }
    }

    // MARK: - Mock flow

    private var mockContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: appState.isCanvasLinked ? "checkmark.circle.fill" : "link")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(appState.isCanvasLinked ? Color.green : Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(appState.isCanvasLinked ? "Canvas linked (mock)" : "Link Canvas (mock)")
                        .font(.headline)
                    Text(appState.isCanvasLinked ? "We’ll surface assignments in encouragements." : "Tap to simulate a Canvas iCal flow. No credentials needed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Button(action: toggleMockLink) {
                Text(appState.isCanvasLinked ? "Unlink Canvas" : "Link Canvas (Mock)")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.85), Color.accentColor],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .foregroundStyle(Color.white)
            }
            .buttonStyle(.plain)

            Button {
                showInstructions = true
            } label: {
                Label("Preview the student instructions", systemImage: "list.bullet.rectangle")
                    .font(.footnote.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)

            if appState.isCanvasLinked {
                if let summary = appState.canvasSummary {
                    CanvasSummaryView(summary: summary)
                } else {
                    Text("Linked! Mock assignments will appear in your encouragements.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("The production app will collect a real Canvas calendar link here. In mock mode, this simply toggles simulated data.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func toggleMockLink() {
        appState.toggleCanvasLink()
        if appState.isCanvasLinked {
            appState.refreshCanvasSummary()
        }
    }
}

// MARK: - Supporting views

private struct LiveStatusDetail: View {
    let status: CalendarLinkStatus

    private var lastValidatedText: String? {
        guard let lastValidatedAt = status.lastValidatedAt else { return nil }
        return lastValidatedAt.formatted(.relative(presentation: .named))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let url = status.calendarUrl, !url.isEmpty {
                Text("Current link: \(url)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if let lastValidatedText {
                Text("Last checked \(lastValidatedText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let lastSynced = status.lastSyncedAt {
                Text("Last synced \(lastSynced.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let syncStatus = status.lastSyncStatus, syncStatus.uppercased() == "ERROR",
               let message = status.lastSyncError, !message.isEmpty {
                Text("Latest sync error: \(message)")
                    .font(.caption)
                    .foregroundStyle(Color.orange)
            }
            if status.status == .error, let message = status.lastError, !message.isEmpty {
                Text("Latest error: \(message)")
                    .font(.caption)
                    .foregroundStyle(Color.red)
            }
        }
    }
}

private struct CanvasSummaryView: View {
    let summary: TodayCanvas

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !summary.assignmentsToday.isEmpty {
                Text("Assignments today")
                    .font(.caption.bold())
                ForEach(summary.assignmentsToday.prefix(3)) { assignment in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(assignment.title)
                            .font(.footnote.bold())
                        Text("Due at \(assignment.dueAt)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !summary.examsToday.isEmpty {
                Text("Exams today")
                    .font(.caption.bold())
                    .padding(.top, summary.assignmentsToday.isEmpty ? 0 : 8)
                ForEach(summary.examsToday.prefix(3)) { exam in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(exam.title)
                            .font(.footnote.bold())
                        Text(exam.when)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct CalendarInstructionsSheet: View {
    @Environment(\.dismiss) private var dismiss
    let videoURL: URL?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    InstructionStep(
                        number: 1,
                        title: "Open the Canvas calendar",
                        detail: "Sign in to Canvas in Safari, then tap the Calendar icon on the left sidebar.",
                        placeholderText: "Placeholder for Canvas calendar icon screenshot"
                    )

                    InstructionStep(
                        number: 2,
                        title: "Open calendar settings",
                        detail: "Select the gear icon on the right side of the calendar view to reveal the Calendar Feed option.",
                        placeholderText: "Placeholder for Canvas calendar settings screenshot"
                    )

                    InstructionStep(
                        number: 3,
                        title: "Copy your calendar feed",
                        detail: "Tap “Copy Calendar Feed” — this copies your personal .ics link to the clipboard.",
                        placeholderText: "Placeholder for Canvas calendar feed modal screenshot"
                    )

                    InstructionStep(
                        number: 4,
                        title: "Paste it into WalkWorthy",
                        detail: "Return to WalkWorthy, paste the link, and tap “Save calendar link.” The feed is read-only, just like when you add it to Outlook or Google Calendar.",
                        placeholderText: "Placeholder for WalkWorthy paste screen screenshot"
                    )

                    if let videoURL {
                        Link(destination: videoURL) {
                            Label("Watch the walkthrough video", systemImage: "play.rectangle.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                    }

                    Text("Your Canvas account stays read-only — WalkWorthy only downloads the calendar feed to understand upcoming assignments and exams.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 8)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 28)
            }
            .navigationTitle("Connect Canvas")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct InstructionStep: View {
    let number: Int
    let title: String
    let detail: String
    let placeholderText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(number)")
                    .font(.title2.bold())
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.white)
                    .background(Color.accentColor, in: Circle())
                    .accessibilityLabel("Step \(number)")
                Text(title)
                    .font(.headline)
            }

            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
                .frame(height: 160)
                .overlay(
                    Text(placeholderText)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding()
                )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
