import SwiftUI

struct DashboardView: View {
    @Environment(SessionStore.self) private var sessionStore
    @Environment(UploadQueueManager.self) var uploadManager
    @Environment(EmailQueueManager.self) var emailQueueManager
    @Environment(GoogleAuthManager.self) var authManager
    
    @State private var selectedSession: RecordingSession?
    @State private var selectedChunk: VideoChunk?
    @State private var showVideoPlayer = false
    @State private var sessionToDelete: RecordingSession?
    
    private var activeSession: RecordingSession? {
        sessionStore.sessions.first(where: { $0.isActive })
    }
    
    private var displaySession: RecordingSession? {
        selectedSession ?? sessionStore.currentSession
    }
    
    private var jobsForDisplaySession: [EmailJob] {
        guard let id = displaySession?.id else { return [] }
        return emailQueueManager.jobs.filter { $0.sessionId == id }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                if sessionStore.sessions.isEmpty {
                    EmptyStateView()
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            SessionPickerView(
                                sessions: sessionStore.sessions,
                                selectedID: displaySession?.id,
                                onSelect: { session in selectedSession = session }
                            )
                            
                            if let session = displaySession {
                                SessionDetailView(
                                    session: session,
                                    uploadManager: uploadManager,
                                    authManager: authManager,
                                    emailJobs: jobsForDisplaySession,
                                    onRetryEmail: { job in emailQueueManager.retry(job, authManager: authManager) },
                                    onPlayChunk: { chunk in
                                        selectedChunk = chunk
                                        showVideoPlayer = true
                                    },
                                    onRequestDelete: {
                                        sessionToDelete = session
                                    }
                                )
                            }
                        }
                        .padding(.vertical)
                    }
                }
            }
            .navigationTitle("Dashboard")
            .sheet(isPresented: $showVideoPlayer) {
                if let chunk = selectedChunk {
                    VideoPlayerView(chunk: chunk)
                }
            }
            .confirmationDialog(
                "Delete Session?",
                isPresented: Binding(
                    get: { sessionToDelete != nil },
                    set: { if !$0 { sessionToDelete = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    if let session = sessionToDelete {
                        deleteSession(session)
                    }
                    sessionToDelete = nil
                }
                Button("Cancel", role: .cancel) {
                    sessionToDelete = nil
                }
            } message: {
                Text("This removes the session, its locally saved recordings, related email jobs, and cancels any in-progress uploads. Files already uploaded to Google Drive are not affected.")
            }
        }
    }
    
    private func deleteSession(_ session: RecordingSession) {
        uploadManager.cancelUploads(for: session)
        emailQueueManager.removeJobs(forSessionId: session.id)
        sessionStore.delete(session)
        if selectedSession?.id == session.id {
            selectedSession = nil
        }
    }
}

private struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray.fill")
                .font(.system(size: 64))
                .foregroundColor(.gray.opacity(0.5))
            Text("No Sessions Yet")
                .font(.title2.bold())
                .foregroundColor(.white)
            Text("Start recording to see upload status here")
                .font(.subheadline)
                .foregroundColor(.gray)
        }
    }
}

private struct SessionPickerView: View {
    let sessions: [RecordingSession]
    let selectedID: String?
    let onSelect: (RecordingSession) -> Void
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(sessions) { session in
                    SessionChipView(session: session, isSelected: session.id == selectedID)
                        .onTapGesture { onSelect(session) }
                }
            }
            .padding(.horizontal)
        }
    }
}

private struct SessionChipView: View {
    let session: RecordingSession
    let isSelected: Bool
    
    var statusText: String {
        if session.isActive { return "Recording" }
        if session.failedCount > 0 { return "\(session.uploadedCount)/\(session.totalCount)" }
        if session.totalCount == 0 { return "Empty" }
        return "\(session.uploadedCount)/\(session.totalCount)"
    }
    
    var statusColor: Color {
        if session.isActive { return .red }
        if session.failedCount > 0 { return .orange }
        if session.uploadedCount == session.totalCount && session.totalCount > 0 { return .green }
        return .secondary
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(session.startDate.formatted(date: .abbreviated, time: .shortened))
                .font(.caption.bold())
                .foregroundColor(.white)
                .lineLimit(1)
            HStack(spacing: 4) {
                Image(systemName: session.isActive ? "circle.fill" : "video.fill")
                    .font(.system(size: 9))
                Text(statusText)
                    .font(.caption2)
            }
            .foregroundColor(statusColor)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.blue.opacity(0.25) : Color.white.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.blue : Color.white.opacity(0.1), lineWidth: 1)
        )
        .cornerRadius(10)
    }
}

