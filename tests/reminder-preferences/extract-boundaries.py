"""Compile actual auth-boundary and settings methods without Firebase or SwiftUI.

Only access modifiers change. External notification/auth/cache collaborators are
inert: tests exercise preference ownership, not those collaborators. An app build
separately checks these methods in their real types and platform context.
"""

from pathlib import Path
import shutil
import sys

source = Path(sys.argv[1]) / "WalkWorthy/WalkWorthy"
output = Path(sys.argv[2])
app = (source / "App/AppState.swift").read_text()
settings = (source / "UI/Settings/SettingsView.swift").read_text()


def declaration(text, signature):
    start = text.index(signature)
    opening = text.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end].replace("private ", "", 1)


app_methods = "\n".join(declaration(app, signature) for signature in [
    "func signOut()",
    "private func setAuthenticatedUserSub(_ sub: String?)",
])
settings_signatures = [
    "private func scopedKey(_ baseKey: String)",
    "private func loadSavedSettings()",
    "private static func defaultTime(hour: Int, minute: Int)",
    "private enum StorageKeys",
]
# Including the old migration when present lets the same tests demonstrate the
# original cross-account adoption against an unchanged baseline checkout.
if "private func migrateReminderKeyIfNeeded(bare: String)" in settings:
    settings_signatures.append("private func migrateReminderKeyIfNeeded(bare: String)")
settings_methods = "\n".join(declaration(settings, signature) for signature in settings_signatures)

harness = """
import Foundation

@MainActor
final class NotificationScheduler {
    static let shared = NotificationScheduler()
    struct Session { let userSub: String }
    func beginSession(for userSub: String) {}
    func invalidateSession(for userSub: String) {}
    func removeReminders(for userSub: String, includingLegacy: Bool) async {}
    func isCurrent(_ session: Session) -> Bool { true }
}

actor AuthSessionStub { func signOut() throws {} }

@MainActor
public final class AppStateBoundary {
    let defaults: UserDefaults
    var authenticatedUserSub: String?
    var authenticationNotice: String?
    var reflectionFetchTask, profileRefreshTask, profileSyncTask: Task<Void, Never>?
    var signOutTask, consentOperation, moodSubmissionTask: Task<Void, Never>?
    var dailyReflection, latestMoodResponse, currentMoodStatus, lastMoodStatusFetch: Int?
    var weekSummary: [Int] = []
    var moodLogFirstPage: [Int] = []
    var consentEpoch = UUID()
    var consentTicket = 0
    var aiConsentBusy = false
    var aiConsentError: String?
    var consentAgeGroup = "unknown"
    var consentRevision = 0
    var accountDeletionPending = false
    var pendingAccountDeletionUsers: Set<String> = []
    let authSession = AuthSessionStub()
    enum StorageKey { static let lastAuthenticatedUser = "walkworthy.auth.lastUser" }
    init(defaults: UserDefaults, userSub: String?) {
        self.defaults = defaults
        self.authenticatedUserSub = userSub
    }
    func removeMoodDrafts(for userSub: String) {}
    func clearOnDiskUserCaches(for userSub: String) {}
    func reloadUserScopedPreferences() {}
    APP_METHODS
}

@MainActor
public final class NotificationSettingsBoundary {
    let defaults: UserDefaults
    let reminderSession: NotificationScheduler.Session?
    var morningTime = NotificationSettingsBoundary.defaultTime(hour: 7, minute: 0)
    var middayTime = NotificationSettingsBoundary.defaultTime(hour: 12, minute: 0)
    var eveningTime = NotificationSettingsBoundary.defaultTime(hour: 19, minute: 0)
    var morningEnabled = true
    var middayEnabled = true
    var eveningEnabled = true
    init(defaults: UserDefaults, userSub: String) {
        self.defaults = defaults
        self.reminderSession = NotificationScheduler.Session(userSub: userSub)
    }
    SETTINGS_METHODS
}
"""
(output / "Boundary.swift").write_text(
    harness.replace("APP_METHODS", app_methods).replace("SETTINGS_METHODS", settings_methods)
)
helper = source / "Notifications/ReminderPreferences.swift"
if helper.exists():
    shutil.copy2(helper, output / helper.name)
