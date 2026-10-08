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

    /// Fetch only the initiating sign-in's token; never substitute another
    /// account or a later sign-in as the same account.
    func validBearerToken(for context: AuthenticatedRequestContext, forcingRefresh: Bool) async throws -> String

    /// Synchronous dispatch gate: checks both the shared generation and actual
    /// credential owner without an actor hop between validation and enqueue.
    @MainActor func validateSession(for context: AuthenticatedRequestContext) throws
}

extension BearerTokenProviding {
    /// Convenience that fetches a token without forcing a refresh.
    func validBearerToken() async throws -> String {
        try await validBearerToken(forcingRefresh: false)
    }
}
