import Foundation

/// Free space on this phone. Clips are always kept locally after upload, so
/// the phone filling up would stop new clips from being written.
enum DeviceStorage {
    /// Warn when less than this much recording time fits on the phone...
    static let lowRecordingSecondsThreshold: TimeInterval = 30 * 60
    /// ...or when less than this many bytes are free, whichever is larger.
    static let lowBytesThreshold: Int64 = 1024 * 1024 * 1024

    /// Space available for user-initiated saves like recordings. A local
    /// filesystem query, so it's cheap to call repeatedly.
    static func availableBytes() -> Int64? {
        let values = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
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
