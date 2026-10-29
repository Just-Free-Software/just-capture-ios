import SwiftUI
import AVKit

/// Plays a Drive session folder's clips back to back, in playlist order.
/// Clips already on the phone play straight away; new ones on Drive are
/// fetched on request and appended without restarting playback.
struct DrivePlaybackView: View {
    let title: String

    @Environment(GoogleAuthManager.self) private var authManager
    @Environment(SharedFolderStore.self) private var sharedFolderStore
    @Environment(\.dismiss) private var dismiss

    @State private var downloader: DriveSessionDownloader
    @State private var player = AVPlayer()

    init(folderId: String, source: DriveSessionDownloader.Source, title: String) {
        self.title = title
        _downloader = State(initialValue: DriveSessionDownloader(folderId: folderId, source: source))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                if downloader.playerItem != nil {
                    VStack(spacing: 12) {
                        VideoPlayer(player: player)
                            .ignoresSafeArea(edges: .horizontal)
                        statusCard
                            .padding(.horizontal, 16)
                            .padding(.bottom, 8)
                    }
                } else if case .failed(let message) = downloader.sync {
                    ContentUnavailableView {
                        Label("Couldn't Load From Drive", systemImage: "exclamationmark.icloud")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try Again") {
                            Task { await downloader.downloadNewClips(authManager: authManager) }
                        }
                        .buttonStyle(.glassProminent)
                        .tint(Theme.accent)
                    }
                } else {
                    firstDownloadProgress
                }
            }
            .navigationTitle(downloader.folderName ?? title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        player.pause()
                        dismiss()
                    }
                }
            }
            .task {
                await downloader.loadSaved()
                if downloader.playerItem == nil {
                    await downloader.downloadNewClips(authManager: authManager)
                } else {
                    // One listing request, so the screen can say whether
                    // there's anything new.
                    await downloader.checkForNewClips(authManager: authManager)
                }
            }
            .onChange(of: downloader.playerItem) { _, item in
                guard let item else { return }
                Task { await swapIn(item) }
            }
            .onChange(of: downloader.sync) { _, sync in
                if !sync.isBusy { sharedFolderStore.update(from: downloader) }
            }
            .onDisappear {
                player.pause()
            }
        }
    }

    /// Replaces what's playing with a rebuilt composition while keeping the
    /// viewer's place. If they had watched to the end, it carries on into
    /// the new clips.
    private func swapIn(_ item: AVPlayerItem) async {
        let isFirst = player.currentItem == nil
        let time = player.currentTime()
        let oldDuration = player.currentItem?.duration ?? .zero
        let wasPlaying = player.rate > 0
        let reachedEnd = oldDuration.isNumeric && (oldDuration - time).seconds < 0.5

        player.replaceCurrentItem(with: item)
        if !isFirst {
            await player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if isFirst || wasPlaying || reachedEnd {
            player.play()
        }
    }

    // MARK: - Status

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Saved on this phone", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.success)
                Spacer()
                Text("\(downloader.segments.count) clip\(downloader.segments.count == 1 ? "" : "s") · \(Formatters.duration(downloader.duration))")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .monospacedDigit()
            }

            if downloader.skippedClips > 0 {
                Text("\(downloader.skippedClips) clip\(downloader.skippedClips == 1 ? "" : "s") couldn't be read and \(downloader.skippedClips == 1 ? "was" : "were") skipped.")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }

            syncRow
        }
        .card(padding: 14)
    }

    @ViewBuilder
    private var syncRow: some View {
        switch downloader.sync {
        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Checking Drive for new clips…")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
            }
        case .downloading(let completed, let total):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: byteFraction ?? Double(completed) / Double(max(total, 1)))
                    .tint(Theme.accent)
                Text("Downloading new clip \(completed + 1) of \(total)")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .monospacedDigit()
            }
        case .preparing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Adding new clips…")
                    .font(.subheadline)
                    .foregroundStyle(Theme.secondaryText)
            }
        case .idle, .failed:
            VStack(alignment: .leading, spacing: 10) {
                if case .failed(let message) = downloader.sync {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let checked = downloader.lastCheckedAt, downloader.newClipIds.isEmpty {
                    Text("Up to date · checked \(checked.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                syncButton
            }
        }
    }

    @ViewBuilder
    private var syncButton: some View {
        let newCount = downloader.newClipIds.count
        if newCount > 0 {
            Button {
                Task { await downloader.downloadNewClips(authManager: authManager) }
            } label: {
                Text("Get \(newCount) New Clip\(newCount == 1 ? "" : "s")")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glassProminent)
            .tint(Theme.accent)
            .controlSize(.large)
            .font(.subheadline.weight(.semibold))
        } else {
            Button {
                Task { await downloader.checkForNewClips(authManager: authManager) }
            } label: {
                Text("Check for New Clips")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .font(.subheadline.weight(.semibold))
        }
    }

    private var byteFraction: Double? {
        guard downloader.totalBytes > 0 else { return nil }
        return Double(downloader.downloadedBytes) / Double(downloader.totalBytes)
    }

    private var firstDownloadProgress: some View {
        VStack(spacing: 14) {
            switch downloader.sync {
            case .downloading(let completed, let total):
                ProgressView(value: byteFraction ?? Double(completed) / Double(max(total, 1)))
                    .tint(Theme.accent)
                Text("Downloading clip \(completed + 1) of \(total)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                if downloader.totalBytes > 0 {
                    Text("\(Formatters.bytes(downloader.downloadedBytes)) of \(Formatters.bytes(downloader.totalBytes))")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                        .monospacedDigit()
                }
            default:
                ProgressView()
                    .tint(.white)
                Text(downloader.sync == .preparing ? "Preparing playback…" : "Finding clips…")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
            }
        }
        .card()
        .padding(32)
    }
}

/// Session folders this app has uploaded to the user's own Google Drive,
/// including ones that are no longer (or never were) on this phone.
struct DriveSessionsView: View {
    @Environment(GoogleAuthManager.self) private var authManager
    @Environment(\.dismiss) private var dismiss

    @State private var folders: [DriveFile] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var playingFolder: DriveFile?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && folders.isEmpty {
                    ProgressView().tint(.white)
                } else if let errorMessage, folders.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn't Reach Drive", systemImage: "exclamationmark.icloud")
                    } description: {
                        Text(errorMessage)
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                            .buttonStyle(.glassProminent)
                            .tint(Theme.accent)
                    }
                } else if folders.isEmpty {
                    ContentUnavailableView(
                        "No Sessions in Drive",
                        systemImage: "folder",
                        description: Text("Sessions this app uploads appear here.")
                    )
                } else {
                    List(folders) { folder in
                        Button {
                            playingFolder = folder
                        } label: {
                            DriveFolderRow(
                                title: displayName(for: folder),
                                subtitle: folder.name,
                                newClipCount: 0
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable { await load() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("Your Sessions in Drive")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
            .sheet(item: $playingFolder) { folder in
                DrivePlaybackView(folderId: folder.id, source: .ownDrive, title: displayName(for: folder))
            }
        }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let token = try await authManager.validAccessToken()
            folders = try await GoogleDriveService.listSessionFolders(accessToken: token)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func displayName(for folder: DriveFile) -> String {
        if let date = folder.createdTime {
            return date.formatted(date: .abbreviated, time: .shortened)
        }
        return folder.name
    }
}

/// List row for a Drive folder, with a badge when it has clips the phone
/// doesn't.
struct DriveFolderRow: View {
    let title: String
    let subtitle: String
    let newClipCount: Int

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.fill")
                .font(.headline)
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if newClipCount > 0 {
                StatusBadge(text: "\(newClipCount) new", systemImage: "arrow.down.circle.fill", color: Theme.accent)
                    .fixedSize()
            } else {
                Image(systemName: "play.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.accent)
            }
        }
        .card(padding: 12)
    }
}
