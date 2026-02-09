//
//  BearerTokenProviding.swift
//  WalkWorthy
//
//  Abstraction used by networking layer to request Firebase ID tokens.
//

import Foundation

protocol BearerTokenProviding {
    func validBearerToken() async throws -> String
}
