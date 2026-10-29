import Foundation

/// Snapshot of the alert-email preferences the Settings screen writes to
/// UserDefaults. Keys and defaults must match the `@AppStorage` declarations
/// in SettingsView.
struct EmailSettings {
    static let defaultSubject = "Alert! [your_name] is broadcasting"
    static let nameToken = "[your_name]"
    /// Subject used by early builds; treated as "not customised".
    static let legacySubject = "🚨 Emergency Recording Alert"
    static let defaultStorageFullNote = "Google Drive storage is full, so new clips cannot be uploaded right now. Recording is still in progress and the app will keep retrying — clips will upload automatically as soon as storage is freed."

    var alertsEnabled: Bool
    var recipients: [String]
    var subject: String
    var note: String
    var storageFullNote: String
    var includeTime: Bool
    var includeLocation: Bool

    static var current: EmailSettings {
        let defaults = UserDefaults.standard
        let rawSubject = defaults.string(forKey: "emailSubject")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let storageNote = defaults.string(forKey: "storageFullEmailNote")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return EmailSettings(
            alertsEnabled: (defaults.object(forKey: "emailAlertsEnabled") as? Bool) ?? true,
            recipients: parseRecipients(defaults.string(forKey: "emailRecipients") ?? ""),
            subject: (rawSubject.isEmpty || rawSubject == legacySubject) ? defaultSubject : rawSubject,
            note: defaults.string(forKey: "emailNote")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            storageFullNote: storageNote.isEmpty ? defaultStorageFullNote : storageNote,
            includeTime: (defaults.object(forKey: "includeTimeInEmail") as? Bool) ?? true,
            includeLocation: (defaults.object(forKey: "includeLocationInEmail") as? Bool) ?? true
        )
    }

    /// Whether an alert would actually go out with these settings.
    var canSend: Bool {
        alertsEnabled && !recipients.isEmpty
    }

    /// Splits the comma/semicolon/whitespace-separated recipients field.
    static func parseRecipients(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet(charactersIn: ",; \n\t"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func isValidEmail(_ address: String) -> Bool {
        address.wholeMatch(of: /[^@\s]+@[^@\s]+\.[^@\s]+/) != nil
    }

    /// Replaces the `[your_name]` placeholder so recipients see who is
    /// actually broadcasting instead of the literal token.
    static func personalize(_ text: String, name: String?, email: String?) -> String {
        let display = [name, email].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty } ?? "Someone"
        return text.replacingOccurrences(of: nameToken, with: display)
    }
}
