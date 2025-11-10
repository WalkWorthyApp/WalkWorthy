//
//  AuthSession.swift
//  WalkWorthy
//
//  Manages Cognito tokens and exposes a lightweight async token provider.
//

import Foundation

actor AuthSession: BearerTokenProviding {
    enum AuthSessionError: LocalizedError, Sendable {
        case notConfigured
        case notAuthenticated
        case tokenExchangeFailed

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Cognito configuration is missing from the bundle."
            case .notAuthenticated:
                return "Sign-in required."
            case .tokenExchangeFailed:
                return "Failed to exchange credentials with Cognito."
            }
        }
    }

    struct TokenSet: Codable, Sendable {
        let accessToken: String
        let idToken: String
        let refreshToken: String?
        let expiresAt: Date
        let scope: String?

        var isExpired: Bool {
            expiresAt.timeIntervalSinceNow < 30
        }
    }

    private let domain: URL
    private let clientId: String
    private let redirectURI: URL
    private let scopes: [String]
    private let keychain: KeychainStorage
    private let tokensKey = "walkworthy.cognito.tokens"
    private var tokens: TokenSet?
    private let urlSession: URLSession

    init?(
        config: Config,
        keychain: KeychainStorage? = nil,
        urlSession: URLSession = .shared,
        scopes: [String] = ["openid", "profile", "email", "offline_access"]
    ) {
        let resolvedKeychain = keychain ?? KeychainStorage()

        guard let domain = config.cognitoDomain,
              let clientId = config.cognitoClientId,
              !clientId.isEmpty,
              let redirect = config.cognitoRedirectURI else {
            return nil
        }
        self.domain = domain
        self.clientId = clientId
        self.redirectURI = redirect
        self.scopes = scopes
        self.keychain = resolvedKeychain
        self.urlSession = urlSession

        if let data = try? resolvedKeychain.data(forKey: tokensKey) {
            let decoder = JSONDecoder()
            if let stored = try? decoder.decode(TokenSet.self, from: data) {
                self.tokens = stored
            }
        }
    }

    // MARK: - BearerTokenProviding

    func validBearerToken() async throws -> String {
        guard let existing = tokens else {
            throw AuthSessionError.notAuthenticated
        }

        if !existing.isExpired {
            return existing.idToken
        }

        guard let refresh = existing.refreshToken else {
            try await signOut()
            throw AuthSessionError.notAuthenticated
        }

        let refreshed = try await refreshTokens(using: refresh)
        tokens = refreshed
        return refreshed.idToken
    }

    // MARK: - Public helpers

    var redirectURL: URL {
        redirectURI
    }

    var authorizationScopes: [String] {
        scopes
    }

    func currentClientId() -> String {
        clientId
    }

    func currentScopes() -> [String] {
        scopes
    }

    func authorizationURL(state: String, additionalScopes: [String] = []) -> URL? {
        var mergedScopes = scopes
        mergedScopes.append(contentsOf: additionalScopes)

        var components = URLComponents(url: authorizeEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
            URLQueryItem(name: "scope", value: Array(Set(mergedScopes)).joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
        ]
        return components?.url
    }

    func currentUserSub() async throws -> String {
        _ = try await validBearerToken()
        guard let token = tokens?.idToken,
              let payload = decodeJWTPayload(token),
              let sub = payload["sub"] as? String else {
            throw AuthSessionError.notAuthenticated
        }
        return sub
    }

    func exchangeAuthorizationCode(_ code: String) async throws -> TokenSet {
        let body = formEncodedBody([
            "grant_type": "authorization_code",
            "client_id": clientId,
            "code": code,
            "redirect_uri": redirectURI.absoluteString,
        ])

        let response = try await sendTokenRequest(body: body)
        let tokenSet = try buildTokenSet(from: response, fallbackRefreshToken: response.refreshToken)
        tokens = tokenSet
        try await persist(tokenSet)
        return tokenSet
    }

    func signOut() async throws {
        tokens = nil
        let keychain = self.keychain
        let key = tokensKey
        try await MainActor.run {
            try keychain.remove(forKey: key)
        }
    }

    // MARK: - Internals

    private func refreshTokens(using refreshToken: String) async throws -> TokenSet {
        let body = formEncodedBody([
            "grant_type": "refresh_token",
            "client_id": clientId,
            "refresh_token": refreshToken,
        ])

        let response = try await sendTokenRequest(body: body)
        let tokenSet = try buildTokenSet(from: response, fallbackRefreshToken: refreshToken)
        tokens = tokenSet
        try await persist(tokenSet)
        return tokenSet
    }

    private func sendTokenRequest(body: Data) async throws -> CognitoTokenResponse {
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await urlSession.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw AuthSessionError.tokenExchangeFailed
        }

        if http.statusCode == 400 || http.statusCode == 401 {
            try? await signOut()
            throw AuthSessionError.notAuthenticated
        }

        guard (200...299).contains(http.statusCode) else {
            throw AuthSessionError.tokenExchangeFailed
        }

        return try decodeTokenResponse(from: data)
    }

    private func buildTokenSet(from response: CognitoTokenResponse, fallbackRefreshToken: String?) throws -> TokenSet {
        guard let accessToken = response.accessToken,
              let idToken = response.idToken else {
            throw AuthSessionError.tokenExchangeFailed
        }

        let refresh = response.refreshToken ?? fallbackRefreshToken

        guard let refresh else {
            throw AuthSessionError.tokenExchangeFailed
        }

        let expiresIn = response.expiresIn ?? 3600
        let expiry = Date().addingTimeInterval(TimeInterval(expiresIn))

        return TokenSet(
            accessToken: accessToken,
            idToken: idToken,
            refreshToken: refresh,
            expiresAt: expiry,
            scope: response.scope
        )
    }

    private func persist(_ tokenSet: TokenSet) async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(tokenSet)
        let keychain = self.keychain
        let key = tokensKey
        try await MainActor.run {
            try keychain.set(data, forKey: key)
        }
    }

    private func formEncodedBody(_ parameters: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = parameters.map { URLQueryItem(name: $0.key, value: $0.value) }
        return (components.percentEncodedQuery ?? "").data(using: .utf8) ?? Data()
    }

    private func decodeJWTPayload(_ token: String) -> [String: Any]? {
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        let payloadSegment = String(segments[1])
        guard let data = data(fromBase64URL: payloadSegment) else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func data(fromBase64URL string: String) -> Data? {
        var base64 = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = 4 - (base64.count % 4)
        if padding > 0 && padding < 4 {
            base64.append(String(repeating: "=", count: padding))
        }
        return Data(base64Encoded: base64)
    }

    private var authorizeEndpoint: URL {
        domain.appendingPathComponent("oauth2").appendingPathComponent("authorize")
    }

    private var tokenEndpoint: URL {
        domain.appendingPathComponent("oauth2").appendingPathComponent("token")
    }

    private func decodeTokenResponse(from data: Data) throws -> CognitoTokenResponse {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dictionary = object as? [String: Any] else {
            throw AuthSessionError.tokenExchangeFailed
        }

        func normalizedString(for key: String) -> String? {
            guard let value = dictionary[key] else { return nil }
            if let string = value as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            if let number = value as? NSNumber {
                return number.stringValue
            }
            return nil
        }

        func normalizedDouble(for key: String) -> Double? {
            guard let value = dictionary[key] else { return nil }
            if let double = value as? Double { return double }
            if let int = value as? Int { return Double(int) }
            if let string = value as? String { return Double(string) }
            return nil
        }

        return CognitoTokenResponse(
            accessToken: normalizedString(for: "access_token"),
            idToken: normalizedString(for: "id_token"),
            refreshToken: normalizedString(for: "refresh_token"),
            tokenType: normalizedString(for: "token_type"),
            expiresIn: normalizedDouble(for: "expires_in"),
            scope: normalizedString(for: "scope")
        )
    }
}

private struct CognitoTokenResponse: Sendable {
    let accessToken: String?
    let idToken: String?
    let refreshToken: String?
    let tokenType: String?
    let expiresIn: Double?
    let scope: String?
}
