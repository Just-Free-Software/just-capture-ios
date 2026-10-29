import SwiftUI
import AVFoundation

/// Grid tile for one recorded clip: a frame from the video with its index,
/// length and upload state on top.
struct ChunkTileView: View {
    let chunk: VideoChunk
    var onPlay: () -> Void
    var onRetry: () -> Void
    
    private var localFileExists: Bool {
        FileManager.default.fileExists(atPath: chunk.localURL.path)
    }
    
    var body: some View {
        Button(action: onPlay) {
            ChunkThumbnail(url: chunk.localURL)
                .aspectRatio(9 / 16, contentMode: .fit)
                .overlay {
                    LinearGradient(colors: [.black.opacity(0.5), .clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                }
                .overlay(alignment: .topLeading) {
                    Text("\(chunk.index + 1)")
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(8)
                }
                .overlay(alignment: .topTrailing) {
                    Image(systemName: chunk.status.icon)
                        .font(.caption)
                        .foregroundStyle(chunk.status.color)
                        .padding(6)
                        .background(.black.opacity(0.4), in: Circle())
                        .padding(4)
                }
                .overlay(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(Formatters.duration(chunk.duration))
                            Spacer()
                            if !localFileExists {
                                Image(systemName: "icloud")
                            }
                        }
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        if chunk.status == .uploading {
                            ProgressView(value: chunk.uploadProgress)
                                .tint(chunk.status.color)
                        }
                    }
                    .padding(8)
                }
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(chunk.status == .failed ? Theme.record.opacity(0.7) : Theme.stroke, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(!localFileExists)
        .contextMenu {
            if localFileExists {
                Button("Play", systemImage: "play.fill", action: onPlay)
            }
            if chunk.status == .failed {
                Button("Retry Upload", systemImage: "arrow.clockwise", action: onRetry)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Clip \(chunk.index + 1), \(Formatters.duration(chunk.duration)), \(chunk.status.label)")
        .accessibilityAddTraits(.isButton)
        .accessibilityActions {
            if chunk.status == .failed {
                Button("Retry Upload", action: onRetry)
            }
        }
    }
}

/// Loads (and caches) a still frame from a local clip.
struct ChunkThumbnail: View {
    let url: URL
    @State private var image: UIImage?
    
    private static let cache = NSCache<NSURL, UIImage>()
    
    var body: some View {
        Rectangle()
            .fill(Theme.surfaceRaised)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .transition(.opacity)
                } else {
                    Image(systemName: "video.fill")
                        .foregroundStyle(Theme.tertiaryText)
                }
            }
            .clipped()
            .task(id: url) {
                if let cached = Self.cache.object(forKey: url as NSURL) {
                    image = cached
                    return
                }
                guard let generated = await Self.generate(url: url) else { return }
                Self.cache.setObject(generated, forKey: url as NSURL)
                withAnimation(.easeOut(duration: 0.2)) { image = generated }
            }
    }
    
    private static func generate(url: URL) async -> UIImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        guard let result = try? await generator.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)) else { return nil }
        return UIImage(cgImage: result.image)
    }
}
