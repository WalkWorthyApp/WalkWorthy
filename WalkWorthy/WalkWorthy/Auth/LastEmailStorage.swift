//
//  LastEmailStorage.swift
//  WalkWorthy
//
//  Manages persistence of the last entered email address for convenience (device-level storage).
//

import Foundation

enum LastEmailStorage {
    private static let key = "walkworthy.auth.lastEmail"

    /// Save the last entered email to UserDefaults
    static func saveEmail(_ email: String) {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            UserDefaults.standard.set(trimmed, forKey: key)
        }
    }

    /// Load the last saved email from UserDefaults
    static func loadEmail() -> String? {
        UserDefaults.standard.string(forKey: key)
    }
}
