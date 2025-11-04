//
//  MockAPIClient.swift
//  WalkWorthy
//
//  Loads mock JSON responses from the bundle.
//

import Foundation

struct MockAPIClient: EncouragementAPI {
    private let decoder: JSONDecoder
    private let bundle: Bundle
    private let calendarLinkKey = "walkworthy.mock.calendar.link"

    init(bundle: Bundle = .main) {
        self.bundle = bundle
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func fetchNext() async throws -> NextResponse {
        try await load(named: "encouragement_next", type: NextResponse.self)
    }

    func fetchTodayCanvas() async throws -> TodayCanvas {
        try await load(named: "today_canvas", type: TodayCanvas.self)
    }

    func triggerScanNow() async throws -> ScanNowResponse {
        try await load(named: "scan_now", type: ScanNowResponse.self)
    }

    func updateUserProfile(_ payload: RemoteUserProfileRequest) async throws {
        let defaults = UserDefaults.standard
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        if let data = try? encoder.encode(payload) {
            defaults.set(data, forKey: "walkworthy.mock.profile.remote")
        }
    }

    func fetchCalendarAgenda() async throws -> CalendarAgendaResponse {
        let now = Date()
        let items: [CalendarAgendaItem] = [
            CalendarAgendaItem(
                id: UUID().uuidString,
                title: "Math homework 5",
                kind: .assignment,
                startAt: now.addingTimeInterval(3600),
                endAt: now.addingTimeInterval(7200),
                dueAt: now.addingTimeInterval(7200),
                course: "Calculus",
                location: nil,
                url: URL(string: "https://example.com/math"),
                timeZoneId: TimeZone.current.identifier
            ),
            CalendarAgendaItem(
                id: UUID().uuidString,
                title: "Physics midterm",
                kind: .exam,
                startAt: now.addingTimeInterval(10800),
                endAt: now.addingTimeInterval(14400),
                dueAt: now.addingTimeInterval(14400),
                course: "Physics",
                location: "Hall A",
                url: nil,
                timeZoneId: TimeZone.current.identifier
            ),
        ]
        return CalendarAgendaResponse(fetchedAt: now, items: items)
    }

    func fetchCalendarLinkStatus() async throws -> CalendarLinkStatus {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: calendarLinkKey) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let status = try? decoder.decode(CalendarLinkStatus.self, from: data) {
                return status
            }
        }

        return CalendarLinkStatus(
            calendarUrl: nil,
            status: .pending,
            lastValidatedAt: nil,
            lastError: nil,
            updatedAt: nil
        )
    }

    func updateCalendarLink(_ payload: CalendarLinkUpdateRequest) async throws -> CalendarLinkStatus {
        let status = CalendarLinkStatus(
            calendarUrl: payload.calendarUrl.trimmingCharacters(in: .whitespacesAndNewlines),
            status: .active,
            lastValidatedAt: Date(),
            lastError: nil,
            updatedAt: Date()
        )
        let defaults = UserDefaults.standard
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(status) {
            defaults.set(data, forKey: calendarLinkKey)
        }
        return status
    }

    func deleteCalendarLink() async throws {
        UserDefaults.standard.removeObject(forKey: calendarLinkKey)
    }

    private func load<T: Decodable>(named name: String, type: T.Type) async throws -> T {
        try await Task.sleep(nanoseconds: 150_000_000) // Simulate network latency
        guard let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Mock") else {
            throw MockAPIError.missingResource(name)
        }
        let data = try Data(contentsOf: url)
        return try decoder.decode(T.self, from: data)
    }

    enum MockAPIError: LocalizedError {
        case missingResource(String)

        var errorDescription: String? {
            switch self {
            case .missingResource(let name):
                return "Mock resource \(name) was not found in the bundle."
            }
        }
    }
}
