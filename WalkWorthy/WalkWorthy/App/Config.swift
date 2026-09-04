//
//  Config.swift
//  WalkWorthy
//
//  Runtime configuration sourced from Info.plist and environment overrides.
//

import Foundation

struct Config {
    static let shared = Config()

    let notificationMode: String
    let apiBaseURL: URL?

    init(bundle: Bundle = .main) {
        var merged: [String: Any] = bundle.infoDictionary ?? [:]

        if let url = bundle.url(forResource: "Config", withExtension: "plist"),
           let data = try? Data(contentsOf: url),
           let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            merged.merge(plist) { _, new in new }
        }

        let env = ProcessInfo.processInfo.environment
        func override(_ key: String, using transform: (String) -> Any? = { $0 }) {
            guard let value = env[key], !value.isEmpty, let transformed = transform(value) else { return }
            merged[key] = transformed
        }

        override("API_BASE_URL")
        override("NOTIFICATION_MODE")

        notificationMode = (merged["NOTIFICATION_MODE"] as? String)?.lowercased() ?? "local"
        apiBaseURL = Self.secureBaseURL(from: merged["API_BASE_URL"], allowLocalhostHTTP: true)
    }

    // Enforces HTTPS for remote endpoints; optionally allows localhost HTTP for development.
    private static func secureBaseURL(from value: Any?, allowLocalhostHTTP: Bool = false) -> URL? {
        guard let raw = value as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let normalized = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: normalized) else { return nil }
        let scheme = url.scheme?.lowercased()

        if scheme == "https" {
            return url
        }

        if allowLocalhostHTTP,
           scheme == "http",
           let host = url.host?.lowercased(),
           host == "localhost" || host == "127.0.0.1" {
            return url
        }

        return nil
    }
}
