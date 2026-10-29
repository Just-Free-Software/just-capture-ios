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
    
    private(set) var quota: DriveStorageQuota?
    private(set) var lastRefreshed: Date?
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
        do {
            let token = try await authManager.validAccessToken()
            quota = try await GoogleDriveService.getStorageQuota(accessToken: token)
            forcedOutOfStorage = false
            lastRefreshed = Date()
        } catch {
            print("Failed to fetch Drive storage quota: \(error.localizedDescription)")
        }
    }
    
    func refreshIfStale(authManager: GoogleAuthManager) async {
        if let last = lastRefreshed, Date().timeIntervalSince(last) < Self.quotaRefreshInterval {
            return
        }
        await refresh(authManager: authManager)
    }
    
    func markOutOfStorage() {
        forcedOutOfStorage = true
    }
    
    static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
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
