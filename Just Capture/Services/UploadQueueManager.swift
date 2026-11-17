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
    /// Called when clips stop being held by iOS and need the app again, so a
    /// wake-up can be queued if the phone is about to be left alone.
    var onWorkChanged: (() -> Void)?
    /// Runs the actual uploads, so they carry on when the app isn't running.
    var transfers: BackgroundTransfers?
    weak var authManager: GoogleAuthManager?
    /// Clips the app is working on: getting an upload link, or waiting to retry.
    private var uploadTasks: [UUID: Task<Void, Never>] = [:]
    /// Clips iOS is holding. It may still be waiting for a connection.
    private var liveUploads: Set<UUID> = []
    /// Non-nil while asking iOS which uploads it holds.
    private var finishedWhileReconnecting: Set<UUID>?
    /// Clips being deleted, whose cancelled uploads shouldn't be retried.
    private var cancelledUploads: Set<UUID> = []
    /// Sessions with a `prepareFolder` loop running, so repeated calls don't
    /// each start their own.
    private var folderPreparers: Set<String> = []
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
    /// a cap, so clips start uploading soon after someone frees up space.
    static let storageRetryInitialDelay: TimeInterval = 5 * 60
    static let storageRetryMaxDelay: TimeInterval = 15 * 60
    static let storageRetryFactor: Double = 2
    /// Every clip waiting on storage re-checks on its own timer, so they share
    /// one quota request per this interval. A long backlog would otherwise
    /// send a request per clip.
    static let sharedQuotaCheckInterval: TimeInterval = 5 * 60
    private var lastQuotaCheck: (date: Date, availableBytes: Int64?)?
    private var quotaCheckTask: Task<Int64?, Error>?

    static func storageRetryDelay(forQuotaAttempt attempt: Int) -> TimeInterval {
        var delay = storageRetryInitialDelay
        for _ in 1..<max(1, attempt) { delay = min(storageRetryMaxDelay, delay * storageRetryFactor) }
        return delay
    }
    
    /// Free Drive space (nil means unlimited), from a recent check if there is
    /// one. Failed checks aren't remembered, so the caller sees the error.
    @MainActor
    private func sharedAvailableBytes(authManager: GoogleAuthManager) async throws -> Int64? {
        if let last = lastQuotaCheck, Date().timeIntervalSince(last.date) < Self.sharedQuotaCheckInterval {
            return last.availableBytes
        }
        if let quotaCheckTask {
            return try await quotaCheckTask.value
        }
        let task = Task { @MainActor in
            defer { quotaCheckTask = nil }
            let token = try await authManager.validAccessToken()
            let available = try await GoogleDriveService.getStorageQuota(accessToken: token).availableBytes
            lastQuotaCheck = (Date(), available)
            return available
        }
        quotaCheckTask = task
        return try await task.value
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
            if session.driveFolderShared == false {
                await self.shareFolder(for: session, authManager: authManager)
            }
            // After sharing, so a follow-up link works when it's opened.
            self.onFolderCreated?(session)
            return result.folderId
        }
        folderTasks[session.id] = task
        defer { folderTasks.removeValue(forKey: session.id) }
        return try await task.value
    }

    /// Marks the session's folder for link sharing because an email is about to
    /// link to it. Folders stay private until this is called. If the folder
    /// doesn't exist yet, it's shared when `ensureFolder` creates it.
    func requestLinkSharing(for session: RecordingSession, authManager: GoogleAuthManager) {
        guard session.driveFolderShared == nil else { return }
        session.driveFolderShared = false
        sessionStore?.save()
        guard session.driveFolderId != nil else { return }
        Task { @MainActor in
            await shareFolder(for: session, authManager: authManager)
        }
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
        lastQuotaCheck = nil
    }

    /// Creates the session's Drive folder right away (so the alert email can
    /// carry the link), retrying with backoff. Failures are non-fatal — the
    /// first chunk upload will try again.
    func prepareFolder(for session: RecordingSession, authManager: GoogleAuthManager) {
        guard session.driveFolderId == nil, folderPreparers.insert(session.id).inserted else { return }
        Task { @MainActor in
            defer { folderPreparers.remove(session.id) }
            var attempt = 0
            while session.driveFolderId == nil {
                do {
                    _ = try await ensureFolder(for: session, authManager: authManager)
                } catch {
                    if RetryPolicy.isOffline(error) {
                        await NetworkMonitor.shared.waitForRestoredConnection(upTo: RetryPolicy.maxDelay)
                        continue
                    }
                    attempt += 1
                    if attempt >= RetryPolicy.maxAttempts {
                        print("Failed to create Drive folder after \(attempt) attempts: \(error.localizedDescription)")
                        return
                    }
                    let delay = RetryPolicy.delay(forAttempt: attempt)
                    print("Drive folder attempt \(attempt) failed, retrying in \(Int(delay))s: \(error.localizedDescription)")
                    await NetworkMonitor.shared.waitForRestoredConnection(upTo: delay)
                }
            }
        }
    }

    /// Gets a clip to where iOS is uploading it. The app only has to get an
    /// upload link, which needs a connection and a token; once it has one, the
    /// clip no longer depends on the app running. `delay` is backoff owed from
    /// a background upload that failed.
    func enqueue(chunk: VideoChunk, session: RecordingSession, authManager: GoogleAuthManager, after delay: TimeInterval = 0) {
        guard !liveUploads.contains(chunk.id) else { return }
        uploadTasks[chunk.id]?.cancel()
        chunk.status = .pending
        chunk.uploadProgress = 0
        let task = Task { @MainActor in
            let background = BackgroundActivity(name: "Upload chunk")
            defer { background.end() }
            if delay > 0 {
                await NetworkMonitor.shared.waitForRestoredConnection(upTo: delay)
            }
            var quotaAttempt = 0
            while true {
                guard !Task.isCancelled else { return }
                await acquireUploadSlot()
                guard !Task.isCancelled else {
                    releaseUploadSlot()
                    return
                }
                do {
                    let alreadyUploaded: String?
                    do {
                        defer { releaseUploadSlot() }
                        alreadyUploaded = try await handOffToBackgroundSession(chunk: chunk, session: session, authManager: authManager)
                    }
                    guard !Task.isCancelled else { return }
                    uploadTasks.removeValue(forKey: chunk.id)
                    if let alreadyUploaded {
                        await completeUpload(of: chunk, in: session, fileId: alreadyUploaded, authManager: authManager)
                    }
                    return
                } catch {
                    guard !Task.isCancelled else { return }
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
                        print("Chunk \(chunk.index + 1) can't upload: Google Drive storage is full. Re-checking in \(Int(delay / 60)) min.")
                        while true {
                            guard !Task.isCancelled else { return }
                            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                            guard !Task.isCancelled else { return }
                            do {
                                let available = try await sharedAvailableBytes(authManager: authManager)
                                // nil = unlimited quota, always uploadable. Wait
                                // until this clip fits: a clip that can't fit
                                // would only be rejected again.
                                if (available ?? Int64.max) >= max(chunk.fileSize, 1) { break }
                            } catch {
                                // Couldn't read the quota (e.g. offline) — fall
                                // through and let the upload attempt itself
                                // surface whatever the real error is.
                                break
                            }
                        }
                        continue
                    }
                    if RetryPolicy.isOffline(error) {
                        // Doesn't use up a try. The wake-up request gets the
                        // app running again if iOS suspends it during this.
                        chunk.status = .pending
                        chunk.uploadProgress = 0
                        print("Chunk \(chunk.index + 1) is waiting for a connection.")
                        onWorkChanged?()
                        await NetworkMonitor.shared.waitForRestoredConnection(upTo: RetryPolicy.maxDelay)
                        continue
                    }
                    let attempt = recordFailedAttempt(for: chunk)
                    guard attempt < RetryPolicy.maxAttempts else {
                        markFailed(chunk, after: attempt, error: error.localizedDescription)
                        uploadTasks.removeValue(forKey: chunk.id)
                        onWorkChanged?()
                        return
                    }
                    chunk.status = .pending
                    chunk.uploadProgress = 0
                    let delay = RetryPolicy.delay(forAttempt: attempt)
                    print("Upload attempt \(attempt) for chunk \(chunk.index + 1) failed, retrying in \(Int(delay))s: \(error.localizedDescription)")
                    await NetworkMonitor.shared.waitForRestoredConnection(upTo: delay)
                }
            }
        }
        uploadTasks[chunk.id] = task
    }

    /// Starts the background upload, continuing an earlier one if there is one.
    /// Returns the file's id if Drive turns out to have the whole clip already.
    private func handOffToBackgroundSession(chunk: VideoChunk, session: RecordingSession, authManager: GoogleAuthManager) async throws -> String? {
        guard let transfers else { throw URLError(.cannotConnectToHost) }
        let folderId = try await ensureFolder(for: session, authManager: authManager)
        let attributes = try FileManager.default.attributesOfItem(atPath: chunk.localURL.path)
        let fileSize = (attributes[.size] as? Int64) ?? chunk.fileSize

        var offset: Int64 = 0
        if let existing = chunk.uploadSessionURL {
            switch try await GoogleDriveService.resumableUploadState(sessionURL: existing, fileSize: fileSize) {
            case .complete(let fileId):
                return fileId
            case .incomplete(let nextOffset):
                offset = nextOffset
            case .expired:
                chunk.uploadSessionURL = nil
            }
        }
        let sessionURL: URL
        if let existing = chunk.uploadSessionURL {
            sessionURL = existing
        } else {
            let token = try await authManager.validAccessToken()
            sessionURL = try await GoogleDriveService.createUploadSession(fileName: chunk.fileName, fileSize: fileSize, folderId: folderId, accessToken: token)
            chunk.uploadSessionURL = sessionURL
            sessionStore?.save()
        }
        try Task.checkCancellation()

        let fileURL = offset > 0
            ? try Self.writeRemainder(of: chunk, from: offset)
            : chunk.localURL
        transfers.startUpload(chunkId: chunk.id, fileURL: fileURL, sessionURL: sessionURL, offset: offset, fileSize: fileSize)
        liveUploads.insert(chunk.id)
        // Stays "Queued" until bytes actually move, which may be much later.
        chunk.uploadProgress = fileSize > 0 ? Double(offset) / Double(fileSize) : 0
        return nil
    }

    /// Background uploads must come from a file, so continuing partway through
    /// a clip needs a file holding just the part Drive doesn't have.
    private static func writeRemainder(of chunk: VideoChunk, from offset: Int64) throws -> URL {
        let url = remainderURL(for: chunk.id)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let handle = try FileHandle(forReadingFrom: chunk.localURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        let remainder = try handle.readToEnd() ?? Data()
        try remainder.write(to: url, options: .atomic)
        return url
    }

    private static func remainderURL(for chunkId: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("UploadRemainders/\(chunkId.uuidString)")
    }

    private func recordFailedAttempt(for chunk: VideoChunk) -> Int {
        let attempt = (chunk.uploadAttempts ?? 0) + 1
        chunk.uploadAttempts = attempt
        sessionStore?.save()
        return attempt
    }

    private func markFailed(_ chunk: VideoChunk, after attempt: Int, error: String) {
        chunk.status = .failed
        chunk.uploadProgress = 0
        sessionStore?.save()
        print("Chunk \(chunk.index + 1) failed after \(attempt) attempts: \(error)")
    }

    private func completeUpload(of chunk: VideoChunk, in session: RecordingSession, fileId: String, authManager: GoogleAuthManager) async {
        chunk.status = .uploaded
        chunk.driveFileId = fileId
        chunk.uploadProgress = 1
        chunk.uploadSessionURL = nil
        chunk.uploadAttempts = nil
        storageExceeded = false
        sessionStore?.save()
        onChunkUploaded?(chunk)
        await updatePlaylist(session: session, authManager: authManager)
    }

    private func findChunk(id: UUID) -> (chunk: VideoChunk, session: RecordingSession)? {
        for session in sessionStore?.sessions ?? [] {
            if let chunk = session.chunks.first(where: { $0.id == id }) { return (chunk, session) }
        }
        return nil
    }

    func handleUploadProgress(chunkId: UUID, fraction: Double) {
        guard let chunk = findChunk(id: chunkId)?.chunk, chunk.status != .uploaded else { return }
        chunk.status = .uploading
        chunk.uploadProgress = fraction
    }

    /// iOS has finished with a clip. This can arrive long after the upload
    /// began, in a later launch of the app. It can also repeat something the
    /// app already worked out for itself, so a clip marked uploaded is left alone.
    func handleUploadFinished(_ finished: FinishedBackgroundUpload) {
        liveUploads.remove(finished.chunkId)
        finishedWhileReconnecting?.insert(finished.chunkId)
        try? FileManager.default.removeItem(at: Self.remainderURL(for: finished.chunkId))
        if cancelledUploads.remove(finished.chunkId) != nil { return }
        guard let (chunk, session) = findChunk(id: finished.chunkId), chunk.status != .uploaded, let authManager else { return }
        defer { onWorkChanged?() }

        if let status = finished.statusCode, (200...299).contains(status),
           let fileId = GoogleDriveService.uploadedFileId(from: finished.body) {
            Task { await completeUpload(of: chunk, in: session, fileId: fileId, authManager: authManager) }
            return
        }
        // A force-quit cancels uploads. Nothing went wrong with the clip, and
        // the next attempt asks Drive how much of it arrived.
        if finished.wasCancelled {
            enqueue(chunk: chunk, session: session, authManager: authManager)
            return
        }
        if let status = finished.statusCode, (try? GoogleDriveService.throwIfQuotaExceeded(data: finished.body, statusCode: status)) == nil {
            storageExceeded = true
            sessionStore?.save()
            enqueue(chunk: chunk, session: session, authManager: authManager, after: Self.storageRetryInitialDelay)
            return
        }
        // A reply with no connection problem behind it still counts, so a
        // permanent rejection can't turn into a loop of full uploads.
        let reason = finished.error?.localizedDescription ?? "HTTP \(finished.statusCode ?? 0)"
        if finished.statusCode == nil, let error = finished.error, RetryPolicy.isOffline(error) {
            enqueue(chunk: chunk, session: session, authManager: authManager)
            return
        }
        let attempt = recordFailedAttempt(for: chunk)
        guard attempt < RetryPolicy.maxAttempts else {
            markFailed(chunk, after: attempt, error: reason)
            return
        }
        let delay = RetryPolicy.delay(forAttempt: attempt)
        print("Background upload of chunk \(chunk.index + 1) failed, retrying in \(Int(delay))s: \(reason)")
        enqueue(chunk: chunk, session: session, authManager: authManager, after: delay)
    }

    /// Learns which clips iOS kept hold of while the app wasn't running. Must
    /// finish before the first sweep, which would otherwise upload them again.
    func reconnectBackgroundUploads() async {
        guard let transfers else { return }
        finishedWhileReconnecting = []
        let live = await transfers.liveUploadIDs()
        // One may have finished after that list was made. Counting it as live
        // would leave it waiting on an upload that's already over.
        liveUploads.formUnion(live.subtracting(finishedWhileReconnecting ?? []))
        finishedWhileReconnecting = nil
    }

    func retryChunk(_ chunk: VideoChunk, session: RecordingSession, authManager: GoogleAuthManager) {
        chunk.uploadAttempts = nil
        enqueue(chunk: chunk, session: session, authManager: authManager)
    }

    /// Cancels every in-flight upload belonging to a session. Used when the
    /// session is being deleted so a late upload can't resurrect it.
    func cancelUploads(for session: RecordingSession) {
        var live: Set<UUID> = []
        for chunk in session.chunks {
            uploadTasks[chunk.id]?.cancel()
            uploadTasks.removeValue(forKey: chunk.id)
            if liveUploads.remove(chunk.id) != nil { live.insert(chunk.id) }
        }
        guard !live.isEmpty, let transfers else { return }
        cancelledUploads.formUnion(live)
        Task { await transfers.cancelUploads(chunkIds: live) }
    }

    /// Sweeps up every chunk that wasn't confirmed uploaded and that neither the
    /// app nor iOS is working on, so a kill or outage can't strand it. Chunks
    /// whose local file is already gone (e.g. `.uploaded` after a
    /// save-Chunks-locally-off clean-up) are skipped; `.pending`/`.uploading`
    /// chunks with no file are marked `.failed` so the user sees the truth.
    /// `retryFailed` also gives clips that ran out of tries a fresh set, and
    /// retries location files. The caller limits how often that happens.
    func resumePendingUploads(authManager: GoogleAuthManager, retryFailed: Bool) {
        guard let sessions = sessionStore?.sessions else { return }
        var changed = false
        for session in sessions {
            for chunk in session.chunks where chunk.status != .uploaded && uploadTasks[chunk.id] == nil && !liveUploads.contains(chunk.id) {
                if FileManager.default.fileExists(atPath: chunk.localURL.path) {
                    if chunk.status == .failed {
                        guard retryFailed else { continue }
                        chunk.uploadAttempts = nil
                    }
                    enqueue(chunk: chunk, session: session, authManager: authManager)
                } else if chunk.status == .pending || chunk.status == .uploading {
                    chunk.status = .failed
                    changed = true
                }
            }
        }
        if changed { sessionStore?.save() }
        guard retryFailed else { return }
        // Clips may all be up already, leaving nothing else to retry this.
        for session in sessions where session.locationText != session.uploadedLocationText {
            Task { await updateLocationFile(session: session, authManager: authManager) }
        }
    }

    /// The app is working on something right now.
    var hasActiveWork: Bool {
        !uploadTasks.isEmpty || !playlistTasks.isEmpty
    }

    /// Clips that need the app to run before they can upload.
    var hasClipsNeedingApp: Bool {
        (sessionStore?.sessions ?? []).contains { session in
            session.chunks.contains { chunk in
                chunk.status != .uploaded && !liveUploads.contains(chunk.id)
                    && FileManager.default.fileExists(atPath: chunk.localURL.path)
            }
        }
    }

    /// Clips not yet on Drive, including those iOS is holding.
    var hasUnfinishedClips: Bool {
        hasClipsNeedingApp || !liveUploads.isEmpty
    }

    /// Rewrites the session's playlist on Drive. Calls for the same session
    /// run one after another so only one playlist file is ever created.
    /// Also retries the location file, so a failed upload of it is picked up
    /// the next time any clip finishes uploading.
    func updatePlaylist(session: RecordingSession, authManager: GoogleAuthManager) async {
        await runInOrder(for: session) {
            await self.writePlaylist(session: session, authManager: authManager)
            await self.writeLocationFile(session: session, authManager: authManager)
        }
    }

    /// Uploads the session's location as soon as it's known, without waiting
    /// for the first clip, in case the phone is lost before that clip uploads.
    func updateLocationFile(session: RecordingSession, authManager: GoogleAuthManager) async {
        _ = try? await ensureFolder(for: session, authManager: authManager)
        await runInOrder(for: session) {
            await self.writeLocationFile(session: session, authManager: authManager)
        }
    }

    private func runInOrder(for session: RecordingSession, _ work: @escaping @MainActor () async -> Void) async {
        let previous = playlistTasks[session.id]
        let task = Task { @MainActor in
            await previous?.value
            await work()
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
    
    private func writeLocationFile(session: RecordingSession, authManager: GoogleAuthManager) async {
        guard let content = session.locationText,
              content != session.uploadedLocationText,
              let folderId = session.driveFolderId else { return }
        do {
            let token = try await authManager.validAccessToken()
            session.locationFileId = try await GoogleDriveService.uploadOrUpdateTextFile(name: "location.txt", mimeType: "text/plain", content: content, folderId: folderId, existingFileId: session.locationFileId, accessToken: token)
            session.uploadedLocationText = content
            sessionStore?.save()
        } catch {
            print("Failed to upload location: \(error)")
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
