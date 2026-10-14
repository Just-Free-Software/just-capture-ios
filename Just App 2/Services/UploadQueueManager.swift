import Foundation
import Observation

@Observable
class UploadQueueManager {
    private(set) var isProcessing: Bool = false
    /// Set when a Drive upload fails because the account's storage quota is
    /// exhausted. Observed by the UI to stop recording and alert the user.
    var storageExceeded = false
    weak var sessionStore: SessionStore?
    private var activeTasks: Int = 0
    private var uploadTasks: [UUID: Task<Void, Never>] = [:]
    
    /// Mirrors the "Save Chunks Locally" setting in UserDefaults. Defaults to true
    /// (preserve files after upload) when the key has never been written.
    private static var saveChunksLocally: Bool {
        (UserDefaults.standard.object(forKey: "saveChunksLocally") as? Bool) ?? true
    }
    
    /// Backoff for re-checking Drive after the quota is exhausted. The first
    /// re-check happens after a few minutes, then the interval doubles up to
    /// a cap, since freeing space typically requires the user to act. Checks
    /// are cheap (quota endpoint only), so the cap is generous.
    static let storageRetryInitialDelay: TimeInterval = 5 * 60
    static let storageRetryMaxDelay: TimeInterval = 24 * 60 * 60
    static let storageRetryFactor: Double = 2
    
    static func storageRetryDelay(forQuotaAttempt attempt: Int) -> TimeInterval {
        var delay = storageRetryInitialDelay
        for _ in 1..<max(1, attempt) { delay = min(storageRetryMaxDelay, delay * storageRetryFactor) }
        return delay
    }
    
