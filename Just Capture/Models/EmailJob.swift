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
    /// When true and no coordinates were known at enqueue time, the queue fills
    /// them in from a fresh fix right before sending.
    var includeLocation: Bool
    var address: String?
    var latitude: Double?
    var longitude: Double?
    var status: EmailStatus
    var attempts: Int
    var lastAttemptAt: Date?
    /// Set when this alert went out before the session's Drive folder existed,
    /// so it carried no link. Cleared once a link follow-up has been queued.
    var needsLinkFollowUp = false
    /// True for the follow-up email that delivers a late link. Follow-ups
    /// never owe a follow-up of their own.
    var isLinkFollowUp = false

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

    // The `var`s carry underscores because that is what @Observable calls
    // their storage, and so what jobs already on disk use as keys.
    private enum CodingKeys: String, CodingKey {
        case id, sessionId, createdAt, _recipients, _subject, _bodyNote, _includeTime
        case _includeLocation, _address, _latitude, _longitude, _status, _attempts, _lastAttemptAt
        case _needsLinkFollowUp, _isLinkFollowUp
    }

    /// Written by hand because the synthesized decoder ignores default values:
    /// a job saved before a property existed would fail to decode, and one
    /// failure discards the whole outbox. The three flags added after the
    /// first release fall back to false.
    required init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        sessionId = try values.decode(String.self, forKey: .sessionId)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        _recipients = try values.decode([String].self, forKey: ._recipients)
        _subject = try values.decode(String.self, forKey: ._subject)
        _bodyNote = try values.decode(String.self, forKey: ._bodyNote)
        _includeTime = try values.decode(Bool.self, forKey: ._includeTime)
        _includeLocation = try values.decodeIfPresent(Bool.self, forKey: ._includeLocation) ?? false
        _address = try values.decodeIfPresent(String.self, forKey: ._address)
        _latitude = try values.decodeIfPresent(Double.self, forKey: ._latitude)
        _longitude = try values.decodeIfPresent(Double.self, forKey: ._longitude)
        _status = try values.decode(EmailStatus.self, forKey: ._status)
        _attempts = try values.decode(Int.self, forKey: ._attempts)
        _lastAttemptAt = try values.decodeIfPresent(Date.self, forKey: ._lastAttemptAt)
        _needsLinkFollowUp = try values.decodeIfPresent(Bool.self, forKey: ._needsLinkFollowUp) ?? false
        _isLinkFollowUp = try values.decodeIfPresent(Bool.self, forKey: ._isLinkFollowUp) ?? false
    }
}