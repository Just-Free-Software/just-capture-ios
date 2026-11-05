import Foundation
import CoreLocation

/// One line in a recording's location trail: where the recording started, or
/// where the phone was when a clip ended. A clip with no recent position still
/// gets a line, with nil coordinates, so the gap is visible.
struct LocationPoint: Codable, Equatable {
    let date: Date
    /// The finished clip this belongs to; nil for the recording's start.
    let clipFileName: String?
    let latitude: Double?
    let longitude: Double?
    /// Radius in meters that the true position is likely within.
    let accuracy: Double?
    /// The phone had no current position, so this is the last one it knew,
    /// from `date`. Optional so trails saved without it still load.
    let isLastKnown: Bool?

    /// A fix older than this isn't where the phone is now.
    static let currentFixMaxAge: TimeInterval = 30
    /// Above this radius, a street address would claim more than the fix knows.
    static let streetAddressMaxAccuracy: Double = 100

    init(location: CLLocation, clipFileName: String?) {
        date = location.timestamp
        isLastKnown = -location.timestamp.timeIntervalSinceNow > Self.currentFixMaxAge
self.clipFileName = clipFileName
        latitude = location.coordinate.latitude
        longitude = location.coordinate.longitude
        accuracy = location.horizontalAccuracy
    }

    init(noLocationAt date: Date, clipFileName: String) {
        self.date = date
        self.clipFileName = clipFileName
        latitude = nil
        longitude = nil
        accuracy = nil
        isLastKnown = nil
    }

    /// Text for a fix too rough for a street address, e.g. "Near Boston, MA
    /// (within about 12 km)". States the accuracy because emails and the trail
    /// header show this without the coordinates' accuracy next to it.
    static func approximateAddress(area: String, accuracy: Double) -> String {
        let radius = accuracy >= 1000
            ? "\(Int((accuracy / 1000).rounded())) km"
            : "\(Int(accuracy.rounded())) m"
        return "Near \(area) (within about \(radius))"
    }

    /// Negative accuracy means the fix is invalid. Coarse fixes are kept, since
    /// a rough area beats nothing and each line states its accuracy.
    static func isUsable(_ location: CLLocation) -> Bool {
        location.horizontalAccuracy >= 0
    }
}

@Observable
class RecordingSession: Identifiable, Codable {
    let id: String
    let startDate: Date
    var chunks: [VideoChunk]
    var driveFolderId: String?
    var driveFolderLink: String?
    /// Whether the Drive folder has been shared with anyone who has the link.
    /// `false` means sharing is still owed and will be retried; `nil` means the
    /// folder is left private (no one has been notified about this session, the
    /// session predates sharing, or the account's policy forbids public links).
    var driveFolderShared: Bool?
    var locationAddress: String?
    var latitude: Double?
    var longitude: Double?
    /// When the start location fix was taken, which can be slightly before
    /// `startDate`.
    var locationDate: Date?
    /// The start of the recording plus one entry per finished clip, oldest
    /// first. Optional so sessions saved before trails existed still load.
    var locationTrail: [LocationPoint]?
    var locationFileId: String?
    /// What's in the Drive copy of `locationText`, to tell if it's out of date.
    var uploadedLocationText: String?
    var chunkDuration: TimeInterval
    var isActive: Bool
    var playlistFileId: String?

    @ObservationIgnored private static var lastIssuedBase: String?
    @ObservationIgnored private static var collisionCount = 0

    init(chunkDuration: TimeInterval) {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        // Ids have one-second resolution; a stop-and-restart within the same
        // second would otherwise reuse the previous session's id and folder.
        var id = formatter.string(from: now)
        if id == Self.lastIssuedBase {
            Self.collisionCount += 1
            id += "_\(Self.collisionCount + 1)"
        } else {
            Self.lastIssuedBase = id
            Self.collisionCount = 0
        }
        self.id = id
        self.startDate = now
        self.chunks = []
        self.chunkDuration = chunkDuration
        self.isActive = true
        self.playlistFileId = nil
    }

    /// Records where the recording started. Does nothing once the trail has begun.
    func addStartToTrail(_ location: CLLocation) {
        guard locationTrail == nil else { return }
        locationTrail = [LocationPoint(location: location, clipFileName: nil)]
    }
    
    /// Records where the phone was when a clip ended; nil if it isn't known.
    func addClipToTrail(_ location: CLLocation?, clipFileName: String) {
        let point = location.map { LocationPoint(location: $0, clipFileName: clipFileName) }
            ?? LocationPoint(noLocationAt: Date(), clipFileName: clipFileName)
        locationTrail = (locationTrail ?? []) + [point]
    }
    
    /// Contents of the session's `location.txt` on Drive, once a location is
    /// known. Each upload replaces the file with the whole trail so far.
    var locationText: String? {
        let trail = locationTrail ?? []
        guard trail.contains(where: { $0.latitude != nil }) || latitude != nil else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm:ss a zzz"
        var lines = ["Recording started: \(formatter.string(from: startDate))"]
        if let locationAddress {
            lines.append("Starting address: \(locationAddress)")
        }
        lines.append("")
        lines.append("Location trail (oldest first):")
        if trail.isEmpty, let latitude, let longitude {
            lines.append("\(locationDate.map(formatter.string(from:)) ?? "Unknown time") | recording start | \(latitude), \(longitude) | https://www.google.com/maps?q=\(latitude),\(longitude)")
        }
        for point in trail {
            var fields = [formatter.string(from: point.date), point.clipFileName ?? "recording start"]
            if let latitude = point.latitude, let longitude = point.longitude {
                if point.isLastKnown == true {
                    fields.append("last known position")
                }
                fields.append("\(latitude), \(longitude)")
if let accuracy = point.accuracy {
                    fields.append("within \(Int(accuracy.rounded())) m")
                }
                fields.append("https://www.google.com/maps?q=\(latitude),\(longitude)")
            } else {
                fields.append("no location available")
            }
            lines.append(fields.joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }
    
    var folderName: String {
        "Session \(id)"
    }
    
    var uploadedCount: Int {
        chunks.filter { $0.status == .uploaded }.count
    }
    
    var failedCount: Int {
        chunks.filter { $0.status == .failed }.count
    }
    
    var totalCount: Int {
        chunks.count
    }
    
    /// Where this session's chunks live, whether or not it exists yet.
    var directoryURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("recordings/\(id)/")
    }
    
    func outputDirectory() -> URL {
        let directoryURL = directoryURL
        
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            do {
                try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true, attributes: nil)
            } catch {
                print("Error creating directory: \(error)")
            }
        }
        
        return directoryURL
    }
}
