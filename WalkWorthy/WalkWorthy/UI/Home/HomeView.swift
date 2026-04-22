//
//  HomeView.swift
//  WalkWorthy
//
//  Primary mood check-in and encouragement feed.
//

import SwiftUI

struct HomeView: View {
    @Binding var selectedTab: Int
    @EnvironmentObject private var appState: AppState
    @State private var activeCheckInType: CheckInType?
    @State private var showNameSheet: Bool = false

    var body: some View {
        ZStack {
            DynamicBackgroundView()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: scaled(24)) {
                    // Soft prompt for users who never entered a first name.
                    // Auto-hides once the name is filled in or the user dismisses.
                    if shouldShowNameBackfillBanner {
                        NameBackfillBanner(
                            onAdd: { showNameSheet = true },
                            onDismiss: { appState.setNameBackfillDismissed(true) }
                        )
                        .transition(.opacity)
                    }

                    // Greeting header
                    greetingHeader

                    // Mood check-in card (if available)
                    if let checkInType = appState.currentCheckInType {
                        checkInCard(for: checkInType)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.95).combined(with: .opacity),
                                removal: .opacity
                            ))
                    }

                    // Today's check-in progress
                    todayProgressCard

                    // Daily reflection
                    if appState.dailyReflection != nil {
                        DailyReflectionCard(reflection: appState.dailyReflection)
                    }

                    // Verse of the Day
                    DailyVerseCard()

                    // Quick actions
                    quickActions
                }
                .padding(.horizontal, scaled(24))
                .padding(.top, scaled(8))
                .padding(.bottom, scaled(120))
            }
            .scrollContentBackground(.hidden)
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("WalkWorthy")
                    .font(.newsreaderSemiBoldItalic(fixedSize: scaled(20)))
            }
        }
        .onAppear {
            Task {
                await appState.loadMoodStatus()
            }
        }
        .sheet(item: $activeCheckInType) { type in
            MoodCheckInView(checkInType: type) {
                activeCheckInType = nil
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $showNameSheet) {
            // Reuses the existing OnboardingForm. In "edit existing profile"
            // mode it dismisses itself on save, closing this sheet naturally.
            OnboardingForm()
        }
    }

    // MARK: - Name backfill banner visibility

    private var shouldShowNameBackfillBanner: Bool {
        guard appState.isAuthenticated else { return false }
        guard appState.authenticatedUserSub != nil else { return false }
        guard !appState.nameBackfillDismissed else { return false }
        // Two-step gate:
        // 1. If we have a live profile, show the banner only when firstName is
        //    empty — the authoritative backend signal.
        // 2. If the profile is nil (e.g. cold-launch-while-offline before the
        //    backend fetch resolves), fall back to the persisted
        //    `hasCompletedProfileSetup` flag so users who set their name
        //    months ago don't see the banner again. Only show when we have no
        //    signal whatsoever that setup happened.
        if let profile = appState.currentProfile {
            let name = profile.firstName.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty
        }
        return !appState.hasCompletedProfileSetup
    }

    private var greetingHeader: some View {
        VStack(alignment: .leading, spacing: scaled(16)) {
            Text(timeBasedGreeting)
                .font(.newsreaderSemiBoldItalic(fixedSize: scaled(40)))
                .foregroundStyle(.primary)

            Text(motivationalSubtitle)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, scaled(8))
    }

    private var timeBasedGreeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let base: String
        switch hour {
        case 3..<12:
            base = "Good morning"
        case 12..<17:
            base = "Good afternoon"
        case 17..<22:
            base = "Good evening"
        default:
            base = "Good night"
        }
        let name = (appState.currentProfile?.firstName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? base : "\(base), \(name)"
    }

    /// Tone categories for the greeting subtitle, derived from profile identity markers.
    private enum SubtitleTone {
        case student
        case professional
        case none
    }

    /// If the user has a major, treat them as a student; else if they have an occupation,
    /// treat them as a professional; else fall back to the original generic tone.
    private var subtitleTone: SubtitleTone {
        guard let profile = appState.currentProfile else { return .none }
        let hasMajor = !profile.major.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasOccupation = !profile.occupation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if hasMajor { return .student }
        if hasOccupation { return .professional }
        return .none
    }

    private var motivationalSubtitle: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch (subtitleTone, hour) {
        // Student tone
        case (.student, 3..<12):
            return "A quiet moment before the day begins."
        case (.student, 12..<17):
            return "A breath between classes."
        case (.student, 17..<22):
            return "How did your day of learning feel?"
        case (.student, _):
            return "Rest up — tomorrow holds more to learn."

        // Professional tone
        case (.professional, 3..<12):
            return "Catch your breath before the day starts."
        case (.professional, 12..<17):
            return "A breath between meetings."
        case (.professional, 17..<22):
            return "How did work feel today?"
        case (.professional, _):
            return "Rest well. Tomorrow is its own day."

        // Default (no identity markers yet)
        case (.none, 3..<12):
            return "Let's start the day with intention."
        case (.none, 12..<17):
            return "Pause and check in with yourself."
        case (.none, 17..<22):
            return "Reflect on how today went."
        case (.none, _):
            return "Rest well and prepare for tomorrow."
        }
    }

    private func checkInCard(for type: CheckInType) -> some View {
        Button {
            activeCheckInType = type
        } label: {
            HStack(spacing: scaled(16)) {
                // Icon
                ZStack {
                    Circle()
                        .fill(type.color.opacity(0.2))
                        .frame(width: scaled(56), height: scaled(56))

                    Image(systemName: type.iconName)
                        .font(.system(size: scaled(24)))
                        .foregroundColor(type.color)
                }

                // Text
                VStack(alignment: .leading, spacing: scaled(4)) {
                    Text(type.displayName + " Check-in")
                        .font(.newsreaderSemiBoldItalic(fixedSize: scaled(17)))
                        .foregroundColor(.primary)

                    Text("How are you feeling?")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
            }
            .padding(scaled(20))
            .background(
                RoundedRectangle(cornerRadius: scaled(20), style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: scaled(20), style: .continuous)
                            .fill(Color.black.opacity(0.30))
                    )
                    .shadow(color: type.color.opacity(0.15), radius: scaled(10), y: scaled(5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: scaled(20), style: .continuous)
                    .stroke(type.color.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var todayProgressCard: some View {
        VStack(alignment: .leading, spacing: scaled(16)) {
            Text("Today's Check-ins")
                .font(.newsreaderSemiBoldItalic(fixedSize: scaled(17)))

            HStack(spacing: scaled(16)) {
                checkInStatusPill(type: .morning, completed: appState.currentMoodStatus?.summary?.morning != nil)
                checkInStatusPill(type: .midday, completed: appState.currentMoodStatus?.summary?.midday != nil)
                checkInStatusPill(type: .evening, completed: appState.currentMoodStatus?.summary?.evening != nil)
            }
        }
        .padding(scaled(20))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: scaled(20), style: .continuous)
                .fill(Color.wwRecessedBackground)
        )
    }

    private func checkInStatusPill(type: CheckInType, completed: Bool) -> some View {
        VStack(spacing: scaled(8)) {
            ZStack {
                Circle()
                    .fill(completed ? type.color : Color(.systemGray5))
                    .frame(width: scaled(44), height: scaled(44))

                if completed {
                    Image(systemName: "checkmark")
                        .font(.system(size: scaled(18), weight: .semibold))
                        .foregroundColor(.white)
                } else {
                    Image(systemName: type.iconName)
                        .font(.system(size: scaled(16)))
                        .foregroundColor(.secondary)
                }
            }

            Text(type.displayName)
                .font(.caption)
                .foregroundColor(completed ? .primary : .secondary)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            guard completed else { return }
            // Allow updating a previously completed check-in
            activeCheckInType = type
        }
        .opacity(completed ? 1.0 : 0.7)
    }

    private var quickActions: some View {
        VStack(spacing: scaled(12)) {
            Button {
                selectedTab = 1
            } label: {
                Label("View History", systemImage: "calendar")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassButtonStyle())
        }
    }

}

private struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: scaled(18), style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: scaled(18), style: .continuous)
                    .stroke(Color.white.opacity(configuration.isPressed ? 0.3 : 0.15), lineWidth: 1)
            )
            .foregroundStyle(.primary)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

/// Soft, dismissible prompt shown on Home for users who haven't set a first name.
/// Tapping the card opens the full profile editor; tapping the × dismisses persistently.
private struct NameBackfillBanner: View {
    let onAdd: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: scaled(14)) {
            Image(systemName: "hand.wave.fill")
                .font(.system(size: scaled(22)))
                .foregroundStyle(Color.accentColor)
                .frame(width: scaled(44), height: scaled(44))
                .background(Circle().fill(Color.accentColor.opacity(0.15)))

            VStack(alignment: .leading, spacing: scaled(2)) {
                Text("Add your name")
                    .font(.newsreaderSemiBoldItalic(fixedSize: scaled(17)))
                    .foregroundColor(.primary)
                Text("Get a personal greeting on Home.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: scaled(13), weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: scaled(30), height: scaled(30))
                    .background(Circle().fill(Color.secondary.opacity(0.15)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(scaled(16))
        .background(
            RoundedRectangle(cornerRadius: scaled(20), style: .continuous)
                .fill(Color.wwRecessedBackground)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onAdd)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Double-tap to add your first name.")
    }
}
