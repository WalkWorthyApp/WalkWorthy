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

    var body: some View {
        ZStack {
            DynamicBackgroundView()
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: scaled(24)) {
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
        switch hour {
        case 3..<12:
            return "Good morning"
        case 12..<17:
            return "Good afternoon"
        case 17..<22:
            return "Good evening"
        default:
            return "Good night"
        }
    }

    private var motivationalSubtitle: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 3..<12:
            return "Let's start the day with intention."
        case 12..<17:
            return "Pause and check in with yourself."
        case 17..<22:
            return "Reflect on how today went."
        default:
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
                    .fill(Color(.systemBackground))
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
                .fill(.ultraThinMaterial)
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
