import Foundation

/// Free space on this phone. Clips are always kept locally after upload, so
/// the phone filling up would stop new clips from being written.
enum DeviceStorage {
    /// Warn when less than this much recording time fits on the phone...
    static let lowRecordingSecondsThreshold: TimeInterval = 30 * 60
    /// ...or when less than this many bytes are free, whichever is larger.
    static let lowBytesThreshold: Int64 = 1024 * 1024 * 1024

    /// Space available for user-initiated saves like recordings. No network
    /// is involved, but the system works out how much purgeable data it could
    /// clear to answer, and that can take a while, so the query runs off the
    /// main thread.
    nonisolated static func availableBytes() async -> Int64? {
        await Task.detached(priority: .userInitiated) {
            let values = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            return values?.volumeAvailableCapacityForImportantUsage
        }.value
    }

    static func isLow(availableBytes: Int64, bytesPerSecond: Double) -> Bool {
        let threshold = max(lowBytesThreshold, Int64(lowRecordingSecondsThreshold * bytesPerSecond))
        return availableBytes < threshold
    }

    static func recordingSeconds(availableBytes: Int64, bytesPerSecond: Double) -> TimeInterval {
        guard bytesPerSecond > 0 else { return 0 }
        return TimeInterval(max(availableBytes, 0)) / bytesPerSecond
    }
}
