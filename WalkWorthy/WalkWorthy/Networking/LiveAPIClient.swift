//
//  LiveAPIClient.swift
//  WalkWorthy
//
//  Production API client backed by Firebase Cloud Functions.
//

import Foundation
import FirebaseCrashlytics

final class LiveAPIClient: EncouragementAPI {
    /// Characterizes the latency profile of an endpoint so we can pick an
    /// appropriate per-request timeout. AI endpoints talk to OpenAI through the
    /// backend and can legitimately take 10–20s; everything else should return
    /// in well under 5s.
    enum EndpointKind {
        case ai
        case nonAI

        var timeoutInterval: TimeInterval {
            switch self {
            case .ai: return 30
            case .nonAI: return 15
            }
        }
    }

    private let baseURL: URL
    private let tokenProvider: BearerTokenProviding
    private let appCheckProvider: AppCheckTokenProviding
    private let urlSession: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init?(config: Config, tokenProvider: BearerTokenProviding, appCheckProvider: AppCheckTokenProviding, urlSession: URLSession? = nil) {
        guard let baseURL = config.apiBaseURL else {
            return nil
        }
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.appCheckProvider = appCheckProvider
        self.urlSession = urlSession ?? LiveAPIClient.makeDefaultSession()
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = .sortedKeys
    }

    /// Degraded-mode initializer used when `Config.apiBaseURL` is missing/invalid.
    /// Points at an unreachable host (RFC 2606 reserved TLD `invalid` — DNS returns
    /// NXDOMAIN, so no request is ever issued — which also prevents an attacker on
    /// the local network from claiming a Bonjour name to intercept the
    /// `Authorization: Bearer <token>` header) so every request fails with
    /// `APIError.network` instead of crashing the app at `@main`. Callers should
    /// surface a configuration-error UI (see `AppState.configurationError`).
    init(baseURL: URL, tokenProvider: BearerTokenProviding, appCheckProvider: AppCheckTokenProviding, urlSession: URLSession? = nil) {
        self.baseURL = baseURL
        self.tokenProvider = tokenProvider
        self.appCheckProvider = appCheckProvider
        self.urlSession = urlSession ?? LiveAPIClient.makeDefaultSession()
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = .sortedKeys
    }

