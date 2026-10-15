import Foundation

@MainActor
enum ReminderPreferences {
    /// Pre-scoping releases did not record an owner for these values. Neither
    /// the current UID nor the last login proves whose reminders they were.
    /// Retire them without changing any account's scoped preferences.
    static func discardOwnerlessValues(in defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix("walkworthy.reminders.") && !key.contains("::") {
            defaults.removeObject(forKey: key)
        }
    }

    /// Scoped to the account like the check-in reminder keys, so account
    /// deletion's `::<uid>` sweep removes it.
    private static func birthdayEnabledKey(for userSub: String) -> String {
        "walkworthy.reminders.birthdayEnabled::\(userSub)"
    }

    /// Whether this account turned on the birthday notification. Opt-in: it
    /// shows the user's name and Scripture on the lock screen.
    static func birthdayEnabled(for userSub: String, in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: birthdayEnabledKey(for: userSub))
    }

    static func setBirthdayEnabled(_ enabled: Bool, for userSub: String, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: birthdayEnabledKey(for: userSub))
    }
}
