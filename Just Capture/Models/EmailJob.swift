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
    /// Optional so jobs saved by older builds still decode. When true and no
    /// coordinates were known at enqueue time, the queue fills them in from a
    /// fresh fix right before sending.
    var includeLocation: Bool?
    var address: String?
    var latitude: Double?
    var longitude: Double?
    var status: EmailStatus
    var attempts: Int
    var lastAttemptAt: Date?
    /// Set when this alert went out before the session's Drive folder existed,
    /// so it carried no link. Cleared once a link follow-up has been queued.
    var needsLinkFollowUp: Bool?
    /// True for the follow-up email that delivers a late link. Follow-ups
    /// never owe a follow-up of their own.
    var isLinkFollowUp: Bool?

    init(
        createdAt: Date = Date(),
        sessionId: String,
        recipients: [String],
        subject: String,
        bodyNote: String,
        includeTime: Bool,
        includeLocation: Bool,
        address: String?,
        latitude: Double?,
        longitude: Double?
    ) {
        self.id = UUID()
        self.sessionId = sessionId
        self.createdAt = createdAt
        self.recipients = recipients
        self.subject = subject
        self.bodyNote = bodyNote
        self.includeTime = includeTime
        self.includeLocation = includeLocation
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.status = .pending
        self.attempts = 0
        self.lastAttemptAt = nil
    }
}