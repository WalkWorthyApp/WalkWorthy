//
//  BearerTokenProviding.swift
//  WalkWorthy
//
//  Abstraction used by networking layer to request Firebase ID tokens.
//

import Foundation

protocol BearerTokenProviding {
    /// Returns a valid bearer token, optionally forcing a refresh from the
    /// identity provider. Callers typically pass `false` and only retry with
    /// `true` after a 401 response in case the cached token expired mid-flight.
    func validBearerToken(forcingRefresh: Bool) async throws -> String
}

extension BearerTokenProviding {
    /// Convenience that fetches a token without forcing a refresh.
    func validBearerToken() async throws -> String {
        try await validBearerToken(forcingRefresh: false)
    }
}