private struct SessionDetailView: View {
    let session: RecordingSession
    let uploadManager: UploadQueueManager
    let authManager: GoogleAuthManager
    let emailJobs: [EmailJob]
    let onRetryEmail: (EmailJob) -> Void
    let onPlayChunk: (VideoChunk) -> Void
    let onRequestDelete: () -> Void
    
    var body: some View {
        VStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Session Info")
                        .font(.headline)
                        .foregroundColor(.white)
                    Spacer()
                    Button(action: onRequestDelete) {
                        Image(systemName: "trash")
                            .font(.body)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
                
                Text(session.startDate.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                HStack {
                    StatView(title: "Total", value: "\(session.totalCount)", color: .blue)
                    Spacer()
                    StatView(title: "Uploaded", value: "\(session.uploadedCount)", color: .green)
                    Spacer()
                    StatView(title: "Failed", value: "\(session.failedCount)", color: .red)
                }
                .padding(.top, 8)
                
                if let link = session.driveFolderLink, let url = URL(string: link) {
                    Link(destination: url) {
                        HStack {
                            Image(systemName: "folder.fill")
                            Text("Open in Drive")
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue.opacity(0.2))
                        .foregroundColor(.blue)
                        .cornerRadius(10)
                    }
                    .padding(.top, 8)
                }
            }
            .padding()
            .background(.ultraThinMaterial)
            .cornerRadius(16)
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
            .padding(.horizontal)
            
            if !emailJobs.isEmpty {
                EmailOutboxCardView(jobs: emailJobs, onRetry: onRetryEmail)
                    .padding(.horizontal)
            }
            
            Divider()
                .background(Color.white.opacity(0.2))
                .padding(.horizontal)
            
            if session.chunks.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "video.slash")
                        .font(.title2)
                        .foregroundColor(.gray)
                    Text("No chunks recorded yet")
                        .font(.subheadline)
                        .foregroundColor(.gray)
                }
                .padding(.vertical, 20)
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(session.chunks) { chunk in
                        StatusCardView(
                            chunk: chunk,
                            onRetry: { uploadManager.retryChunk(chunk, session: session, authManager: authManager) },
                            onPlay: { onPlayChunk(chunk) }
                        )
                        .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                .padding(.horizontal)
                .animation(.spring(), value: session.chunks.count)
            }
        }
    }
}

private struct EmailOutboxCardView: View {
    let jobs: [EmailJob]
    let onRetry: (EmailJob) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Alert Email")
                    .font(.headline)
                    .foregroundColor(.white)
                Spacer()
                Image(systemName: "envelope.fill")
                    .foregroundColor(.blue)
            }
            
            ForEach(jobs) { job in
                EmailJobRow(job: job, onRetry: { onRetry(job) })
            }
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
    }
}

private struct EmailJobRow: View {
    let job: EmailJob
    let onRetry: () -> Void
    
    private var statusText: String {
        switch job.status {
        case .pending:
            if job.attempts == 0 {
                return "Queued"
            } else {
                return "Retrying (attempt \(job.attempts))"
            }
        case .sending: return "Sending…"
        case .sent: return "Sent"
        case .failed: return "Failed after \(job.attempts) attempts"
        }
    }
    
    private var statusColor: Color {
        switch job.status {
        case .pending: return .orange
        case .sending: return .blue
        case .sent: return .green
        case .failed: return .red
        }
    }
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: job.status == .sent ? "checkmark.circle.fill" : "envelope")
                .foregroundColor(statusColor)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(job.recipients.joined(separator: ", "))
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(statusText)
                    .font(.caption)
                    .foregroundColor(statusColor)
            }
            
            Spacer()
            
            if job.status == .failed {
                Button(action: onRetry) {
                    Image(systemName: "arrow.counterclockwise.circle.fill")
                        .font(.title3)
                        .foregroundColor(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct StatView: View {
    let title: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.title3.bold())
                .foregroundColor(color)
        }
    }
}