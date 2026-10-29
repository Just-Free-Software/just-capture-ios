import Foundation
import AVFoundation
import Observation

/// Downloads a session folder from Google Drive (the user's own, or one
/// someone shared as "anyone with the link") and turns its
/// `playlist.m3u8` into something AVPlayer can play.
///
/// The playlist's entries point at authenticated Drive URLs and its segments
/// are standalone MP4s rather than real HLS segments, so AVPlayer can't stream
/// it as-is. Instead the clips are downloaded (in playlist order) and stitched
/// into one seekable composition. A manifest saved next to the clips lets them
/// play again later without touching the network.
///
/// Nothing here runs on its own: every Drive request comes from an explicit
/// call, downloads run one at a time, and a failure stops the sync rather
/// than retrying. Clips already on the phone are never fetched again.
@Observable
class DriveSessionDownloader {
    enum Source {
        /// A folder this app uploaded, read as the signed-in user.
        case ownDrive
        /// A folder shared as "anyone with the link", read anonymously with
        /// the app's API key.
        case publicLink
    }

    enum SyncState: Equatable {
        case idle
        case checking
        case downloading(completed: Int, total: Int)
        case preparing
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .checking, .downloading, .preparing: return true
            case .idle, .failed: return false
            }
        }
    }

    struct Segment: Codable, Equatable {
        let fileId: String
        let fileName: String
        let size: Int64?
    }

    private struct Manifest: Codable {
        var folderName: String?
        var segments: [Segment]
    }

    let folderId: String
    let source: Source

    private(set) var sync: SyncState = .idle
    private(set) var downloadedBytes: Int64 = 0
    private(set) var totalBytes: Int64 = 0
    /// What has been downloaded, in playback order.
    private(set) var segments: [Segment] = []
    /// The folder's name on Drive.
    private(set) var folderName: String?
    /// Clips on Drive that aren't on the phone yet, as of the last check.
    private(set) var newClipIds: [String] = []
    /// Every clip on Drive as of the last check, or nil if never checked.
    private(set) var remoteClipIds: [String]?
    private(set) var lastCheckedAt: Date?

    private(set) var playerItem: AVPlayerItem?
    private(set) var duration: TimeInterval = 0
    /// Clips that downloaded but couldn't be read, left out of playback.
    private(set) var skippedClips = 0

    init(folderId: String, source: Source) {
        self.folderId = folderId
        self.source = source
        if let manifest = Self.loadManifest(folderId: folderId, source: source) {
            segments = manifest.segments
            folderName = manifest.folderName
        }
    }

    // MARK: - Storage

    /// Shared folders are kept until the user deletes them. The user's own
    /// sessions already live in their Drive, so those sit in Caches where
    /// iOS may reclaim them.
    static func directoryURL(folderId: String, source: Source) -> URL {
        switch source {
        case .publicLink:
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SharedFolders/\(folderId)/")
        case .ownDrive:
            return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("DriveDownloads/\(folderId)/")
        }
    }

    var directoryURL: URL { Self.directoryURL(folderId: folderId, source: source) }

    private static func manifestURL(folderId: String, source: Source) -> URL {
        directoryURL(folderId: folderId, source: source).appendingPathComponent("manifest.json")
    }

    private static func loadManifest(folderId: String, source: Source) -> Manifest? {
        guard let data = try? Data(contentsOf: manifestURL(folderId: folderId, source: source)) else { return nil }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    static func deleteDownloads(folderId: String, source: Source) {
        try? FileManager.default.removeItem(at: directoryURL(folderId: folderId, source: source))
    }

    private func saveManifest() throws {
        var directory = directoryURL
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Videos can be large and are re-downloadable; keep them out of
        // iCloud backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)

        let data = try JSONEncoder().encode(Manifest(folderName: folderName, segments: segments))
        try data.write(to: Self.manifestURL(folderId: folderId, source: source), options: .atomic)
        try writeLocalPlaylist()
    }

    /// Saves a copy of the playlist next to the clips, pointing at the local
    /// files, so the downloaded folder is self-describing.
    private func writeLocalPlaylist() throws {
        var m3u8 = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-MEDIA-SEQUENCE:0\n"
        for segment in segments {
            m3u8 += "#EXTINF:0,\n\(segment.fileName)\n"
        }
        m3u8 += "#EXT-X-ENDLIST\n"
        try m3u8.write(to: directoryURL.appendingPathComponent("playlist.m3u8"), atomically: true, encoding: .utf8)
    }

    // MARK: - Playback

    /// Builds the player from clips already on the phone. No network.
    func loadSaved() async {
        guard !segments.isEmpty else { return }
        await rebuildPlayer()
    }

    private func rebuildPlayer() async {
        let urls = segments
            .map { directoryURL.appendingPathComponent($0.fileName) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard let composition = try? await makeComposition(from: urls) else { return }
        duration = composition.duration.seconds
        playerItem = AVPlayerItem(asset: composition)
    }

    // MARK: - Syncing with Drive

    /// Fetched fresh per request, since a long download can outlive a token.
    private func access(_ authManager: GoogleAuthManager) async throws -> GoogleDriveService.ReadAccess {
        switch source {
        case .ownDrive: return .user(accessToken: try await authManager.validAccessToken())
        case .publicLink: return .publicLink
        }
    }

    /// One listing request: finds out whether the folder has clips that
    /// aren't on the phone yet. Downloads nothing.
    func checkForNewClips(authManager: GoogleAuthManager) async {
        guard !sync.isBusy else { return }
        sync = .checking
        do {
            try await resolveFolderName(authManager: authManager)
            let files = try await GoogleDriveService.listFiles(inFolder: folderId, access: access(authManager))
            recordRemote(files)
            sync = .idle
        } catch {
            sync = .failed(error.localizedDescription)
        }
    }

    /// Downloads every clip that isn't on the phone yet, then rebuilds the
    /// player to include them.
    func downloadNewClips(authManager: GoogleAuthManager) async {
        guard !sync.isBusy else { return }
        sync = .checking
        do {
            try await resolveFolderName(authManager: authManager)
            let files = try await GoogleDriveService.listFiles(inFolder: folderId, access: access(authManager))
            recordRemote(files)
            let ordered = try await orderedSegments(in: files, access: access(authManager))
            guard !ordered.isEmpty else {
                sync = .failed("This folder has no clips yet.")
                return
            }

            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let missing = ordered.filter { !isAlreadyDownloaded($0) }
            totalBytes = missing.reduce(0) { $0 + ($1.size ?? 0) }
            downloadedBytes = 0

            for (index, segment) in missing.enumerated() {
                try Task.checkCancellation()
                sync = .downloading(completed: index, total: missing.count)
                let destination = directoryURL.appendingPathComponent(segment.fileName)
                // Stops at the first failure: a throttled download is never
                // retried automatically.
                try await GoogleDriveService.downloadFile(fileId: segment.fileId, to: destination, access: access(authManager))
                downloadedBytes += segment.size ?? fileSize(at: destination)
                // Saved per clip, so an interrupted sync keeps what it got.
                segments = ordered.filter { isAlreadyDownloaded($0) }
                try saveManifest()
            }
            segments = ordered.filter { isAlreadyDownloaded($0) }
            try saveManifest()
            newClipIds = []

            sync = .preparing
            await rebuildPlayer()
            sync = .idle
        } catch is CancellationError {
            sync = .idle
        } catch {
            sync = .failed(error.localizedDescription)
        }
        // Whatever finished downloading before a failure is still playable.
        if playerItem == nil && !segments.isEmpty {
            await rebuildPlayer()
        }
    }

    private func resolveFolderName(authManager: GoogleAuthManager) async throws {
        // For shared links this also catches a wrong or private link before
        // anything else is requested.
        guard folderName == nil else { return }
        folderName = try await GoogleDriveService.getFile(fileId: folderId, access: access(authManager)).name
    }

    private func recordRemote(_ files: [DriveFile]) {
        let clipIds = files.filter { $0.name.hasSuffix(".mp4") }.map(\.id)
        let downloaded = Set(segments.map(\.fileId))
        remoteClipIds = clipIds
        newClipIds = clipIds.filter { !downloaded.contains($0) }
        lastCheckedAt = Date()
    }

    /// Clip order comes from `playlist.m3u8` when there is one. Without it
    /// (e.g. the playlist upload failed) the folder's `chunk_N.mp4` files are
    /// sorted by N.
    private func orderedSegments(in files: [DriveFile], access: GoogleDriveService.ReadAccess) async throws -> [Segment] {
        let filesById = Dictionary(files.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byChunkIndex = files
            .filter { $0.name.hasSuffix(".mp4") }
            .sorted { Self.chunkIndex($0.name) < Self.chunkIndex($1.name) }
            .map { Segment(fileId: $0.id, fileName: $0.name, size: $0.byteCount) }

        guard let playlist = files.first(where: { $0.name == "playlist.m3u8" }) else { return byChunkIndex }
        let data = try await GoogleDriveService.downloadData(fileId: playlist.id, access: access)
        let ids = Self.segmentFileIds(inPlaylist: String(decoding: data, as: UTF8.self))
        guard !ids.isEmpty else { return byChunkIndex }

        var ordered = ids.map { id in
            let file = filesById[id]
            return Segment(fileId: id, fileName: file?.name ?? "\(id).mp4", size: file?.byteCount)
        }
        // The playlist is rewritten after each upload, so a clip can be in
        // the folder before the playlist lists it. Don't leave it out.
        let listed = Set(ids)
        ordered += byChunkIndex.filter { !listed.contains($0.fileId) }
        return ordered
    }

    /// Pulls Drive file ids out of the playlist's
    /// `https://www.googleapis.com/drive/v3/files/<id>?alt=media` entries.
    static func segmentFileIds(inPlaylist playlist: String) -> [String] {
        playlist
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .compactMap { line in
                guard let url = URL(string: line) else { return nil }
                let parts = url.pathComponents
                guard let filesIndex = parts.lastIndex(of: "files"), filesIndex + 1 < parts.count else { return nil }
                return parts[filesIndex + 1]
            }
    }

    private static func chunkIndex(_ name: String) -> Int {
        let digits = name.drop(while: { !$0.isNumber }).prefix(while: \.isNumber)
        return Int(digits) ?? .max
    }

    private func isAlreadyDownloaded(_ segment: Segment) -> Bool {
        let url = directoryURL.appendingPathComponent(segment.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        guard let expected = segment.size else { return true }
        return fileSize(at: url) == expected
    }

    private func fileSize(at url: URL) -> Int64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
    }

    private func makeComposition(from urls: [URL]) async throws -> AVComposition {
        skippedClips = 0
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw URLError(.cannotDecodeContentData)
        }

        var cursor = CMTime.zero
        var hasTransform = false
        for url in urls {
            let asset = AVURLAsset(url: url)
            do {
                let duration = try await asset.load(.duration)
                guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first,
                      duration > .zero else {
                    skippedClips += 1
                    continue
                }
                let range = CMTimeRange(start: .zero, duration: duration)
                try videoTrack.insertTimeRange(range, of: sourceVideo, at: cursor)
                if !hasTransform {
                    // Clips are recorded rotated (portrait) and carry the
                    // rotation as a transform the composition doesn't copy.
                    videoTrack.preferredTransform = try await sourceVideo.load(.preferredTransform)
                    hasTransform = true
                }
                // Video is already in, so a bad audio track just means a
                // silent clip rather than shifting everything after it.
                if let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first {
                    try? audioTrack.insertTimeRange(range, of: sourceAudio, at: cursor)
                }
                cursor = cursor + duration
            } catch {
                // A clip cut off mid-upload or mid-recording shouldn't block
                // the rest of the session from playing.
                skippedClips += 1
            }
        }

        guard cursor > .zero else { throw URLError(.cannotDecodeContentData) }
        if audioTrack.segments.isEmpty {
            composition.removeTrack(audioTrack)
        }
        return composition
    }
}
