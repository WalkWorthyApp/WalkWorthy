import Foundation

// Test-only SDK stand-in: never sends error reports.
public final class Crashlytics {
    public static func crashlytics() -> Crashlytics { Crashlytics() }
    public func record(error: Error) {}
}
