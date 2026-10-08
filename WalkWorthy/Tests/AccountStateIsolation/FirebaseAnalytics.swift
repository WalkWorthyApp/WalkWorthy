// Test-only SDK stand-in: no Firebase initialization or analytics collection.
public let AnalyticsEventLogin = "login"
public let AnalyticsEventSignUp = "sign_up"
public let AnalyticsParameterMethod = "method"
public enum Analytics {
    public static func logEvent(_ name: String, parameters: [String: Any]?) {}
    public static func setAnalyticsCollectionEnabled(_ enabled: Bool) {}
}
