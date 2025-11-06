//
//  RootView.swift
//  WalkWorthy
//
//  Coordinates onboarding and the main tab experience.
//

import SwiftUI

struct RootView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if appState.requiresAuthenticationGate {
                TitleScreenView()
                    .transition(.opacity)
            } else if appState.onboardingCompleted {
                MainTabView()
                    .transition(.asymmetric(insertion: .move(edge: .trailing), removal: .opacity))
            } else {
                OnboardingForm()
                    .transition(.asymmetric(insertion: .move(edge: .leading), removal: .opacity))
            }
        }
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: appState.onboardingCompleted)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: appState.requiresAuthenticationGate)
    }
}

private struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack {
                HomeView()
            }
            .tabItem {
                Label("Home", systemImage: "house.fill")
            }

            TodaysAgendaView()
                .tabItem {
                    Label("Agenda", systemImage: "calendar")
                }

            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
    }
}

#if DEBUG
private struct PreviewEncouragementAPI: EncouragementAPI {
    func fetchNext() async throws -> NextResponse {
        let verse = Verse.placeholder
        let payload = EncouragementPayload(
            id: verse.id,
            ref: verse.reference,
            text: verse.text,
            encouragement: verse.encouragement,
            translation: verse.translation.rawValue,
            expiresAt: nil
        )
        return NextResponse(shouldNotify: false, payload: payload, metadata: nil)
    }

    func triggerScanNow() async throws -> ScanNowResponse {
        ScanNowResponse(message: "Preview", encouragementId: Verse.placeholder.id, status: .success, log: nil)
    }

    func updateUserProfile(_ payload: RemoteUserProfileRequest) async throws {}

    func fetchCalendarAgenda() async throws -> CalendarAgendaResponse {
        CalendarAgendaResponse(fetchedAt: nil, items: [])
    }

    func fetchCalendarLinkStatus() async throws -> CalendarLinkStatus {
        CalendarLinkStatus(calendarUrl: nil, status: .pending, lastValidatedAt: nil, lastError: nil, updatedAt: nil, lastSyncedAt: nil, lastSyncStatus: nil, lastSyncError: nil)
    }

    func updateCalendarLink(_ payload: CalendarLinkUpdateRequest) async throws -> CalendarLinkStatus {
        CalendarLinkStatus(calendarUrl: payload.calendarUrl, status: .pending, lastValidatedAt: Date(), lastError: nil, updatedAt: Date(), lastSyncedAt: nil, lastSyncStatus: nil, lastSyncError: nil)
    }

    func deleteCalendarLink() async throws {}
}

#Preview {
    let defaults = UserDefaults(suiteName: "preview.walkworthy") ?? .standard
    defaults.removePersistentDomain(forName: "preview.walkworthy")

    return RootView()
        .environmentObject(AppState(
            config: Config.shared,
            apiClient: PreviewEncouragementAPI(),
            authSession: nil,
            defaults: defaults
        ))
}
#endif
