//
//  APIError.swift
//  WalkWorthy
//
//  Thin error wrapper for HTTP calls against the backend.
//

import Foundation

enum RateLimitScope: String {
    case user
    case ip
    case dailyBudget
    case unknown
}

enum APIError: LocalizedError {
    case missingConfiguration(String)
    case unauthorized
    case notAuthenticated
    case conflict(message: String?)
    case rateLimited(retryAfterSeconds: Int?, scope: RateLimitScope)
    case server(statusCode: Int, message: String?)
    case decodingFailed(Error)
    case encodingFailed(Error)
    case network(Error)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingConfiguration(let key):
            return "Missing configuration value for \(key)."
        case .unauthorized, .notAuthenticated:
            return "Please sign in to continue."
        case .conflict(let message):
            return message ?? "Request could not be completed."
        case .rateLimited(let retryAfterSeconds, let scope):
            return rateLimitedDescription(retryAfterSeconds: retryAfterSeconds, scope: scope)
        case .server(_, let message):
            return message ?? "The server returned an unexpected error."
        case .decodingFailed:
            return "Failed to decode the server response."
        case .encodingFailed:
            return "Failed to encode the request payload."
        case .network(let error):
            return error.localizedDescription
        case .invalidResponse:
            return "Received an invalid response from the server."
        }
    }

    var errorTitle: String? {
        switch self {
        case .rateLimited:
            return "Usage limit reached"
        default:
            return nil
        }
    }

    private func rateLimitedDescription(retryAfterSeconds: Int?, scope: RateLimitScope) -> String {
        let minutesText: String? = retryAfterSeconds.map { seconds in
            let minutes = Int(ceil(Double(seconds) / 60.0))
            return "~\(minutes) minute\(minutes == 1 ? "" : "s")"
        }

        switch scope {
        case .user:
            if let minutes = minutesText {
                return "You've reached the usage limit for this feature. Try again in \(minutes)."
            }
            return "You've reached the usage limit. Please try again in a little while."
        case .ip:
            if let minutes = minutesText {
                return "Too many requests from this network. Please try again in \(minutes)."
            }
            return "Too many requests from this network. Please try again in a little while."
        case .dailyBudget:
            return "You've used today's limit for this feature. It'll reset tomorrow."
        case .unknown:
            return "You're making requests too quickly. Please wait a moment and try again."
        }
    }
}
