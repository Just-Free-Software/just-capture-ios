import SwiftUI

extension UploadStatus {
    var color: Color {
        switch self {
        case .pending: return Theme.warning
        case .uploading: return Theme.accent
        case .uploaded: return Theme.success
        case .failed: return Theme.record
        }
    }
    
    var label: String {
        switch self {
        case .pending: return "Queued"
        case .uploading: return "Uploading"
        case .uploaded: return "Uploaded"
        case .failed: return "Failed"
        }
    }
    
    var icon: String {
        switch self {
        case .pending: return "clock.fill"
        case .uploading: return "arrow.up.circle.fill"
        case .uploaded: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.triangle.fill"
        }
    }
}
