import Foundation

/// Snapshot of the alert-email preferences the Settings screen writes to
/// UserDefaults. Keys and defaults must match the `@AppStorage` declarations
/// in SettingsView.
struct EmailSettings {
    static let defaultSubject = "I have started a recording"
    static let nameToken = "[your_name]"
    /// Defaults from earlier builds. Settings saves the default into storage,
    /// so these are treated as "not customised" and replaced.
    static let legacySubjects: Set<String> = ["🚨 Emergency Recording Alert", "Alert! [your_name] is broadcasting", "[your_name] started recording"]

    static func isDefaultSubject(_ subject: String) -> Bool {
        subject.isEmpty || legacySubjects.contains(subject)
    }
    /// Subject for the low- and full-storage emails, naming whose Drive needs clearing.
    static func storageSubject(name: String?, email: String?) -> String {
        let owner = [name, email].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        let drive = owner.map { "\($0)'s Google Drive" } ?? "the Google Drive"
        return "Action Needed: Free up space on \(drive) for Just Capture"
    }
    /// Note for the second email, sent when Drive is close to full mid-recording.
    static let storageLowNote = "Google Drive storage is almost full. Recording is still in progress, but once storage runs out, new clips can't be uploaded until space is freed. Once it is, the clips will upload if Just Capture is still running on the device. You may not get another email from this account after that. If you have access to this Google account or manage its family plan, you can add storage at one.google.com."
    /// Used instead if Drive fills up before the low-storage email went out.
    static let storageFullNote = "Google Drive storage is full, so new clips can't be uploaded right now. Once space is freed, the clips will upload if Just Capture is still running on the device. If you have access to this Google account or manage its family plan, you can add storage at one.google.com."

    var alertsEnabled: Bool
    var recipients: [String]
    var subject: String
    var note: String
    var includeTime: Bool
    /// The app-wide location switch, not just an email option: when off, the
    /// app doesn't fetch location for recordings or emails. The storage key
    /// keeps its older email-specific name so existing choices carry over.
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

    /// The default subject no longer uses `[your_name]`, but a subject someone
    /// customised in an earlier build might. Fill it with their email address
    /// so recipients never see the literal token.
    static func personalize(_ text: String, email: String?) -> String {
        let trimmed = email?.trimmingCharacters(in: .whitespaces) ?? ""
        let display = trimmed.isEmpty ? "Someone" : trimmed
        return text.replacingOccurrences(of: nameToken, with: display)
    }
}
