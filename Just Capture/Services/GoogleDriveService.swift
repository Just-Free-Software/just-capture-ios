import Foundation

enum DriveError: LocalizedError, Equatable {
    case storageQuotaExceeded
    /// The account (typically a Workspace one) has an admin policy that
    /// forbids sharing files with anyone outside the organization.
    case publicSharingNotAllowed
    /// Drive throttled a read; `reason` is Drive's own name for the limit,
    /// e.g. `userRateLimitExceeded` or `downloadQuotaExceeded`.
    case rateLimited(reason: String)
    /// An anonymous read found nothing: the folder isn't shared as "anyone
    /// with the link", or the link is wrong.
    case notPublic
    case apiKeyMissing
    case apiKeyRejected
    case readFailed(status: Int, reason: String?)

    var errorDescription: String? {
        switch self {
        case .storageQuotaExceeded:
            return "Google Drive storage is full."
        case .publicSharingNotAllowed:
            return "This Google account doesn't allow sharing files publicly."
        case .rateLimited(let reason):
            return "Google Drive is limiting downloads right now (\(reason)). Wait a while before trying again."
        case .notPublic:
            return "This folder isn't shared publicly. Ask the owner to share it as \"Anyone with the link\"."
        case .apiKeyMissing:
            return "Opening shared links needs a Google API key, and none is set up in this build."
        case .apiKeyRejected:
            return "Google rejected this app's API key. Check its restrictions in Cloud Console."
        case .readFailed(let status, let reason):
            return "Google Drive returned an error (\(reason ?? "HTTP \(status)"))."
        }
    }
}

struct DriveStorageQuota: Equatable {
    let limit: Int64?
    let usage: Int64
    
    var isUnlimited: Bool {
        guard let limit = limit else { return true }
        return limit <= 0
    }
    
    var availableBytes: Int64? {
        guard !isUnlimited, let limit = limit else { return nil }
        return max(0, limit - usage)
    }
}

enum GoogleDriveService {
    static func getStorageQuota(accessToken: String) async throws -> DriveStorageQuota {
        guard let url = URL(string: "https://www.googleapis.com/drive/v3/about?fields=storageQuota") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try throwIfQuotaExceeded(data: data, statusCode: httpResponse.statusCode)
        guard (200...299).contains(httpResponse.statusCode) else { throw URLError(.badServerResponse) }
        
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let quotaJson = json?["storageQuota"] as? [String: Any],
              let usageString = quotaJson["usage"] as? String,
              let usage = Int64(usageString) else {
            throw URLError(.badServerResponse)
        }
        
        let limit = (quotaJson["limit"] as? String).flatMap(Int64.init)
        return DriveStorageQuota(limit: limit, usage: usage)
    }
    
    static func throwIfQuotaExceeded(data: Data, statusCode: Int) throws {
        guard statusCode == 403,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let errors = error["errors"] as? [[String: Any]] else { return }
        if errors.contains(where: { ($0["reason"] as? String) == "storageQuotaExceeded" }) {
            throw DriveError.storageQuotaExceeded
        }
    }
    
    static func createFolder(name: String, accessToken: String) async throws -> (folderId: String, webViewLink: String) {
        guard let url = URL(string: "https://www.googleapis.com/drive/v3/files?fields=id,webViewLink") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = ["name": name, "mimeType": "application/vnd.google-apps.folder"]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        if let httpResponse = response as? HTTPURLResponse {
            try throwIfQuotaExceeded(data: data, statusCode: httpResponse.statusCode)
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        
        guard let id = json?["id"] as? String, let webViewLink = json?["webViewLink"] as? String else {
            throw URLError(.badServerResponse)
        }
        
        return (id, webViewLink)
    }

    /// Makes a file or folder readable by anyone with its link. Files inside a
    /// folder inherit this, so the alert email's link opens for recipients
    /// without them having to request access.
    static func shareWithAnyoneWithLink(fileId: String, accessToken: String) async throws {
        guard let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)/permissions") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["role": "reader", "type": "anyone"]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try throwIfPublicSharingNotAllowed(data: data, statusCode: httpResponse.statusCode)
        guard (200...299).contains(httpResponse.statusCode) else { throw URLError(.badServerResponse) }
    }

