import Foundation
import Observation

/// A folder someone else shared by link, saved for replay on this phone.
struct SharedFolder: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    let addedAt: Date
    var downloadedClipIds: [String]
    /// Clips seen on Drive at the last check.
    var remoteClipIds: [String]
    var lastCheckedAt: Date?

    var newClipCount: Int {
        let downloaded = Set(downloadedClipIds)
        return remoteClipIds.filter { !downloaded.contains($0) }.count
    }
}

/// The Shared tab's list of saved folders, and the check for new clips in
/// them.
///
/// Checking costs one Drive listing request per folder. It only runs when
/// the user opens the tab or pulls to refresh, folders checked recently are
/// skipped, folders are checked one at a time, and the first rate-limit
/// error ends the whole run.
@Observable
class SharedFolderStore {
    private(set) var folders: [SharedFolder] = []
    private(set) var isChecking = false
    private(set) var checkError: String?

    private static var storageURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("shared-folders.json")
    }

    init() {
        load()
    }

    /// Records what a player learned about a folder: adds it the first time
    /// its name resolves, and updates its clip counts after that.
    func update(from downloader: DriveSessionDownloader) {
        guard downloader.source == .publicLink, let name = downloader.folderName else { return }
        let downloaded = downloader.segments.map(\.fileId)
        if let index = folders.firstIndex(where: { $0.id == downloader.folderId }) {
            folders[index].name = name
            folders[index].downloadedClipIds = downloaded
            if let remote = downloader.remoteClipIds {
                folders[index].remoteClipIds = remote
                folders[index].lastCheckedAt = downloader.lastCheckedAt
            }
        } else {
            folders.insert(SharedFolder(
                id: downloader.folderId,
                name: name,
                addedAt: Date(),
                downloadedClipIds: downloaded,
                remoteClipIds: downloader.remoteClipIds ?? [],
                lastCheckedAt: downloader.lastCheckedAt
            ), at: 0)
        }
        save()
    }

    func remove(_ folder: SharedFolder) {
        DriveSessionDownloader.deleteDownloads(folderId: folder.id, source: .publicLink)
        folders.removeAll { $0.id == folder.id }
        save()
    }

    func dismissCheckError() {
        checkError = nil
    }

    /// Lists each saved folder on Drive to see if clips were added. Folders
    /// checked within `minimumInterval` seconds are skipped.
    func checkForNewClips(minimumInterval: TimeInterval) async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        checkError = nil

        let due = folders.filter { folder in
            guard let last = folder.lastCheckedAt else { return true }
            return Date().timeIntervalSince(last) >= minimumInterval
        }
        checking: for folder in due {
            do {
                let files = try await GoogleDriveService.listFiles(inFolder: folder.id, access: .publicLink)
                guard let index = folders.firstIndex(where: { $0.id == folder.id }) else { continue }
                folders[index].remoteClipIds = files.filter { $0.name.hasSuffix(".mp4") }.map(\.id)
                folders[index].lastCheckedAt = Date()
            } catch let error as DriveError {
                checkError = error.localizedDescription
                // These would fail the same way for every other folder.
                switch error {
                case .rateLimited, .apiKeyMissing, .apiKeyRejected: break checking
                default: continue
                }
            } catch {
                // Usually offline; every other folder would fail the same way.
                checkError = error.localizedDescription
                break checking
            }
        }
        save()
    }

    private func save() {
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try FileManager.default.createDirectory(at: Self.storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(folders).write(to: Self.storageURL, options: .atomic)
        } catch {
            print("Failed to save shared folders: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.storageURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            folders = try decoder.decode([SharedFolder].self, from: data)
        } catch {
            print("Failed to load shared folders: \(error)")
        }
    }
}
