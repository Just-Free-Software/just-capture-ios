import Foundation

/// Snapshot of the alert-email preferences the Settings screen writes to
/// UserDefaults. Keys and defaults must match the `@AppStorage` declarations
/// in SettingsView.
struct EmailSettings {
    static let defaultSubject = "[your_name] started recording"
    static let nameToken = "[your_name]"
    /// Defaults from earlier builds. Settings used to save the default into
    /// storage, so these are treated as "not customised" and replaced.
    static let legacySubjects: Set<String> = ["🚨 Emergency Recording Alert", "Alert! [your_name] is broadcasting"]

    static func isDefaultSubject(_ subject: String) -> Bool {
        subject.isEmpty || legacySubjects.contains(subject)
    }
    /// Note for the second email, sent if Drive fills up mid-recording.
    static let storageFullNote = "Google Drive storage is full, so new clips cannot be uploaded right now. Recording is still in progress and the app will keep retrying — it will try to upload the remaining clips once storage is freed."

    var alertsEnabled: Bool
    var recipients: [String]
    var subject: String
    var note: String
    var includeTime: Bool
    var includeLocation: Bool

    static var current: EmailSettings {
        let defaults = UserDefaults.standard
        let rawSubject = defaults.string(forKey: "emailSubject")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return EmailSettings(
            alertsEnabled: (defaults.object(forKey: "emailAlertsEnabled") as? Bool) ?? true,
            recipients: parseRecipients(defaults.string(forKey: "emailRecipients") ?? ""),
            subject: isDefaultSubject(rawSubject) ? defaultSubject : rawSubject,
            note: defaults.string(forKey: "emailNote")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
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
