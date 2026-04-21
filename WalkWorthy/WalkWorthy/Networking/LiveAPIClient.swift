//
//  LiveAPIClient.swift
//  WalkWorthy
//
//  Production API client backed by Firebase Cloud Functions.
//

import Foundation

final class LiveAPIClient: EncouragementAPI {
    private let baseURL: URL
    private let tokenProvider: BearerTokenProviding
    private let appCheckProvider: AppCheckTokenProviding
    private let urlSession: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init?(config: Config, tokenProvider: BearerTokenProviding, appCheckProvider: AppCheckTokenProviding, urlSession: URLSession = .shared) {
        guard let baseURL = config.apiBaseURL else {
            return nil
        }
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.appCheckProvider = appCheckProvider
        self.urlSession = urlSession
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = .sortedKeys
    }

    // MARK: - EncouragementAPI

    func updateUserProfile(_ payload: RemoteUserProfileRequest) async throws {
        let request = try await makeRequest(path: "userProfile", method: "PATCH", body: payload)
        try await sendExpectingNoContent(request)
    }

    // MARK: - Mood API

    /// Submit a mood check-in with automatic retry for cold start errors.
    ///
    /// Firebase Cloud Functions can experience cold start delays on the first request,
    /// which may result in a 500 error. This method automatically retries once on
    /// server errors (500) to handle this transient condition.
    func submitMoodCheckIn(_ moodRequest: MoodCheckInRequest) async throws -> MoodCheckInResponse {
        #if DEBUG
        print("[LiveAPIClient] Submitting mood check-in: \(moodRequest.checkInType), score=\(moodRequest.moodSpectrumData.moodScore)")
        #endif

        let maxAttempts = 2
        var lastError: Error?

        for attempt in 1...maxAttempts {
            do {
                let request = try await makeRequest(path: "moodCheckIn", method: "POST", body: moodRequest)
                #if DEBUG
                if attempt == 1 {
                    print("[LiveAPIClient] Full Request URL: \(request.url?.absoluteString ?? "nil")")
                }
                #endif
                let response = try await send(request, decode: MoodCheckInResponse.self)
                #if DEBUG
                print("[LiveAPIClient] Mood check-in success (attempt \(attempt))")
                #endif
                return response
            } catch let error as APIError {
                lastError = error

                // Only retry on server errors (500s) which are likely cold start issues
                if case .server(let statusCode, _) = error, statusCode >= 500 && statusCode < 600 {
                    if attempt < maxAttempts {
                        #if DEBUG
                        print("[LiveAPIClient] Server error \(statusCode), retrying... (attempt \(attempt)/\(maxAttempts))")
                        #endif
                        // Brief delay before retry to allow function to warm up
                        try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                        continue
                    }
                }
                #if DEBUG
                print("[LiveAPIClient] Mood check-in failed: \(error)")
                #endif
                throw error
            } catch {
                lastError = error
                #if DEBUG
                print("[LiveAPIClient] Mood check-in failed: \(error)")
                #endif
                throw error
            }
        }

        // Should not reach here, but throw last error if we do
        throw lastError ?? APIError.invalidResponse
    }

    func fetchMoodStatus() async throws -> MoodStatusResponse {
        let request = try await makeRequest(path: "moodCheckIn", method: "GET")
        return try await send(request, decode: MoodStatusResponse.self)
    }

