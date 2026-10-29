
enum UploadStatus: String, Codable, Sendable {
    case pending
    case uploading
    case uploaded
    case failed
}
