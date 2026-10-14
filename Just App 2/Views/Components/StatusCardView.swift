import SwiftUI

struct StatusCardView: View {
    @Bindable var chunk: VideoChunk
    var onRetry: () -> Void
    var onPlay: () -> Void
    
    private var localFileExists: Bool {
        FileManager.default.fileExists(atPath: chunk.localURL.path)
    }
    
    var body: some View {
        HStack(spacing: 16) {
            // Left
            Circle()
                .fill(chunk.status.color.opacity(0.2))
                .frame(width: 40, height: 40)
                .overlay(
                    Text("\(chunk.index + 1)")
                        .font(.headline)
                        .foregroundColor(chunk.status.color)
                )
            
            // Middle
            VStack(alignment: .leading, spacing: 4) {
                Text("Chunk \(chunk.index + 1)")
                    .font(.headline)
                    .foregroundColor(.white)
                
                Text("\(chunk.formattedFileSize) • \(String(format: "%.1fs", chunk.duration))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                
                if chunk.status == .uploading {
                    ProgressView(value: chunk.uploadProgress)
                        .progressViewStyle(.linear)
                        .tint(chunk.status.color)
                }
            }
            
            Spacer()
            
            // Right
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: chunk.status.icon)
                    Text(chunk.status.label)
                        .font(.caption.bold())
                }
                .foregroundColor(chunk.status.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(chunk.status.color.opacity(0.1))
                .clipShape(Capsule())
                
                HStack(spacing: 12) {
                    if chunk.status == .failed {
                        Button(action: onRetry) {
                            Image(systemName: "arrow.counterclockwise.circle.fill")
                                .font(.title3)
                                .foregroundColor(.orange)
                        }
                    }
                    
                    Button(action: onPlay) {
                        Image(systemName: localFileExists ? "play.circle.fill" : "play.slash.circle.fill")
                            .font(.title3)
                            .foregroundColor(localFileExists ? .blue : .gray)
                    }
                    .disabled(!localFileExists)
                }
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .cornerRadius(16)
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.1), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.2), radius: 5, x: 0, y: 2)
    }
}