    func fetchMoodHistory(days: Int, startDate: String?, endDate: String?) async throws -> MoodHistoryResponse {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "history", value: String(days))
        ]
        if let startDate {
            queryItems.append(URLQueryItem(name: "startDate", value: startDate))
        }
        if let endDate {
            queryItems.append(URLQueryItem(name: "endDate", value: endDate))
        }
        let request = try await makeRequest(
            path: "moodCheckIn",
            method: "GET",
            queryItems: queryItems
        )
        return try await send(request, decode: MoodHistoryResponse.self)
    }

    func fetchMoodLogFullHistory(days: Int, endDate: String?) async throws -> MoodLogResponse {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "fullHistory", value: String(days))
        ]
        if let endDate {
            queryItems.append(URLQueryItem(name: "endDate", value: endDate))
        }
        let request = try await makeRequest(
            path: "moodCheckIn",
            method: "GET",
            queryItems: queryItems
        )
        return try await send(request, decode: MoodLogResponse.self)
    }

    private static func logicalDate() -> Date {
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour < 3 else { return Date() }
        return Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    }

    func fetchDailyReflection() async throws -> DailyReflection {
        let localDate = isoDateFormatter.string(from: Self.logicalDate())
        let request = try await makeRequest(
            path: "dailyReflection",
            method: "GET",
            queryItems: [URLQueryItem(name: "date", value: localDate)]
        )
        return try await send(request, decode: DailyReflection.self)
    }

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private var isoDateFormatter: DateFormatter { Self.isoDateFormatter }

    // MARK: - Internal helpers

    private func makeRequest<T: Encodable>(path: String, method: String, body: T) async throws -> URLRequest {
        var request = try await makeRequest(path: path, method: method)
        request.httpBody = try encodeBody(body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func makeRequest(path: String, method: String, queryItems: [URLQueryItem]? = nil) async throws -> URLRequest {
        var url = baseURL
        if !path.isEmpty {
            let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            for component in trimmed.split(separator: "/") {
                url.appendPathComponent(String(component))
            }
        }

        if let queryItems {
            guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                throw APIError.invalidResponse
            }
            components.queryItems = queryItems
            guard let finalURL = components.url else {
                throw APIError.invalidResponse
            }
            url = finalURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 60

        do {
            let token = try await tokenProvider.validBearerToken()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } catch {
            throw APIError.notAuthenticated
        }

        do {
            let appCheckToken = try await appCheckProvider.validAppCheckToken()
            request.setValue(appCheckToken, forHTTPHeaderField: "X-Firebase-AppCheck")
        } catch {
            #if DEBUG
            print("[LiveAPIClient] App Check token fetch failed: \(error)")
            #endif
        }

        return request
    }

    private func send<T: Decodable>(_ request: URLRequest, decode type: T.Type) async throws -> T {
        do {
            let (data, response) = try await urlSession.data(for: request)
            #if DEBUG
            if let httpResponse = response as? HTTPURLResponse {
                print("[LiveAPIClient] HTTP Status: \(httpResponse.statusCode), body: \(data.count) bytes")
            }
            #endif
            return try handleResponse(data: data, response: response, decode: type)
        } catch let apiError as APIError {
            throw apiError
        } catch {
            #if DEBUG
            print("[LiveAPIClient] Network error: \(error)")
            #endif
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
            if T.self == EmptyPayload.self, let empty = EmptyPayload() as? T {
                return empty
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
        case 429:
            throw parseRateLimitError(data: data, response: http)
        default:
            throw APIError.server(statusCode: http.statusCode, message: parseErrorMessage(from: data))
        }
    }

    private func parseRateLimitError(data: Data, response: HTTPURLResponse) -> APIError {
        let body = try? JSONDecoder().decode(RateLimitErrorBody.self, from: data)

        let scope: RateLimitScope
        if let rawScope = body?.scope {
            scope = RateLimitScope(rawValue: rawScope) ?? .unknown
        } else {
            scope = .unknown
        }

        let retryAfterSeconds: Int? = body?.retryAfterSeconds ?? parseRetryAfterHeader(response.value(forHTTPHeaderField: "Retry-After"))

        #if DEBUG
        print("[LiveAPIClient] Rate limited — scope: \(scope.rawValue), retryAfterSeconds: \(retryAfterSeconds.map(String.init) ?? "nil")")
        #endif

        return .rateLimited(retryAfterSeconds: retryAfterSeconds, scope: scope)
    }

    private func parseRetryAfterHeader(_ value: String?) -> Int? {
        guard let value else { return nil }
        if let seconds = Int(value) {
            return seconds
        }
        // HTTP-date fallback
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: value) {
            let diff = Int(date.timeIntervalSinceNow)
            return diff > 0 ? diff : nil
        }
        return nil
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

private struct RateLimitErrorBody: Decodable {
    let code: String?
    let scope: String?
    let retryAfterSeconds: Int?
}
