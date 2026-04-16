//
//  AppCheckTokenProviding.swift
//  WalkWorthy
//
//  Abstraction for fetching Firebase App Check tokens.
//

import Foundation

protocol AppCheckTokenProviding: Sendable {
    func validAppCheckToken() async throws -> String
}
