//
//  LiveAPIClient.swift
//  WalkWorthy
//
//  Production API client backed by the deployed AWS stack.
//

import Foundation

final class LiveAPIClient: EncouragementAPI {
    private let baseURL: URL
    private let tokenProvider: BearerTokenProviding
    private let urlSession: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init?(config: Config, tokenProvider: BearerTokenProviding, urlSession: URLSession = .shared) {
        guard let baseURL = config.apiBaseURL else {
            return nil
        }
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.urlSession = urlSession
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = .sortedKeys
    }

    // MARK: - EncouragementAPI

    func fetchNext() async throws -> NextResponse {
        var request = try await makeRequest(path: "encouragement/next", method: "GET")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return try await send(request, decode: NextResponse.self)
    }

    func fetchTodayCanvas() async throws -> TodayCanvas {
        // Live API surfaces Canvas insights through encouragement metadata; return an empty summary here.
        TodayCanvas(assignmentsToday: [], examsToday: [])
    }

    func triggerScanNow() async throws -> ScanNowResponse {
        let request = try await makeRequest(path: "scan/now", method: "POST", body: EmptyPayload())
        return try await send(request, decode: ScanNowResponse.self)
    }

    func updateUserProfile(_ payload: RemoteUserProfileRequest) async throws {
        let request = try await makeRequest(path: "user/profile", method: "POST", body: payload)
        try await sendExpectingNoContent(request)
    }

    func fetchCalendarAgenda() async throws -> CalendarAgendaResponse {
        let request = try await makeRequest(path: "user/calendar-agenda", method: "GET")
        return try await send(request, decode: CalendarAgendaResponse.self)
    }

    func fetchCalendarLinkStatus() async throws -> CalendarLinkStatus {
        let request = try await makeRequest(path: "user/calendar-link", method: "GET")
        return try await send(request, decode: CalendarLinkStatus.self)
    }

    func updateCalendarLink(_ payload: CalendarLinkUpdateRequest) async throws -> CalendarLinkStatus {
        let request = try await makeRequest(path: "user/calendar-link", method: "PUT", body: payload)
        return try await send(request, decode: CalendarLinkStatus.self)
    }

    func deleteCalendarLink() async throws {
        let request = try await makeRequest(path: "user/calendar-link", method: "DELETE")
        try await sendExpectingNoContent(request)
    }

    // MARK: - Internal helpers

    private func makeRequest<T: Encodable>(path: String, method: String, body: T) async throws -> URLRequest {
        var request = try await makeRequest(path: path, method: method)
        request.httpBody = try encodeBody(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func makeRequest(path: String, method: String) async throws -> URLRequest {
        var url = baseURL
        if !path.isEmpty {
            let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            for component in trimmed.split(separator: "/") {
                url.appendPathComponent(String(component))
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        do {
            let token = try await tokenProvider.validBearerToken()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } catch {
            throw APIError.notAuthenticated
        }

        return request
    }

    private func send<T: Decodable>(_ request: URLRequest, decode type: T.Type) async throws -> T {
        do {
            let (data, response) = try await urlSession.data(for: request)
            return try handleResponse(data: data, response: response, decode: type)
        } catch let apiError as APIError {
            throw apiError
        } catch {
            throw APIError.network(error)
        }
    }

    private func sendExpectingNoContent(_ request: URLRequest) async throws {
        let _: EmptyPayload = try await send(request, decode: EmptyPayload.self)
    }

    private func handleResponse<T: Decodable>(data: Data, response: URLResponse, decode type: T.Type) throws -> T {
        guard let http = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }

        switch http.statusCode {
        case 200...299:
            if T.self == EmptyPayload.self {
                return EmptyPayload() as! T
            }
            guard !data.isEmpty else {
                throw APIError.invalidResponse
            }
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                throw APIError.decodingFailed(error)
            }
        case 401, 403:
            throw APIError.unauthorized
        case 409:
            throw APIError.conflict(message: parseErrorMessage(from: data))
        default:
            throw APIError.server(statusCode: http.statusCode, message: parseErrorMessage(from: data))
        }
    }

    private func encodeBody<T: Encodable>(_ value: T) throws -> Data {
        do {
            return try encoder.encode(value)
        } catch {
            throw APIError.encodingFailed(error)
        }
    }

    private func parseErrorMessage(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }

        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let message = object["message"] as? String {
            return message
        }

        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct EmptyPayload: Codable {
    init() {}
}
