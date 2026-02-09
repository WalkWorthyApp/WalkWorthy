//
//  HomeView.swift
//  WalkWorthy
//
//  Primary mood check-in and encouragement feed.
//

import SwiftUI

// Wrapper to make MoodCheckInResponse identifiable for sheet(item:)
private struct ResponseWrapper: Identifiable {
    let id: String
    let response: MoodCheckInResponse
    let selectedMood: MoodOption?

    init(response: MoodCheckInResponse, selectedMood: MoodOption?) {
        self.id = response.checkInId
        self.response = response
        self.selectedMood = selectedMood
    }
}

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @State private var activeCheckInType: CheckInType?
    @State private var pendingResponse: ResponseWrapper?
    @State private var completedResponse: ResponseWrapper?

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 24) {
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

                // Today's progress
                todayProgressCard

                // Latest encouragement
                if let response = appState.latestMoodResponse {
                    latestEncouragementCard(response)
                }

                // Quick actions
                quickActions
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 120)
        }
        .background(backgroundGradient)
        .navigationTitle("WalkWorthy")
        .toolbarTitleDisplayMode(.inline)
        .onAppear {
            Task {
                await appState.loadMoodStatus()
            }
        }
        .sheet(item: $activeCheckInType, onDismiss: {
            // Present response sheet after check-in sheet fully dismisses
            if let pending = pendingResponse {
                completedResponse = pending
                pendingResponse = nil
            }
        }) { type in
            NavigationStack {
                MoodCheckInView(checkInType: type) { response, mood in
                    pendingResponse = ResponseWrapper(response: response, selectedMood: mood)
                    activeCheckInType = nil
                }
                .navigationTitle(type.displayName)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            activeCheckInType = nil
                        }
                    }
                }
            }
            .presentationDetents([.large])
        }
        .sheet(item: $completedResponse) { wrapper in
            NavigationStack {
                MoodResponseView(
                    response: wrapper.response,
                    mood: wrapper.selectedMood,
                    onDismiss: {
                        completedResponse = nil
                    }
                )
                .navigationBarTitleDisplayMode(.inline)
                .onDisappear {
                    completedResponse = nil
                }
            }
            .presentationDetents([.large])
        }
    }

    private var greetingHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(timeBasedGreeting)
                .font(.largeTitle.bold())
                .foregroundStyle(.primary)

            Text(motivationalSubtitle)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 12)
    }

    private var timeBasedGreeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:
            return "Good morning"
        case 12..<17:
            return "Good afternoon"
        case 17..<22:
            return "Good evening"
        default:
            return "Hello"
        }
    }

    private var motivationalSubtitle: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12:
            return "Let's start the day with intention."
        case 12..<17:
            return "Pause and check in with yourself."
        case 17..<22:
            return "Reflect on how today went."
        default:
            return "Take a moment for yourself."
        }
    }

    private func checkInCard(for type: CheckInType) -> some View {
        Button {
            activeCheckInType = type
        } label: {
            HStack(spacing: 16) {
                // Icon
                ZStack {
                    Circle()
                        .fill(type.color.opacity(0.2))
                        .frame(width: 56, height: 56)

                    Image(systemName: type.iconName)
                        .font(.system(size: 24))
                        .foregroundColor(type.color)
                }

                // Text
                VStack(alignment: .leading, spacing: 4) {
                    Text(type.displayName + " Check-in")
                        .font(.headline)
                        .foregroundColor(.primary)

                    Text("How are you feeling?")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .foregroundColor(.secondary)
            }
            .padding(20)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(.systemBackground))
                    .shadow(color: type.color.opacity(0.15), radius: 10, y: 5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(type.color.opacity(0.3), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var todayProgressCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Today's Check-ins")
                .font(.headline)

            HStack(spacing: 16) {
                checkInStatusPill(type: .morning, completed: appState.currentMoodStatus?.summary?.morning != nil)
                checkInStatusPill(type: .midday, completed: appState.currentMoodStatus?.summary?.midday != nil)
                checkInStatusPill(type: .evening, completed: appState.currentMoodStatus?.summary?.evening != nil)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }

    private func checkInStatusPill(type: CheckInType, completed: Bool) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(completed ? type.color : Color(.systemGray5))
                    .frame(width: 44, height: 44)

                if completed {
                    Image(systemName: "checkmark")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                } else {
                    Image(systemName: type.iconName)
                        .font(.system(size: 16))
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

    private func latestEncouragementCard(_ response: MoodCheckInResponse) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Latest Encouragement")
                    .font(.headline)

                Spacer()

                Text(response.aiResponse.verseRef)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(.accentColor)
            }

            Text(response.aiResponse.message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .lineLimit(3)

            Divider()

            Text(response.aiResponse.verseText)
                .font(.subheadline)
                .italic()
                .foregroundColor(.primary)
                .lineLimit(4)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.05), radius: 10, y: 5)
        )
    }

    private var quickActions: some View {
        VStack(spacing: 12) {
            NavigationLink {
                MoodHistoryView()
            } label: {
                Label("View History", systemImage: "calendar")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(GlassButtonStyle())
        }
    }

    private var backgroundGradient: some View {
        LinearGradient(
            colors: [Color(.systemBackground), Color(.systemIndigo).opacity(0.08), Color(.systemBackground)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}

private struct GlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding()
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(configuration.isPressed ? 0.3 : 0.15), lineWidth: 1)
            )
            .foregroundStyle(.primary)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}
