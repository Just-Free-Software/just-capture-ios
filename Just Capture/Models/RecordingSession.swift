import Foundation

@Observable
class RecordingSession: Identifiable, Codable {
    let id: String
    let startDate: Date
    var chunks: [VideoChunk]
    var driveFolderId: String?
    var driveFolderLink: String?
    /// Whether the Drive folder has been shared with anyone who has the link.
    /// `false` means sharing is still owed and will be retried; `nil` means the
    /// folder is left private (the session predates sharing, or the account's
    /// policy forbids public links).
    var driveFolderShared: Bool?
    var locationAddress: String?
    var latitude: Double?
    var longitude: Double?
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
        self.driveFolderShared = false
        self.chunkDuration = chunkDuration
        self.isActive = true
        self.playlistFileId = nil
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