    func enqueue(chunk: VideoChunk, session: RecordingSession, authManager: GoogleAuthManager) {
        uploadTasks[chunk.id]?.cancel()
        let task = Task { @MainActor in
            chunk.status = .uploading
            chunk.uploadProgress = 0
            var attempt = 0
            var quotaAttempt = 0
            while true {
                guard !Task.isCancelled else { return }
                do {
                    let token = try await authManager.validAccessToken()
                    
                    if session.driveFolderId == nil {
                        let result = try await GoogleDriveService.createFolder(name: session.folderName, accessToken: token)
                        session.driveFolderId = result.folderId
                        session.driveFolderLink = result.webViewLink
                        sessionStore?.save()
                    }
                    
                    guard let folderId = session.driveFolderId else { throw URLError(.unknown) }
                    
                    let fileId = try await GoogleDriveService.uploadFile(localURL: chunk.localURL, fileName: chunk.fileName, folderId: folderId, accessToken: token) { progress in
                        Task { @MainActor in
                            chunk.uploadProgress = progress
                        }
                    }
                    
                    chunk.status = .uploaded
                    chunk.driveFileId = fileId
                    storageExceeded = false
                    sessionStore?.save()
                    
                    if !Self.saveChunksLocally {
                        try? FileManager.default.removeItem(at: chunk.localURL)
                    }
                    
                    await updatePlaylist(session: session, authManager: authManager)
                    return
                } catch {
                    if case DriveError.storageQuotaExceeded = error {
                        // Recording keeps going; the chunk stays queued. Freeing
                        // space usually needs the user to act, so back off
                        // exponentially, and between attempts just poll the
                        // (cheap) quota endpoint instead of pushing the whole
                        // file into a 403 again.
                        chunk.status = .pending
                        chunk.uploadProgress = 0
                        storageExceeded = true
                        sessionStore?.save()
                        quotaAttempt += 1
                        let delay = Self.storageRetryDelay(forQuotaAttempt: quotaAttempt)
                        print("🛑 Chunk \(chunk.index + 1) can't upload: Google Drive storage is full. Re-checking in \(Int(delay / 60)) min.")
                        while true {
                            guard !Task.isCancelled else { return }
                            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                            guard !Task.isCancelled else { return }
                            do {
                                let token = try await authManager.validAccessToken()
                                let quota = try await GoogleDriveService.getStorageQuota(accessToken: token)
                                // nil availableBytes = unlimited quota, always uploadable
                                if (quota.availableBytes ?? Int64.max) > 0 { break }
                            } catch {
                                // Couldn't read the quota (e.g. offline) — fall
                                // through and let the upload attempt itself
                                // surface whatever the real error is.
                                break
                            }
                        }
                        continue
                    }
                    attempt += 1
                    if attempt >= RetryPolicy.maxAttempts {
                        chunk.status = .failed
                        chunk.uploadProgress = 0
                        sessionStore?.save()
                        print("🛑 Chunk \(chunk.index + 1) failed after \(attempt) attempts: \(error.localizedDescription)")
                        return
                    }
                    chunk.uploadProgress = 0
                    let delay = RetryPolicy.delay(forAttempt: attempt)
                    print("📤 Upload attempt \(attempt) for chunk \(chunk.index + 1) failed, retrying in \(Int(delay))s: \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        uploadTasks[chunk.id] = task
    }
    
    func retryChunk(_ chunk: VideoChunk, session: RecordingSession, authManager: GoogleAuthManager) {
        enqueue(chunk: chunk, session: session, authManager: authManager)
    }
    
    /// Cancels every in-flight upload belonging to a session. Used when the
    /// session is being deleted so a late upload can't resurrect it.
    func cancelUploads(for session: RecordingSession) {
        for chunk in session.chunks {
            uploadTasks[chunk.id]?.cancel()
            uploadTasks.removeValue(forKey: chunk.id)
        }
    }
    
    /// On app launch, re-enqueue every chunk that wasn't confirmed uploaded so
    /// a backgrounding/kill mid-outage doesn't permanently strand uploads.
    /// Chunks whose local file is already gone (e.g. `.uploaded` after a
    /// save-Chunks-locally-off clean-up) are skipped; `.pending`/`.uploading`
    /// chunks with no file are marked `.failed` so the user sees the truth.
    func resumePendingUploads(authManager: GoogleAuthManager) {
        guard let sessions = sessionStore?.sessions else { return }
        var changed = false
        for session in sessions {
            for chunk in session.chunks where chunk.status != .uploaded {
                if FileManager.default.fileExists(atPath: chunk.localURL.path) {
                    chunk.uploadProgress = 0
                    enqueue(chunk: chunk, session: session, authManager: authManager)
                } else if chunk.status == .pending || chunk.status == .uploading {
                    chunk.status = .failed
                    changed = true
                }
            }
        }
        if changed { sessionStore?.save() }
    }
    
    func updatePlaylist(session: RecordingSession, authManager: GoogleAuthManager) async {
        do {
            let token = try await authManager.validAccessToken()
            guard let folderId = session.driveFolderId else { return }
            
            let content = generatePlaylistContent(for: session)
            let fileId = try await GoogleDriveService.uploadOrUpdatePlaylist(content: content, folderId: folderId, existingFileId: session.playlistFileId, accessToken: token)
            session.playlistFileId = fileId
            sessionStore?.save()
        } catch {
            print("Failed to update playlist: \(error)")
        }
    }
    
    private func generatePlaylistContent(for session: RecordingSession) -> String {
        var m3u8 = """
        #EXTM3U
        #EXT-X-VERSION:3
        #EXT-X-TARGETDURATION:\(Int(ceil(session.chunkDuration)))
        #EXT-X-MEDIA-SEQUENCE:0
        """
        
        for chunk in session.chunks where chunk.status == .uploaded {
            if let fileId = chunk.driveFileId {
                m3u8 += "\n#EXTINF:\(chunk.duration),\n"
                m3u8 += "\(GoogleDriveService.getDirectDownloadURL(fileId: fileId))"
            }
        }
        
        if !session.isActive {
            m3u8 += "\n#EXT-X-ENDLIST"
        }
        
        return m3u8
    }
}
