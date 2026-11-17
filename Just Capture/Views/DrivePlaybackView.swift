import SwiftUI
import AVKit
import MapKit

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
    @State private var didLoad = false

    /// `localClips` are the session's clips recorded on this phone, which
    /// play from where they are instead of being downloaded back.
    init(
        folderId: String,
        source: DriveSessionDownloader.Source,
        title: String,
        localClips: [DriveSessionDownloader.LocalClip] = [],
        locationText: String? = nil
    ) {
        self.title = title
        _downloader = State(initialValue: DriveSessionDownloader(folderId: folderId, source: source, localClips: localClips, locationText: locationText))
    }

    private var locationInfo: SessionLocationInfo? {
        downloader.locationText.flatMap(SessionLocationInfo.init(text:))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                if downloader.playerItem != nil, let info = locationInfo {
                    // With location details the player takes the top of the
                    // screen and the rest scrolls; full screen is one tap away.
                    VStack(spacing: 0) {
                        FullScreenCapablePlayer(player: player)
                            .ignoresSafeArea(edges: .horizontal)
                            .containerRelativeFrame(.vertical) { height, _ in height * 0.5 }
                        ScrollView {
                            VStack(spacing: 12) {
                                statusCard
                                SessionLocationCard(info: info)
                            }
                            .padding(16)
                        }
                    }
                } else if downloader.playerItem != nil {
                    VStack(spacing: 12) {
                        FullScreenCapablePlayer(player: player)
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
                // Full screen covers this view and uncovers it again, which
                // would otherwise rerun this and rebuild what's playing.
                guard !didLoad else { return }
                didLoad = true
                await downloader.loadSaved()
                if downloader.playerItem == nil {
                    await downloader.downloadNewClips(authManager: authManager)
                } else if !downloader.hasAllClipsLocally {
                    // One listing request, so the screen can say whether
                    // there's anything new. Skipped when this phone recorded
                    // the session and still has every clip.
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

            // Only after a check, so it isn't claimed before Drive was asked.
            if downloader.locationText == nil, downloader.lastCheckedAt != nil {
                Label("No location was saved with this recording.", systemImage: "location.slash")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
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

/// Where a session was recorded: when it started, a map of the route, and
/// the position saved at the end of each clip.
private struct SessionLocationCard: View {
    let info: SessionLocationInfo

    /// Long recordings have hundreds of points; show the first few until asked.
    @State private var showsAllPoints = false
    private static let collapsedPointCount = 5

    private var visiblePoints: [SessionLocationInfo.Point] {
        showsAllPoints ? info.points : Array(info.points.prefix(Self.collapsedPointCount))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Location", systemImage: "mappin.and.ellipse")
                .font(.headline)
                .foregroundStyle(.white)

            VStack(alignment: .leading, spacing: 4) {
                if let address = info.startingAddress {
                    Text(address)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                }
                if let started = info.started {
                    Text("Started \(started)")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
            }

            let route = info.route
            if let first = route.first {
                Map {
                    if route.count > 1 {
                        MapPolyline(coordinates: route)
                            .stroke(Theme.accent, lineWidth: 4)
                    }
                    Marker("Start", coordinate: first)
                        .tint(Theme.success)
                    if route.count > 1, let last = route.last {
                        Marker("Latest", coordinate: last)
                            .tint(Theme.record)
                    }
                }
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel("Map of the recording's route")
            }

            if !info.points.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(visiblePoints) { point in
                        LocationPointRow(point: point)
                    }
                }
                if info.points.count > Self.collapsedPointCount {
                    Button(showsAllPoints ? "Show Fewer" : "Show All \(info.points.count) Locations") {
                        withAnimation(.snappy) { showsAllPoints.toggle() }
                    }
                    .font(.subheadline.weight(.semibold))
                    .tint(Theme.accent)
                }
            }
        }
        .card(padding: 14)
    }
}

/// One saved position. Opens in Maps when it has coordinates.
private struct LocationPointRow: View {
    let point: SessionLocationInfo.Point

    private var detail: String {
        // The date is in the card's header; a row only needs the time.
        let time = point.time.components(separatedBy: " at ").last ?? point.time
        guard point.coordinate != nil else { return "\(time) · no location available" }
        return ([time] + [point.isLastKnown ? "last known position" : nil, point.accuracy].compactMap { $0 }).joined(separator: " · ")
    }

    var body: some View {
        if let url = point.mapURL {
            Link(destination: url) { content(opensMap: true) }
        } else {
            content(opensMap: false)
        }
    }

    private func content(opensMap: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(point.label)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(opensMap ? Theme.secondaryText : Theme.warning)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 8)
            if opensMap {
                Image(systemName: "arrow.up.right.square")
                    .foregroundStyle(Theme.accent)
            }
        }
        .contentShape(.rect)
    }
}

/// The system player, used instead of SwiftUI's `VideoPlayer` so the app
/// controls what happens around full screen. Going full screen covers the
/// SwiftUI screen underneath, which SwiftUI reports as that screen
/// disappearing, so playback is stopped here, when the player itself is
/// torn down, rather than in `onDisappear`.
struct FullScreenCapablePlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        controller.delegate = context.coordinator
        controller.view.backgroundColor = .clear
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player {
            controller.player = player
        }
    }

    static func dismantleUIViewController(_ controller: AVPlayerViewController, coordinator: Coordinator) {
        controller.player?.pause()
    }

    final class Coordinator: NSObject, AVPlayerViewControllerDelegate {
        func playerViewController(
            _ playerViewController: AVPlayerViewController,
            willEndFullScreenPresentationWithAnimationCoordinator coordinator: any UIViewControllerTransitionCoordinator
        ) {
            // The system pauses when full screen is closed; carry on playing
            // if the video was playing.
            let wasPlaying = (playerViewController.player?.rate ?? 0) > 0
            coordinator.animate(alongsideTransition: nil) { context in
                if !context.isCancelled && wasPlaying { playerViewController.player?.play() }
            }
        }
    }
}

/// List row for a Drive folder, with a badge when it has clips the phone
/// doesn't.
struct DriveFolderRow: View {
    let title: String
    let subtitle: String
    let newClipCount: Int
    /// When set, the row ends with a "more" menu offering to delete the folder.
    var onDelete: (() -> Void)? = nil

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
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
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
            if let onDelete {
                Menu {
                    Button("Delete from This Phone", systemImage: "trash", role: .destructive, action: onDelete)
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.secondaryText)
                        .frame(width: 32, height: 44)
                        .contentShape(.rect)
                }
                .accessibilityLabel("More")
            }
        }
        .card(padding: 12)
    }
}
