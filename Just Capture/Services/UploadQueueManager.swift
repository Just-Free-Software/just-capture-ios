import Foundation
import Observation

@Observable
class UploadQueueManager {
    /// Set when a Drive upload fails because the account's storage quota is
    /// exhausted. Observed by the UI to stop recording and alert the user.
    var storageExceeded = false
    /// Set when the signed-in account can't share folders publicly (usually a
    /// Workspace admin policy), so alert-email links won't open for
    /// recipients. Observed by the UI to warn the user ahead of time.
    private(set) var publicSharingBlocked = false
    weak var sessionStore: SessionStore?
    /// Called once a session's Drive folder exists, so alert emails that went
    /// out without a link can send it.
    var onFolderCreated: ((RecordingSession) -> Void)?
    /// Called after each chunk lands in Drive, so the storage figure can be
    /// updated without waiting for a quota refresh.
    var onChunkUploaded: ((VideoChunk) -> Void)?
    private var uploadTasks: [UUID: Task<Void, Never>] = [:]
    /// One in-flight Drive folder creation per session. Without this, the
    /// recording start and the first chunk uploads each create their own
    /// folder and the session's clips end up split across several folders.
    private var folderTasks: [String: Task<String, Error>] = [:]
    /// One in-flight folder-sharing request per session, so parallel uploads
    /// don't each send their own permission request.
    private var shareTasks: [String: Task<Void, Never>] = [:]
    /// Tail of each session's playlist-write chain, so concurrent uploads
    /// don't race to create duplicate playlist.m3u8 files.
    private var playlistTasks: [String: Task<Void, Never>] = [:]
    
    /// Caps simultaneous file uploads at `AppConfig.maxConcurrentUploads`.
    /// After an outage dozens of chunks may be queued; pushing them all at once
    /// on a weak connection makes every one of them slower to land.
    private var activeUploads = 0
    private var slotWaiters: [CheckedContinuation<Void, Never>] = []
    
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
    
    private func acquireUploadSlot() async {
        if activeUploads < AppConfig.maxConcurrentUploads {
            activeUploads += 1
            return
        }
        await withCheckedContinuation { slotWaiters.append($0) }
    }
    
    private func releaseUploadSlot() {
        if slotWaiters.isEmpty {
            activeUploads -= 1
        } else {
            // Hand the slot straight to the next waiter.
            slotWaiters.removeFirst().resume()
        }
    }
    
    /// Returns the session's Drive folder id, creating the folder if needed.
    /// Concurrent callers share a single creation request.
    func ensureFolder(for session: RecordingSession, authManager: GoogleAuthManager) async throws -> String {
        if let id = session.driveFolderId {
            if session.driveFolderShared == false {
                await shareFolder(for: session, authManager: authManager)
            }
            return id
        }
        if let pending = folderTasks[session.id] { return try await pending.value }
        let task = Task { @MainActor in
            let token = try await authManager.validAccessToken()
            let result = try await GoogleDriveService.createFolder(name: session.folderName, accessToken: token)
            session.driveFolderId = result.folderId
            session.driveFolderLink = result.webViewLink
            self.sessionStore?.save()
            await self.shareFolder(for: session, authManager: authManager)
            // After sharing, so a follow-up link works when it's opened.
            self.onFolderCreated?(session)
            return result.folderId
        }
        folderTasks[session.id] = task
        defer { folderTasks.removeValue(forKey: session.id) }
        return try await task.value
    }

    /// Shares the session's folder with anyone who has the link. Best-effort:
    /// a failure (outage, or a Workspace policy that forbids public links)
    /// must never block uploads, so it's logged and retried on the next
    /// `ensureFolder` call instead of thrown.
    private func shareFolder(for session: RecordingSession, authManager: GoogleAuthManager) async {
        if let pending = shareTasks[session.id] { return await pending.value }
        let task = Task { @MainActor in
            guard let folderId = session.driveFolderId else { return }
            do {
                let token = try await authManager.validAccessToken()
                try await GoogleDriveService.shareWithAnyoneWithLink(fileId: folderId, accessToken: token)
                session.driveFolderShared = true
                self.sessionStore?.save()
            } catch DriveError.publicSharingNotAllowed {
                // Retrying can't succeed; stop and leave the folder private.
                self.publicSharingBlocked = true
                session.driveFolderShared = nil
                self.sessionStore?.save()
            } catch {
                print("Failed to share Drive folder: \(error.localizedDescription)")
            }
        }
        shareTasks[session.id] = task
        defer { shareTasks.removeValue(forKey: session.id) }
        await task.value
    }
    