    /// A 403 on a permission request is either a rate limit (reasons like
    /// `userRateLimitExceeded`, `sharingRateLimitExceeded`), which is worth
    /// retrying, or a sharing policy refusal, which never will succeed.
    private static func throwIfPublicSharingNotAllowed(data: Data, statusCode: Int) throws {
        guard statusCode == 403 else { return }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let errors = (json?["error"] as? [String: Any])?["errors"] as? [[String: Any]] ?? []
        let isRateLimited = errors.contains { ($0["reason"] as? String)?.hasSuffix("Exceeded") == true }
        if !isRateLimited {
            throw DriveError.publicSharingNotAllowed
        }
    }

    static func deleteFile(fileId: String, accessToken: String) async throws {
        guard let url = URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)") else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw URLError(.badServerResponse)
        }
    }
    
    static func uploadFile(localURL: URL, fileName: String, folderId: String, accessToken: String, onProgress: @Sendable @escaping (Double) -> Void) async throws -> String {
        guard let url = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable") else { throw URLError(.badURL) }
        
        let fileData = try Data(contentsOf: localURL)
        let fileSize = fileData.count
        
        var initiateRequest = URLRequest(url: url)
        initiateRequest.httpMethod = "POST"
        initiateRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        initiateRequest.setValue("video/mp4", forHTTPHeaderField: "X-Upload-Content-Type")
        initiateRequest.setValue("\(fileSize)", forHTTPHeaderField: "X-Upload-Content-Length")
        initiateRequest.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        
        let metadata: [String: Any] = ["name": fileName, "parents": [folderId]]
        initiateRequest.httpBody = try JSONSerialization.data(withJSONObject: metadata)
        
        let (initiateData, response) = try await URLSession.shared.data(for: initiateRequest)
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        try throwIfQuotaExceeded(data: initiateData, statusCode: httpResponse.statusCode)
        guard let resumableURLString = httpResponse.value(forHTTPHeaderField: "Location"),
              let resumableURL = URL(string: resumableURLString) else {
            throw URLError(.badServerResponse)
        }
        
        let chunkSize = 2 * 1024 * 1024
        var offset = 0
        var fileId: String? = nil
        
        if fileSize <= chunkSize {
            var uploadRequest = URLRequest(url: resumableURL)
            uploadRequest.httpMethod = "PUT"
            uploadRequest.setValue("\(fileSize)", forHTTPHeaderField: "Content-Length")
            let (data, uploadResponse) = try await URLSession.shared.upload(for: uploadRequest, from: fileData)
            if let httpUpResp = uploadResponse as? HTTPURLResponse, (200...299).contains(httpUpResp.statusCode) {
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                fileId = json?["id"] as? String
                onProgress(1.0)
            } else {
                if let httpUpResp = uploadResponse as? HTTPURLResponse {
                    try throwIfQuotaExceeded(data: data, statusCode: httpUpResp.statusCode)
                }
                throw URLError(.badServerResponse)
            }
        } else {
            while offset < fileSize {
                let currentChunkSize = min(chunkSize, fileSize - offset)
                let chunkData = fileData.subdata(in: offset..<(offset + currentChunkSize))
                
                var uploadRequest = URLRequest(url: resumableURL)
                uploadRequest.httpMethod = "PUT"
                uploadRequest.setValue("\(currentChunkSize)", forHTTPHeaderField: "Content-Length")
                uploadRequest.setValue("bytes \(offset)-\(offset + currentChunkSize - 1)/\(fileSize)", forHTTPHeaderField: "Content-Range")
                
                let (data, uploadResponse) = try await URLSession.shared.upload(for: uploadRequest, from: chunkData)
                if let httpUpResp = uploadResponse as? HTTPURLResponse {
                    if httpUpResp.statusCode == 308 {
                        offset += currentChunkSize
                        onProgress(Double(offset) / Double(fileSize))
                    } else if (200...299).contains(httpUpResp.statusCode) {
                        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                        fileId = json?["id"] as? String
                        onProgress(1.0)
                        break
                    } else {
                        try throwIfQuotaExceeded(data: data, statusCode: httpUpResp.statusCode)
                        throw URLError(.badServerResponse)
                    }
                }
            }
        }
        
        guard let id = fileId else { throw URLError(.badServerResponse) }
        return id
    }
    
    static func uploadOrUpdatePlaylist(content: String, folderId: String, existingFileId: String?, accessToken: String) async throws -> String {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request: URLRequest
        
        if let existingId = existingFileId {
            guard let url = URL(string: "https://www.googleapis.com/upload/drive/v3/files/\(existingId)?uploadType=multipart") else { throw URLError(.badURL) }
            request = URLRequest(url: url)
            request.httpMethod = "PATCH"
        } else {
            guard let url = URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart") else { throw URLError(.badURL) }
            request = URLRequest(url: url)
            request.httpMethod = "POST"
        }
        
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        
        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
        
        var metadata: [String: Any] = ["mimeType": "application/x-mpegURL"]
        if existingFileId == nil {
            metadata["name"] = "playlist.m3u8"
            metadata["parents"] = [folderId]
        }
        
        body.append(try JSONSerialization.data(withJSONObject: metadata))
        body.append("\r\n".data(using: .utf8)!)
        
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Type: application/x-mpegURL\r\n\r\n".data(using: .utf8)!)
        body.append(content.data(using: .utf8)!)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--".data(using: .utf8)!)
        
        request.httpBody = body
        
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        
        guard let fileId = json?["id"] as? String else { throw URLError(.badServerResponse) }
        return fileId
    }
    
    static func getDirectDownloadURL(fileId: String) -> String {
        return "https://www.googleapis.com/drive/v3/files/\(fileId)?alt=media"
    }

    // MARK: - Reading back from Drive

    /// How a read request identifies itself to Drive.
    enum ReadAccess {
        /// As the signed-in user. With the `drive.file` scope that only
        /// reaches files this app created.
        case user(accessToken: String)
        /// Anonymously, with the app's API key. Reaches any file shared as
        /// "anyone with the link", and nothing else.
        case publicLink
    }

    /// Upper bound on pages fetched by one listing, so a misbehaving
    /// `nextPageToken` can't turn into an endless stream of requests.
    private static let maxListPages = 5

    private static func readRequest(_ components: URLComponents, access: ReadAccess) throws -> URLRequest {
        var components = components
        if case .publicLink = access {
            guard !AppConfig.driveAPIKey.isEmpty else { throw DriveError.apiKeyMissing }
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "key", value: AppConfig.driveAPIKey)]
        }
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        switch access {
        case .user(let accessToken):
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        case .publicLink:
            // Lets the key be restricted to this app in Cloud Console.
            if let bundleId = Bundle.main.bundleIdentifier {
                request.setValue(bundleId, forHTTPHeaderField: "X-Ios-Bundle-Identifier")
            }
        }
        return request
    }

    /// Turns a failed read into an error that says which limit or permission
    /// was hit, using the `reason` Drive puts in the error body.
    private static func throwIfReadFailed(data: Data?, response: URLResponse, access: ReadAccess) throws {
        guard let httpResponse = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        let status = httpResponse.statusCode
        guard !(200...299).contains(status) else { return }

        let json = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let error = json?["error"] as? [String: Any]
        let reason = (error?["errors"] as? [[String: Any]])?.first?["reason"] as? String
            ?? (error?["status"] as? String)

        if status == 429 || reason == "userRateLimitExceeded" || reason == "rateLimitExceeded"
            || reason == "downloadQuotaExceeded" || reason == "dailyLimitExceeded" {
            throw DriveError.rateLimited(reason: reason ?? "HTTP \(status)")
        }
        if case .publicLink = access, status == 404 || reason == "notFound" {
            throw DriveError.notPublic
        }
        // A bad key is a 400 `keyInvalid`; a key whose app restriction
        // doesn't match is a 403 `forbidden`.
        if case .publicLink = access, reason == "keyInvalid" || (status == 403 && reason == "forbidden") {
            throw DriveError.apiKeyRejected
        }
        throw DriveError.readFailed(status: status, reason: reason)
    }

    /// Lists files matching a Drive search query, newest first.
    static func listFiles(query: String, access: ReadAccess) async throws -> [DriveFile] {
        var files: [DriveFile] = []
        var pageToken: String?

        for _ in 0..<maxListPages {
            var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            components.queryItems = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,size,createdTime)"),
                URLQueryItem(name: "orderBy", value: "createdTime desc"),
                URLQueryItem(name: "pageSize", value: "200"),
                URLQueryItem(name: "supportsAllDrives", value: "true"),
                URLQueryItem(name: "includeItemsFromAllDrives", value: "true")
            ]
            if let pageToken {
                components.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken))
            }
            let request = try readRequest(components, access: access)

            let (data, response) = try await URLSession.shared.data(for: request)
            try throwIfReadFailed(data: data, response: response, access: access)

            let page = try JSONDecoder.drive.decode(DriveFileList.self, from: data)
            files += page.files
            guard let next = page.nextPageToken, !next.isEmpty else { break }
            pageToken = next
        }
        return files
    }

    /// Session folders this app has created, newest first.
    static func listSessionFolders(accessToken: String) async throws -> [DriveFile] {
        try await listFiles(
            query: "mimeType = 'application/vnd.google-apps.folder' and name contains 'Session ' and trashed = false",
            access: .user(accessToken: accessToken)
        )
    }

    static func listFiles(inFolder folderId: String, access: ReadAccess) async throws -> [DriveFile] {
        try await listFiles(query: "'\(folderId)' in parents and trashed = false", access: access)
    }

    /// A single file or folder's metadata, e.g. a shared folder's name.
    static func getFile(fileId: String, access: ReadAccess) async throws -> DriveFile {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(fileId)")!
        components.queryItems = [
            URLQueryItem(name: "fields", value: "id,name,mimeType,size,createdTime"),
            URLQueryItem(name: "supportsAllDrives", value: "true")
        ]
        let request = try readRequest(components, access: access)
        let (data, response) = try await URLSession.shared.data(for: request)
        try throwIfReadFailed(data: data, response: response, access: access)
        return try JSONDecoder.drive.decode(DriveFile.self, from: data)
    }

    private static func mediaComponents(fileId: String) -> URLComponents {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(fileId)")!
        components.queryItems = [
            URLQueryItem(name: "alt", value: "media"),
            URLQueryItem(name: "supportsAllDrives", value: "true")
        ]
        return components
    }

    static func downloadData(fileId: String, access: ReadAccess) async throws -> Data {
        let request = try readRequest(mediaComponents(fileId: fileId), access: access)
        let (data, response) = try await URLSession.shared.data(for: request)
        try throwIfReadFailed(data: data, response: response, access: access)
        return data
    }

    /// Streams a file straight to disk at `destination`, replacing anything there.
    static func downloadFile(fileId: String, to destination: URL, access: ReadAccess) async throws {
        let request = try readRequest(mediaComponents(fileId: fileId), access: access)
        let (tempURL, response) = try await URLSession.shared.download(for: request)
        do {
            // An error body is small JSON saved to the temp file.
            let errorBody = (response as? HTTPURLResponse).map { (200...299).contains($0.statusCode) } == true
                ? nil : try? Data(contentsOf: tempURL)
            try throwIfReadFailed(data: errorBody, response: response, access: access)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }

    /// Pulls a folder id out of the links Drive hands out, e.g.
    /// `https://drive.google.com/drive/folders/<id>?usp=sharing`,
    /// `.../drive/u/0/folders/<id>` or `.../open?id=<id>`. A bare id is
    /// accepted as-is.
    static func folderId(fromLink text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isId: (Substring) -> Bool = { candidate in
            candidate.count >= 10 && candidate.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
        if isId(Substring(trimmed)) { return trimmed }

        guard let components = URLComponents(string: trimmed),
              let host = components.host, host.hasSuffix("google.com") else { return nil }
        let parts = components.path.split(separator: "/")
        if let index = parts.firstIndex(of: "folders"), index + 1 < parts.count, isId(parts[index + 1]) {
            return String(parts[index + 1])
        }
        if let id = components.queryItems?.first(where: { $0.name == "id" })?.value, isId(Substring(id)) {
            return id
        }
        return nil
    }
}

struct DriveFile: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let mimeType: String
    /// Drive reports sizes as strings, and omits them for folders.
    let size: String?
    let createdTime: Date?

    var byteCount: Int64? { size.flatMap(Int64.init) }
}

private struct DriveFileList: Decodable {
    let files: [DriveFile]
    let nextPageToken: String?
}

private extension JSONDecoder {
    static let drive: JSONDecoder = {
        let decoder = JSONDecoder()
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = withFraction.date(from: string) ?? plain.date(from: string) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(string)"))
        }
        return decoder
    }()
}
