import Foundation
import Observation

@Observable
@MainActor
final class DriveStorageManager {
    enum StorageState {
        case ok
        case low
        case out
        case unlimited
        case unavailable
    }
    
    static let lowStorageThresholdBytes: Int64 = 250 * 1024 * 1024
    static let quotaRefreshInterval: TimeInterval = 60
    /// Drive can take a minute or two to count newly uploaded files in the
    /// quota. Within this long of our last upload, a server figure lower than
    /// our own running total is treated as stale.
    static let quotaLagWindow: TimeInterval = 120
    
    private(set) var quota: DriveStorageQuota?
    /// Set on every attempt, successful or not, so a failing quota request
    /// is still throttled to once per `quotaRefreshInterval`.
    private var lastRefreshAttempt: Date?
    private var isRefreshing = false
    private var lastLocalUpload: Date?
    private(set) var forcedOutOfStorage = false
    weak var sessionStore: SessionStore?
    
    var state: StorageState {
        if forcedOutOfStorage { return .out }
        guard let quota else { return .unavailable }
        guard let available = quota.availableBytes else { return .unlimited }
        if available <= 0 { return .out }
        if available < Self.lowStorageThresholdBytes { return .low }
        return .ok
    }
    
    var availableBytes: Int64? {
        quota?.availableBytes
    }
    
    var bytesPerSecondEstimate: Double {
        var totalBytes: Double = 0
        var totalSeconds: Double = 0
        for session in sessionStore?.sessions ?? [] {
            for chunk in session.chunks where chunk.duration > 0 && chunk.fileSize > 0 {
                totalBytes += Double(chunk.fileSize)
                totalSeconds += chunk.duration
            }
        }
        if totalSeconds > 0 {
            return totalBytes / totalSeconds
        }
        return AppConfig.estimatedVideoBytesPerSecond
    }
    
    var estimatedRecordingSeconds: TimeInterval? {
        guard let available = availableBytes, available > 0 else { return nil }
        return TimeInterval(available) / bytesPerSecondEstimate
    }
    
    func refresh(authManager: GoogleAuthManager) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        lastRefreshAttempt = Date()
        do {
            let token = try await authManager.validAccessToken()
            let server = try await GoogleDriveService.getStorageQuota(accessToken: token)
            if let local = quota, let lastUpload = lastLocalUpload,
               Date().timeIntervalSince(lastUpload) < Self.quotaLagWindow,
               local.limit == server.limit, local.usage > server.usage {
                // Drive hasn't counted our latest uploads yet; don't let the
                // free space jump back up.
                quota = DriveStorageQuota(limit: server.limit, usage: local.usage)
            } else {
                quota = server
            }
            forcedOutOfStorage = false
        } catch {
            print("Failed to fetch Drive storage quota: \(error.localizedDescription)")
        }
    }
    
    func refreshIfStale(authManager: GoogleAuthManager) async {
        if let last = lastRefreshAttempt, Date().timeIntervalSince(last) < Self.quotaRefreshInterval {
            return
        }
        await refresh(authManager: authManager)
    }
    
    /// Counts a finished upload against the quota right away, rather than
    /// waiting for the next refresh, then re-checks with Drive if the last
    /// check is more than a minute old.
    func recordUpload(bytes: Int64, authManager: GoogleAuthManager) {
        forcedOutOfStorage = false
        if let quota {
            self.quota = DriveStorageQuota(limit: quota.limit, usage: quota.usage + bytes)
        }
        lastLocalUpload = Date()
        Task { await refreshIfStale(authManager: authManager) }
    }
    
    func markOutOfStorage() {
        forcedOutOfStorage = true
    }
    
    /// Binary units, as Google uses: a free account's "15 GB" is 15 GiB, which
    /// decimal formatting would show as 16.1 GB.
    static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .binary)
    }
    
    static func formatRecordingTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours) hr \(minutes) min" }
        if minutes > 0 { return "\(minutes) min" }
        return "less than a minute"
    }
}
