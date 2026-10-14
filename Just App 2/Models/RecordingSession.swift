import Foundation

@Observable
class RecordingSession: Identifiable, Codable {
    let id: String
    let startDate: Date
    var chunks: [VideoChunk]
    var driveFolderId: String?
    var driveFolderLink: String?
    var locationAddress: String?
    var latitude: Double?
    var longitude: Double?
    var chunkDuration: TimeInterval
    var isActive: Bool
    var playlistFileId: String?
    
    init(chunkDuration: TimeInterval) {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        self.id = formatter.string(from: now)
        self.startDate = now
        self.chunks = []
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
    
    func outputDirectory() -> URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let documentsDirectory = paths[0]
        let directoryURL = documentsDirectory.appendingPathComponent("recordings/\(id)/")
        
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
