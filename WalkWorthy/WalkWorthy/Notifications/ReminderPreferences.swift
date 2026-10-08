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
}
