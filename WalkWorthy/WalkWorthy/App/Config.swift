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
    let defaultTranslation: Translation
    let apiBaseURL: URL?
    let cognitoDomain: URL?
    let cognitoClientId: String?
    let cognitoRedirectURI: URL?
    let canvasRedirectURI: URL?
    let canvasBaseURL: URL?
    let canvasClientId: String?

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
        override("COGNITO_DOMAIN")
        override("COGNITO_CLIENT_ID")
        override("COGNITO_REDIRECT_URI")
        override("CANVAS_BASE_URL")
        override("CANVAS_CLIENT_ID")
        override("CANVAS_REDIRECT_URI")
        override("DEFAULT_TRANSLATION") { $0.uppercased() }
        override("NOTIFICATION_MODE")

        notificationMode = (merged["NOTIFICATION_MODE"] as? String)?.lowercased() ?? "local"
        let translationKey = (merged["DEFAULT_TRANSLATION"] as? String)?.uppercased() ?? Translation.esv.rawValue
        defaultTranslation = Translation(rawValue: translationKey) ?? .esv
        apiBaseURL = (merged["API_BASE_URL"] as? String)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap(URL.init(string:))
        cognitoDomain = (merged["COGNITO_DOMAIN"] as? String)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { raw -> URL? in
                if raw.isEmpty { return nil }
                if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
                    return URL(string: raw)
                }
                return URL(string: "https://\(raw)")
            }
        cognitoClientId = (merged["COGNITO_CLIENT_ID"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        cognitoRedirectURI = (merged["COGNITO_REDIRECT_URI"] as? String)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap(URL.init(string:))
        canvasRedirectURI = (merged["CANVAS_REDIRECT_URI"] as? String)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap(URL.init(string:))
        canvasBaseURL = (merged["CANVAS_BASE_URL"] as? String)
            .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { raw -> URL? in
                if raw.isEmpty { return nil }
                if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
                    return URL(string: raw)
                }
                return URL(string: "https://\(raw)")
            }
        canvasClientId = (merged["CANVAS_CLIENT_ID"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
