import SwiftUI

extension UploadStatus {
    var color: Color {
        switch self {
        case .pending: return .orange
        case .uploading: return .blue
        case .uploaded: return .green
        case .failed: return .red
        }
    }
    
    var label: String {
        switch self {
        case .pending: return "Pending"
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
