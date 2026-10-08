import Foundation
import Testing
@testable import ReminderBoundary

// Each test owns a unique suite; none reads or modifies the app's defaults.
@MainActor
private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
    let suite = "walkworthy.reminder-tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    try body(defaults)
}

private let legacyValues: [String: Int] = [
    "morningEnabled": 0, "middayEnabled": 0, "eveningEnabled": 0,
    "morningHour": 5, "morningMinute": 17,
    "middayHour": 11, "middayMinute": 23,
    "eveningHour": 22, "eveningMinute": 41,
]

@MainActor
private func seedLegacy(_ defaults: UserDefaults) {
    for (suffix, value) in legacyValues {
        defaults.set(value, forKey: "walkworthy.reminders.\(suffix)")
    }
}

@MainActor
private func expectNoLegacyOrInheritedValues(_ defaults: UserDefaults, userSub: String) {
    for suffix in legacyValues.keys {
        #expect(defaults.object(forKey: "walkworthy.reminders.\(suffix)") == nil)
        #expect(defaults.object(forKey: "walkworthy.reminders.\(suffix)::\(userSub)") == nil)
    }
}

@Test @MainActor
func upgradedAccountSignsOutBeforeAnotherAccountOpensSettings() throws {
    try withDefaults { defaults in
        seedLegacy(defaults)
        defaults.set("A", forKey: "walkworthy.auth.lastUser")
        // A has never visited reminder settings since upgrading.
        let app = AppStateBoundary(defaults: defaults, userSub: "A")
        app.signOut()
        // Cleanup must finish synchronously, before Firebase's callback.
        expectNoLegacyOrInheritedValues(defaults, userSub: "B")
        app.setAuthenticatedUserSub(nil)
        app.setAuthenticatedUserSub("B")
        let settings = NotificationSettingsBoundary(defaults: defaults, userSub: "B")
        settings.loadSavedSettings()
        expectNoLegacyOrInheritedValues(defaults, userSub: "B")
        #expect(settings.morningEnabled)
        #expect(settings.middayEnabled)
        #expect(settings.eveningEnabled)
        #expect(Calendar.current.component(.hour, from: settings.morningTime) == 7)
        #expect(Calendar.current.component(.hour, from: settings.middayTime) == 12)
        #expect(Calendar.current.component(.hour, from: settings.eveningTime) == 19)
    }
}

@Test(arguments: ["listener-signout", "direct-switch", "signed-out-launch", "repeat-account"])
@MainActor
func everyAuthBoundaryRetiresOwnerlessValues(path: String) throws {
    try withDefaults { defaults in
        seedLegacy(defaults)
        let app = AppStateBoundary(defaults: defaults, userSub: path == "signed-out-launch" ? nil : "A")
        switch path {
        case "listener-signout", "signed-out-launch": app.setAuthenticatedUserSub(nil)
        case "direct-switch": app.setAuthenticatedUserSub("B")
        default: app.setAuthenticatedUserSub("A")
        }
        expectNoLegacyOrInheritedValues(defaults, userSub: "B")
    }
}

@Test @MainActor
func scopedAndUnrelatedPreferencesSurviveRepeatedCleanup() throws {
    try withDefaults { defaults in
        let preserved: [String: Int] = [
            "walkworthy.reminders.morningEnabled::A": 0,
            "walkworthy.reminders.morningHour::A": 0,
            "walkworthy.reminders.morningMinute::A": 0,
            "walkworthy.reminders.morningEnabled::B": 0,
            "walkworthy.reminders.morningHour::B": 9,
            "walkworthy.reminders.morningMinute::B": 32,
            "walkworthy.reminders.futureSetting::C": 7,
            "walkworthy.remindersExtra": 8,
            "unrelated.preference": 42,
        ]
        for (key, value) in preserved { defaults.set(value, forKey: key) }
        seedLegacy(defaults)
        defaults.set(1, forKey: "walkworthy.reminders.unknownLegacySetting")
        let app = AppStateBoundary(defaults: defaults, userSub: "A")
        app.signOut()
        app.setAuthenticatedUserSub(nil)
        app.setAuthenticatedUserSub("B")
        let settings = NotificationSettingsBoundary(defaults: defaults, userSub: "B")
        settings.loadSavedSettings()
        for (key, value) in preserved {
            #expect(defaults.object(forKey: key) as? Int == value)
        }
        #expect(defaults.object(forKey: "walkworthy.reminders.unknownLegacySetting") == nil)
        #expect(!settings.morningEnabled)
        #expect(Calendar.current.component(.hour, from: settings.morningTime) == 9)
        #expect(Calendar.current.component(.minute, from: settings.morningTime) == 32)
        app.setAuthenticatedUserSub("C")
        NotificationSettingsBoundary(defaults: defaults, userSub: "C").loadSavedSettings()
        expectNoLegacyOrInheritedValues(defaults, userSub: "C")
    }
}

@Test(arguments: [nil, "A", "B"] as [String?])
@MainActor
func settingsNeverTreatsLastLoginAsReminderOwnership(lastUser: String?) throws {
    try withDefaults { defaults in
        seedLegacy(defaults)
        defaults.set(lastUser, forKey: "walkworthy.auth.lastUser")
        // Challenge the read boundary even if cleanup hasn't happened yet.
        let settings = NotificationSettingsBoundary(defaults: defaults, userSub: "B")
        settings.loadSavedSettings()
        for suffix in legacyValues.keys {
            #expect(defaults.object(forKey: "walkworthy.reminders.\(suffix)::B") == nil)
        }
        #expect(settings.morningEnabled)
        #expect(Calendar.current.component(.hour, from: settings.morningTime) == 7)
    }
}

@Test @MainActor
func returningAccountKeepsScopedDisabledReminderAndMidnightTime() throws {
    try withDefaults { defaults in
        defaults.set(false, forKey: "walkworthy.reminders.morningEnabled::A")
        defaults.set(0, forKey: "walkworthy.reminders.morningHour::A")
        defaults.set(0, forKey: "walkworthy.reminders.morningMinute::A")
        let app = AppStateBoundary(defaults: defaults, userSub: "A")
        app.signOut()
        app.setAuthenticatedUserSub(nil)
        app.setAuthenticatedUserSub("A")
        let settings = NotificationSettingsBoundary(defaults: defaults, userSub: "A")
        settings.loadSavedSettings()
        #expect(!settings.morningEnabled)
        #expect(Calendar.current.component(.hour, from: settings.morningTime) == 0)
        #expect(Calendar.current.component(.minute, from: settings.morningTime) == 0)
        #expect(settings.middayEnabled)
        #expect(defaults.object(forKey: "walkworthy.reminders.morningEnabled::A") as? Bool == false)
    }
}
