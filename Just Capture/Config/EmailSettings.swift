import Foundation

/// Snapshot of the alert-email preferences the Settings screen writes to
/// UserDefaults. Keys and defaults must match the `@AppStorage` declarations
/// in SettingsView.
struct EmailSettings {
    static let defaultSubject = "I have started a recording"

    /// Subject for the low- and full-storage emails, naming whose Drive needs clearing.
    static func storageSubject(name: String?, email: String?) -> String {
        let owner = [name, email].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty }
        let drive = owner.map { "\($0)'s Google Drive" } ?? "the Google Drive"
        return "Action Needed: Free up space on \(drive) for Just Capture"
    }
    /// Note for the second email, sent when Drive is close to full mid-recording.
    static let storageLowNote = "Google Drive storage is almost full. Recording is still in progress, but once storage runs out, new clips can't be uploaded until space is freed. Once it is, the clips will upload on their own if the phone is on and Just Capture hasn't been force-closed, though this can take a while. You may not get another email from this account after that. If you have access to this Google account or manage its family plan, you can add storage at one.google.com."
    /// Used instead if Drive fills up before the low-storage email went out.
    static let storageFullNote = "Google Drive storage is full, so new clips can't be uploaded right now. Once space is freed, the clips will upload on their own if the phone is on and Just Capture hasn't been force-closed, though this can take a while. If you have access to this Google account or manage its family plan, you can add storage at one.google.com."

    var alertsEnabled: Bool
    var recipients: [String]
    var subject: String
    var note: String
    var includeTime: Bool
    /// The app-wide location switch, not just an email option: when off, the
    /// app doesn't fetch location for recordings or emails.
    var locationEnabled: Bool

    static var current: EmailSettings {
        let defaults = UserDefaults.standard
        let rawSubject = defaults.string(forKey: "emailSubject")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return EmailSettings(
            alertsEnabled: (defaults.object(forKey: "emailAlertsEnabled") as? Bool) ?? true,
            recipients: parseRecipients(defaults.string(forKey: "emailRecipients") ?? ""),
            subject: rawSubject.isEmpty ? defaultSubject : rawSubject,
            note: defaults.string(forKey: "emailNote")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            includeTime: (defaults.object(forKey: "includeTimeInEmail") as? Bool) ?? true,
            locationEnabled: (defaults.object(forKey: "locationEnabled") as? Bool) ?? true
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
}
