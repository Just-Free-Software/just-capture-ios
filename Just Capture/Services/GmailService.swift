import Foundation

enum GmailService {
    static func sendEmergencyEmail(to recipients: [String], subject: String, bodyNote: String, startedAt: Date?, address: String?, latitude: Double?, longitude: Double?, driveFolderLink: String?, accessToken: String) async throws {
        let html = buildEmailHTML(
            subject: subject,
            startedAt: startedAt,
            address: address,
            latitude: latitude,
            longitude: longitude,
            driveFolderLink: driveFolderLink,
            bodyNote: bodyNote
        )
        
        let htmlBase64 = html.data(using: .utf8)?.base64EncodedString(options: .lineLength76Characters) ?? ""
        // Strip CR/LF so user-entered values can't break out of their header.
        let to = recipients.map { $0.replacingOccurrences(of: "[\\r\\n]", with: "", options: .regularExpression) }.joined(separator: ", ")
        let subjectBase64 = subject.data(using: .utf8)?.base64EncodedString() ?? ""
        let encodedSubject = "=?utf-8?B?" + subjectBase64 + "?="
        
        let mime = """
        From: me
        To: \(to)
        Subject: \(encodedSubject)
        MIME-Version: 1.0
        Content-Type: text/html; charset=utf-8
        Content-Transfer-Encoding: base64
        X-Priority: 1
        Importance: high

        \(htmlBase64)
        """.replacingOccurrences(of: "\n", with: "\r\n")
        
        guard let data = mime.data(using: .utf8) else { throw URLError(.unknown) }
        let base64url = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        
        guard let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = ["raw": base64url]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (responseData, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
            let errorString = String(data: responseData, encoding: .utf8) ?? "Unknown Error"
            print("Gmail API Error: \(errorString)")
            throw URLError(.badServerResponse)
        }
        
        print("✅ Email sent successfully to \(recipients.joined(separator: ", "))!")
    }
    
    // TODO: Replace with the real App Store link once the app is listed.
    private static let appDownloadURL = "https://justfreesoftware.fyi/just-capture/info"
    
    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "\n", with: "<br>")
    }
    
    private static func buildEmailHTML(subject: String, startedAt: Date?, address: String?, latitude: Double?, longitude: Double?, driveFolderLink: String?, bodyNote: String) -> String {
        var template = loadTemplate()
        
        template = template.replacingOccurrences(of: "{{SUBJECT}}", with: escapeHTML(subject))
        
        // Use the time the recording started (when the job was queued), not
        // the time this particular send attempt happens to succeed.
        if let startedAt {
            let timestampFormatter = DateFormatter()
            timestampFormatter.dateFormat = "MMM d, yyyy 'at' h:mm a zzz"
            timestampFormatter.timeZone = .current
            let timeString = timestampFormatter.string(from: startedAt)
            let timeHtml = "<p>Recording started: \(timeString)</p>"
            template = template.replacingOccurrences(of: "{{TIMESTAMP_SECTION}}", with: timeHtml)
            template = template.replacingOccurrences(of: "{{TIMESTAMP}}", with: timeString)
        } else {
            template = template.replacingOccurrences(of: "{{TIMESTAMP_SECTION}}", with: "")
            template = template.replacingOccurrences(of: "{{TIMESTAMP}}", with: "")
        }
        
        if let address = address, !address.isEmpty {
            let addressHtml = "<p>Location: \(escapeHTML(address))</p>"
            template = template.replacingOccurrences(of: "{{ADDRESS_SECTION}}", with: addressHtml)
        } else {
            template = template.replacingOccurrences(of: "{{ADDRESS_SECTION}}", with: "")
        }
        
        if let lat = latitude, let lng = longitude {
            let mapHtml = "<p><a href=\"https://www.google.com/maps?q=\(lat),\(lng)\">View location on Google Maps</a></p>"
            template = template.replacingOccurrences(of: "{{MAP_LINK_SECTION}}", with: mapHtml)
        } else {
            template = template.replacingOccurrences(of: "{{MAP_LINK_SECTION}}", with: "")
        }
        
        if let link = driveFolderLink, !link.isEmpty {
            let driveHtml = "<p><a href=\"\(escapeHTML(link))\">View the live recording on Google Drive</a></p>"
            template = template.replacingOccurrences(of: "{{DRIVE_LINK_SECTION}}", with: driveHtml)
        } else {
            template = template.replacingOccurrences(of: "{{DRIVE_LINK_SECTION}}", with: "")
        }
        
        if !bodyNote.isEmpty {
            let noteHtml = "<p>Note: \(escapeHTML(bodyNote))</p>"
            template = template.replacingOccurrences(of: "{{NOTE_SECTION}}", with: noteHtml)
        } else {
            template = template.replacingOccurrences(of: "{{NOTE_SECTION}}", with: "")
        }
        
        let appHtml = "<p style=\"color: #888888; font-size: 12px;\">For a better viewing experience, <a href=\"\(escapeHTML(appDownloadURL))\">download Just Capture</a>.</p>"
        template = template.replacingOccurrences(of: "{{APP_LINK_SECTION}}", with: appHtml)
        
        return template
    }
    
    private static func loadTemplate() -> String {
        if let url = Bundle.main.url(forResource: "EmailTemplate", withExtension: "html"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
        
        // Fallback default template if file cannot be loaded from bundle
        return """
        <!DOCTYPE html>
        <html>
        <body style="font-family: sans-serif; font-size: 14px;">
            <p><strong>{{SUBJECT}}</strong></p>
            {{TIMESTAMP_SECTION}}
            {{ADDRESS_SECTION}}
            {{MAP_LINK_SECTION}}
            {{DRIVE_LINK_SECTION}}
            {{NOTE_SECTION}}
            {{APP_LINK_SECTION}}
        </body>
        </html>
        """
    }
}

