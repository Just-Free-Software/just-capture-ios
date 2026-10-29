import Foundation

@Observable
class VideoChunk: Identifiable, Codable {
    let id: UUID
    let index: Int
    /// Absolute path as of the last save. iOS can move the app's container
    /// between launches (e.g. after an update), so SessionStore rebases this
    /// onto the current Documents directory when loading.
    var localURL: URL
    let createdAt: Date
    var duration: TimeInterval
    var fileSize: Int64
    var status: UploadStatus
    var uploadProgress: Double
    var driveFileId: String?
    
    init(index: Int, localURL: URL, duration: TimeInterval = 0, fileSize: Int64 = 0) {
        self.id = UUID()
        self.index = index
        self.localURL = localURL
        self.createdAt = Date()
        self.duration = duration
        self.fileSize = fileSize
        self.status = .pending
        self.uploadProgress = 0.0
    }
    
    var fileName: String {
        localURL.lastPathComponent
    }
    
    var formattedFileSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSize)
    }
}
