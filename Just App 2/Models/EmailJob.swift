import Foundation

enum EmailStatus: String, Codable, Sendable {
    case pending
    case sending
    case sent
    case failed
}

@Observable
class EmailJob: Identifiable, Codable {
    let id: UUID
    let sessionId: String
    let createdAt: Date
    var recipients: [String]
    var subject: String
    var bodyNote: String
    var includeTime: Bool
    var address: String?
    var latitude: Double?
    var longitude: Double?
    var status: EmailStatus
    var attempts: Int
    var lastAttemptAt: Date?
    
    init(
        sessionId: String,
        recipients: [String],
        subject: String,
        bodyNote: String,
        includeTime: Bool,
        address: String?,
        latitude: Double?,
        longitude: Double?
    ) {
        self.id = UUID()
        self.sessionId = sessionId
        self.createdAt = Date()
        self.recipients = recipients
        self.subject = subject
        self.bodyNote = bodyNote
        self.includeTime = includeTime
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.status = .pending
        self.attempts = 0
        self.lastAttemptAt = nil
    }
}