import Foundation

enum DriveError: LocalizedError, Equatable {
    case storageQuotaExceeded
    
    var errorDescription: String? {
        switch self {
        case .storageQuotaExceeded:
            return "Google Drive storage is full."
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
}
