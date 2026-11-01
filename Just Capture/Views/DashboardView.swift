import SwiftUI

struct DashboardView: View {
    @Environment(SessionStore.self) private var sessionStore
    @Environment(UploadQueueManager.self) private var uploadManager
    @Environment(EmailQueueManager.self) private var emailQueueManager

    @State private var sessionToDelete: RecordingSession?

    private var totalDuration: TimeInterval {
        sessionStore.sessions.reduce(0) { $0 + $1.totalDuration }
    }

    private var totalQueued: Int {
        sessionStore.sessions.reduce(0) { $0 + $1.queuedCount }
    }

    private var totalFailed: Int {
        sessionStore.sessions.reduce(0) { $0 + $1.failedCount }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sessionStore.sessions.isEmpty {
                    ContentUnavailableView(
                        "No Recordings Yet",
                        systemImage: "video.badge.waveform",
                        description: Text("Sessions you record show up here, with their upload and alert status.")
                    )
                } else {
                    List {
                        summary
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)

                        Section {
                            ForEach(sessionStore.sessions) { session in
                                NavigationLink(value: session.id) {
                                    SessionRow(session: session)
                                }
                                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .swipeActions(edge: .trailing) {
                                    if !session.isActive {
                                        Button("Delete", systemImage: "trash") {
                                            sessionToDelete = session
                                        }
                                        .tint(Theme.record)
                                    }
                                }
                            }
                        } header: {
                            Text("Sessions")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.secondaryText)
                                .textCase(nil)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(Theme.background.ignoresSafeArea())
            .navigationTitle("My Clips")
            .navigationDestination(for: String.self) { id in
                if let session = sessionStore.sessions.first(where: { $0.id == id }) {
                    SessionDetailView(session: session)
                } else {
                    ContentUnavailableView("Session Deleted", systemImage: "trash")
                }
            }
            .deleteSessionDialog(session: $sessionToDelete)
        }
    }

    private var summary: some View {
        HStack(spacing: 12) {
            StatView(title: "Recorded", value: Formatters.duration(totalDuration), color: .white)
            StatView(title: "Uploading", value: "\(totalQueued)", color: totalQueued > 0 ? Theme.accent : Theme.secondaryText)
            StatView(title: "Failed", value: "\(totalFailed)", color: totalFailed > 0 ? Theme.warning : Theme.secondaryText)
        }
        .card()
    }
}

// MARK: - Session row

private struct SessionRow: View {
    let session: RecordingSession

    var body: some View {
        let status = session.statusSummary
        HStack(spacing: 14) {
            Image(systemName: session.isActive ? "record.circle.fill" : "video.fill")
                .font(.headline)
                .foregroundStyle(status.color)
                .frame(width: 44, height: 44)
                .background(status.color.opacity(0.15), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text("\(session.startDate.formatted(.dateTime.month(.abbreviated).day())), \(session.startDate.formatted(date: .omitted, time: .shortened))")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .foregroundStyle(.white)
                Text(detailText)
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .monospacedDigit()
                if session.totalCount > 0 && session.uploadedCount < session.totalCount {
                    ProgressView(value: session.uploadFraction)
                        .tint(status.color)
                        .padding(.top, 2)
                }
            }

            Spacer(minLength: 8)
            StatusBadge(text: status.text, systemImage: status.icon, color: status.color)
                .fixedSize()
        }
        .card(padding: 12)
    }

    private var detailText: String {
        let clips = "\(session.totalCount) clip\(session.totalCount == 1 ? "" : "s")"
        return [Formatters.duration(session.totalDuration), clips, Formatters.bytes(session.totalBytes)].joined(separator: " · ")
    }
}

// MARK: - Session detail

struct SessionDetailView: View {
    let session: RecordingSession

    @Environment(UploadQueueManager.self) private var uploadManager
    @Environment(EmailQueueManager.self) private var emailQueueManager
    @Environment(GoogleAuthManager.self) private var authManager
    @Environment(\.dismiss) private var dismiss

    @State private var playingChunk: VideoChunk?
    @State private var playingFromDrive = false
    @State private var sessionToDelete: RecordingSession?

