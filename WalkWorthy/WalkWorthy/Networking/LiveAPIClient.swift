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
        print("[LiveAPIClient] Submitting mood check-in: \(moodRequest.checkInType), \(moodRequest.primaryMood)")
        #endif

        let maxRetries = 2
        var lastError: Error?

        for attempt in 1...maxRetries {
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
                    if attempt < maxRetries {
                        #if DEBUG
                        print("[LiveAPIClient] Server error \(statusCode), retrying... (attempt \(attempt)/\(maxRetries))")
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

    func fetchMoodHistory(days: Int) async throws -> MoodHistoryResponse {
        let url = baseURL.appendingPathComponent("moodCheckIn")

        // Safely compose URL with query parameters
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw APIError.invalidResponse
        }
        components.queryItems = [URLQueryItem(name: "history", value: String(days))]

        guard let finalURL = components.url else {
            throw APIError.invalidResponse
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20

        do {
            let token = try await tokenProvider.validBearerToken()
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } catch {
            throw APIError.notAuthenticated
        }

        return try await send(request, decode: MoodHistoryResponse.self)
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