    /// Builds a `URLSession` with a bounded overall deadline so retries + per-call
    /// timeouts can't compound into a multi-minute stall. Per-request timeouts
    /// are still set via `URLRequest.timeoutInterval` on each call.
    static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        return URLSession(configuration: configuration)
    }

    // MARK: - EncouragementAPI

    @discardableResult
    func updateUserProfile(_ payload: RemoteUserProfileRequest) async throws -> RemoteUserProfileResponse? {
        // The backend PATCH merges the update server-side and returns the
        // fully merged document in the same `{ profile: {...} }` envelope as
        // GET. A decode failure is non-fatal — the PATCH already succeeded —
        // so return nil instead of throwing and let callers skip the snapshot.
        do {
            let envelope: UserProfileEnvelope = try await performRequest(
                path: "userProfile",
                method: "PATCH",
                body: payload,
                endpointKind: .nonAI,
                decode: UserProfileEnvelope.self
            )
            return envelope.profile
        } catch APIError.decodingFailed {
            #if DEBUG
            print("[LiveAPIClient] PATCH userProfile succeeded but response decode failed")
            #endif
            return nil
        }
    }

    func fetchUserProfile() async throws -> RemoteUserProfileResponse? {
        let envelope: UserProfileEnvelope = try await performRequest(
            path: "userProfile",
            method: "GET",
            endpointKind: .nonAI,
            decode: UserProfileEnvelope.self
        )
        return envelope.profile
    }

    /// Permanently delete the authenticated user's Firestore data and their
    /// Firebase Auth user. Required for App Store Guideline 5.1.1(v).
    ///
    /// Backend contract: `POST /deleteAccount` with an empty body. Response
    /// `200` returns `{ "deleted": true }`. Any other shape, a `deleted: false`
    /// payload, or a non-2xx status surfaces as an `APIError` so the caller
    /// can abort local cleanup.
    func deleteAccount() async throws {
        let response: DeleteAccountResponse = try await performRequest(
            path: "deleteAccount",
            method: "POST",
            endpointKind: .nonAI,
            decode: DeleteAccountResponse.self
        )
        guard response.deleted else {
            throw APIError.server(statusCode: 500, message: "Account deletion did not complete")
        }
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
                let response: MoodCheckInResponse = try await performRequest(
                    path: "moodCheckIn",
                    method: "POST",
                    body: moodRequest,
                    endpointKind: .ai,
                    decode: MoodCheckInResponse.self
                )
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
        try await performRequest(
            path: "moodCheckIn",
            method: "GET",
            endpointKind: .nonAI,
            decode: MoodStatusResponse.self
        )
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
        return try await performRequest(
            path: "moodCheckIn",
            method: "GET",
            queryItems: queryItems,
            endpointKind: .nonAI,
            decode: MoodHistoryResponse.self
        )
    }

    func fetchMoodLogFullHistory(days: Int, endDate: String?) async throws -> MoodLogResponse {
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "fullHistory", value: String(days))
        ]
        if let endDate {
            queryItems.append(URLQueryItem(name: "endDate", value: endDate))
        }
        return try await performRequest(
            path: "moodCheckIn",
            method: "GET",
            queryItems: queryItems,
            endpointKind: .nonAI,
            decode: MoodLogResponse.self
        )
    }

    private static func logicalDate() -> Date {
        let hour = Calendar.current.component(.hour, from: Date())
        guard hour < 3 else { return Date() }
        return Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
    }

    func fetchDailyReflection() async throws -> DailyReflection {
        let localDate = isoDateFormatter.string(from: Self.logicalDate())
        return try await performRequest(
            path: "dailyReflection",
            method: "GET",
            queryItems: [URLQueryItem(name: "date", value: localDate)],
            endpointKind: .ai,
            decode: DailyReflection.self
        )
    }

    private static let isoDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private var isoDateFormatter: DateFormatter { Self.isoDateFormatter }

    // MARK: - Internal helpers

    /// Build, send, and decode a JSON request in one call. Handles the 401
    /// forced-refresh retry transparently so individual endpoint methods don't
    /// need to duplicate the logic.
    ///
    /// Retry semantics: **Single retry only.** If the first request returns 401
    /// we force-refresh the bearer token and try once more. If the retry also
    /// returns 401, we propagate `.unauthorized` to the caller — further retries
    /// would tight-loop against an invalid session. Callers are responsible for
    /// handling persistent auth failure (typically by routing the user to sign
    /// in again). The retry path re-enters `makeRequest` which re-fetches the
    /// App Check token; if that fetch fails the request proceeds without the
    /// header (see App Check degrade-mode comment in `makeRequest`).
    private func performRequest<T: Decodable>(
        path: String,
        method: String,
        queryItems: [URLQueryItem]? = nil,
        endpointKind: EndpointKind,
        decode type: T.Type
    ) async throws -> T {
        let request = try await makeRequest(
            path: path,
            method: method,
            queryItems: queryItems,
            endpointKind: endpointKind,
            forcingTokenRefresh: false
        )

        do {
            return try await send(request, decode: type)
        } catch APIError.unauthorized {
            let retryRequest = try await makeRequest(
                path: path,
                method: method,
                queryItems: queryItems,
                endpointKind: endpointKind,
                forcingTokenRefresh: true
            )
            // If this second send throws .unauthorized, it propagates to the
            // caller unchanged — we do not retry a second time.
            return try await send(retryRequest, decode: type)
        }
    }

    /// Variant used for JSON-body requests — identical retry semantics.
    private func performRequest<Body: Encodable, T: Decodable>(
        path: String,
        method: String,
        body: Body,
        queryItems: [URLQueryItem]? = nil,
        endpointKind: EndpointKind,
        decode type: T.Type
    ) async throws -> T {
        let encodedBody = try encodeBody(body)

        let request = try await makeRequest(
            path: path,
            method: method,
            queryItems: queryItems,
            endpointKind: endpointKind,
            forcingTokenRefresh: false,
            body: encodedBody
        )

        do {
            return try await send(request, decode: type)
        } catch APIError.unauthorized {
            let retryRequest = try await makeRequest(
                path: path,
                method: method,
                queryItems: queryItems,
                endpointKind: endpointKind,
                forcingTokenRefresh: true,
                body: encodedBody
            )
            return try await send(retryRequest, decode: type)
        }
    }

    private func makeRequest(
        path: String,
        method: String,
        queryItems: [URLQueryItem]? = nil,
        endpointKind: EndpointKind,
        forcingTokenRefresh: Bool,
        body: Data? = nil
    ) async throws -> URLRequest {
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
        request.timeoutInterval = endpointKind.timeoutInterval

        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        do {
            let token = try await tokenProvider.validBearerToken(forcingRefresh: forcingTokenRefresh)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } catch {
            throw APIError.notAuthenticated
        }

        // App Check token fetch can fail for reasons that are not caller-recoverable:
        // simulators (App Attest only works on real devices), App Store reviewer
        // devices (known App Attest flakiness), and transient Firebase revalidation
        // windows. Hard-blocking these would brick the app in legitimate scenarios.
        //
        // Instead: degrade silently — log in DEBUG, proceed without the header. The
        // backend independently enforces App Check via `verifyAppCheck()` and returns
        // 403 if the header is missing/invalid. `handleResponse` maps 403 to
        // `APIError.unauthorized`, which is a recoverable path (sign in again).
        do {
            let appCheckToken = try await appCheckProvider.validAppCheckToken()
            request.setValue(appCheckToken, forHTTPHeaderField: "X-Firebase-AppCheck")
        } catch {
            #if DEBUG
            print("[LiveAPIClient] App Check token fetch failed; proceeding without header: \(error)")
            #else
            // Record as a non-fatal so we can see App Attest failure frequency in
            // production — helpful for diagnosing Apple reviewer device flakiness
            // or provisioning regressions.
            Crashlytics.crashlytics().record(error: error)
            #endif
            // Intentionally proceed. Backend enforces App Check independently via
            // verifyAppCheck(). A missing header returns 403, which `handleResponse`
            // maps to APIError.unauthorized — recoverable by the user.
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

/// Backend wraps the profile in `{ profile: {...} | null }`.
private struct UserProfileEnvelope: Decodable {
    let profile: RemoteUserProfileResponse?
}

/// Backend acknowledgement for `POST /deleteAccount`. A `true` value means
/// Firestore documents AND the Firebase Auth user were removed server-side;
/// the auth state listener will then flip the client to signed-out.
private struct DeleteAccountResponse: Decodable {
    let deleted: Bool
}