    private var emailJobs: [EmailJob] {
        emailQueueManager.jobs.filter { $0.sessionId == session.id }
    }

    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing) {
                overviewCard

                if !emailJobs.isEmpty {
                    EmailOutboxCard(jobs: emailJobs) { job in
                        emailQueueManager.retry(job, authManager: authManager)
                    }
                }

                Text("Clips")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.top, 4)

                if session.chunks.isEmpty {
                    Text(session.isActive ? "The first clip will appear here in a few seconds." : "No clips were recorded.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.secondaryText)
                        .card()
                } else {
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(session.chunks) { chunk in
                            ChunkTileView(
                                chunk: chunk,
                                onPlay: { playingChunk = chunk },
                                onRetry: { uploadManager.retryChunk(chunk, session: session, authManager: authManager) }
                            )
                        }
                    }
                    .animation(.snappy, value: session.chunks.count)
                }
            }
            .padding(16)
        }
        .background(Theme.background.ignoresSafeArea())
        .navigationTitle(session.startDate.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !session.isActive {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Delete Session", systemImage: "trash", role: .destructive) {
                            sessionToDelete = session
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .sheet(item: $playingChunk) { chunk in
            VideoPlayerView(chunk: chunk)
        }
        .sheet(isPresented: $playingFromDrive) {
            if let folderId = session.driveFolderId {
                DrivePlaybackView(folderId: folderId, source: .ownDrive, title: session.startDate.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .deleteSessionDialog(session: $sessionToDelete, onDeleted: { dismiss() })
    }

    private var overviewCard: some View {
        let status = session.statusSummary
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Formatters.duration(session.totalDuration))
                        .font(.largeTitle.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                    Text("\(Formatters.bytes(session.totalBytes)) · \(Int(session.chunkDuration))s clips")
                        .font(.caption)
                        .foregroundStyle(Theme.secondaryText)
                }
                Spacer()
                StatusBadge(text: status.text, systemImage: status.icon, color: status.color)
            }

            HStack {
                StatView(title: "Uploaded", value: "\(session.uploadedCount)", color: Theme.success)
                StatView(title: "Queued", value: "\(session.queuedCount)", color: session.queuedCount > 0 ? Theme.accent : Theme.secondaryText)
                StatView(title: "Failed", value: "\(session.failedCount)", color: session.failedCount > 0 ? Theme.record : Theme.secondaryText)
            }

            if session.totalCount > 0 {
                ProgressView(value: session.uploadFraction)
                    .tint(status.color)
            }

            HStack(spacing: 10) {
                if let link = session.driveFolderLink, let url = URL(string: link) {
                    Link(destination: url) {
                        Label("Drive", systemImage: "folder.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                }
                if session.driveFolderId != nil && session.uploadedCount > 0 {
                    Button {
                        playingFromDrive = true
                    } label: {
                        Label("Play", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .tint(Theme.accent)
                }
                if session.failedCount > 0 {
                    Button {
                        for chunk in session.chunks where chunk.status == .failed {
                            uploadManager.retryChunk(chunk, session: session, authManager: authManager)
                        }
                    } label: {
                        Label("Retry \(session.failedCount)", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glass)
                    .tint(Theme.warning)
                }
            }
            .font(.subheadline.weight(.semibold))
            .lineLimit(1)
            .controlSize(.large)
        }
        .card()
    }
}

// MARK: - Email outbox

private struct EmailOutboxCard: View {
    let jobs: [EmailJob]
    let onRetry: (EmailJob) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Alert emails", systemImage: "envelope.fill")
                .font(.headline)
                .foregroundStyle(.white)
            ForEach(jobs) { job in
                EmailJobRow(job: job, onRetry: { onRetry(job) })
            }
        }
        .card()
    }
}

private struct EmailJobRow: View {
    let job: EmailJob
    let onRetry: () -> Void

    private var status: (text: String, icon: String, color: Color) {
        switch job.status {
        case .pending:
            return job.attempts == 0
                ? ("Queued", "clock.fill", Theme.warning)
                : ("Retrying · attempt \(job.attempts)", "clock.arrow.circlepath", Theme.warning)
        case .sending: return ("Sending…", "paperplane.fill", Theme.accent)
        case .sent: return ("Sent \(job.lastAttemptAt?.formatted(date: .omitted, time: .shortened) ?? "")", "checkmark.circle.fill", Theme.success)
        case .failed: return ("Failed after \(job.attempts) attempts", "exclamationmark.triangle.fill", Theme.record)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: status.icon)
                .foregroundStyle(status.color)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.subject)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text("\(status.text) · \(job.recipients.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if job.status == .failed {
                Button("Retry", action: onRetry)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.glass)
                    .tint(Theme.warning)
            }
        }
    }
}

// MARK: - Delete

private struct DeleteSessionDialog: ViewModifier {
    @Binding var session: RecordingSession?
    var onDeleted: (() -> Void)?

    @Environment(SessionStore.self) private var sessionStore
    @Environment(UploadQueueManager.self) private var uploadManager
    @Environment(EmailQueueManager.self) private var emailQueueManager

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Delete this session?",
            isPresented: Binding(get: { session != nil }, set: { if !$0 { session = nil } }),
            titleVisibility: .visible,
            presenting: session
        ) { session in
            Button("Delete Session", role: .destructive) {
                uploadManager.cancelUploads(for: session)
                emailQueueManager.removeJobs(forSessionId: session.id)
                sessionStore.delete(session)
                self.session = nil
                onDeleted?()
            }
        } message: { _ in
            Text("Removes the clips saved on this phone and stops any pending uploads or emails. Clips already in Google Drive are kept.")
        }
    }
}

private extension View {
    func deleteSessionDialog(session: Binding<RecordingSession?>, onDeleted: (() -> Void)? = nil) -> some View {
        modifier(DeleteSessionDialog(session: session, onDeleted: onDeleted))
    }
}