    /// Finds out at sign-in whether this account may share publicly, so the
    /// user is warned before an emergency rather than during one. Drive has no
    /// way to ask, so this shares a throwaway folder and deletes it. A network
    /// failure leaves the previous answer in place.
    func checkPublicSharing(authManager: GoogleAuthManager) async {
        do {
            let token = try await authManager.validAccessToken()
            let probe = try await GoogleDriveService.createFolder(name: "Just sharing check", accessToken: token)
            defer {
                Task { try? await GoogleDriveService.deleteFile(fileId: probe.folderId, accessToken: token) }
            }
            do {
                try await GoogleDriveService.shareWithAnyoneWithLink(fileId: probe.folderId, accessToken: token)
                publicSharingBlocked = false
            } catch DriveError.publicSharingNotAllowed {
                publicSharingBlocked = true
            }
        } catch {
            print("Public sharing check failed: \(error.localizedDescription)")
        }
    }

    /// Clears per-account state when the user signs out.
    func resetAccountState() {
        publicSharingBlocked = false
    }

    /// Creates the session's Drive folder right away (so the alert email can
    /// carry the link), retrying with backoff. Failures are non-fatal — the
    /// first chunk upload will try again.
    func prepareFolder(for session: RecordingSession, authManager: GoogleAuthManager) {
        Task { @MainActor in
            var attempt = 0
            while session.driveFolderId == nil {
                do {
                    _ = try await ensureFolder(for: session, authManager: authManager)
                } catch {
                    attempt += 1
                    if attempt >= RetryPolicy.maxAttempts {
                        print("Failed to create Drive folder after \(attempt) attempts: \(error.localizedDescription)")
                        return
                    }
                    let delay = RetryPolicy.delay(forAttempt: attempt)
                    print("Drive folder attempt \(attempt) failed, retrying in \(Int(delay))s: \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
    }
    
    func enqueue(chunk: VideoChunk, session: RecordingSession, authManager: GoogleAuthManager) {
        uploadTasks[chunk.id]?.cancel()
        chunk.status = .pending
        chunk.uploadProgress = 0
        let task = Task { @MainActor in
            let background = BackgroundActivity(name: "Upload chunk")
            defer { background.end() }
            var attempt = 0
            var quotaAttempt = 0
            while true {
                guard !Task.isCancelled else { return }
                await acquireUploadSlot()
                guard !Task.isCancelled else {
                    releaseUploadSlot()
                    return
                }
                chunk.status = .uploading
                do {
                    let fileId: String
                    do {
                        defer { releaseUploadSlot() }
                        let folderId = try await ensureFolder(for: session, authManager: authManager)
                        let token = try await authManager.validAccessToken()
                        fileId = try await GoogleDriveService.uploadFile(localURL: chunk.localURL, fileName: chunk.fileName, folderId: folderId, accessToken: token) { progress in
                            Task { @MainActor in
                                chunk.uploadProgress = progress
                            }
                        }
                    }
                    
                    chunk.status = .uploaded
                    chunk.driveFileId = fileId
                    storageExceeded = false
                    sessionStore?.save()
                    onChunkUploaded?(chunk)
                    
                    uploadTasks.removeValue(forKey: chunk.id)
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
                        uploadTasks.removeValue(forKey: chunk.id)
                        return
                    }
                    chunk.status = .pending
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
            for chunk in session.chunks where chunk.status != .uploaded && uploadTasks[chunk.id] == nil {
                if FileManager.default.fileExists(atPath: chunk.localURL.path) {
                    enqueue(chunk: chunk, session: session, authManager: authManager)
                } else if chunk.status == .pending || chunk.status == .uploading {
                    chunk.status = .failed
                    changed = true
                }
            }
        }
        if changed { sessionStore?.save() }
    }
    
    /// Rewrites the session's playlist on Drive. Calls for the same session
    /// run one after another so only one playlist file is ever created.
    func updatePlaylist(session: RecordingSession, authManager: GoogleAuthManager) async {
        let previous = playlistTasks[session.id]
        let task = Task { @MainActor in
            await previous?.value
            await self.writePlaylist(session: session, authManager: authManager)
        }
        playlistTasks[session.id] = task
        await task.value
        if playlistTasks[session.id] == task {
            playlistTasks.removeValue(forKey: session.id)
        }
    }
    
    private func writePlaylist(session: RecordingSession, authManager: GoogleAuthManager) async {
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
