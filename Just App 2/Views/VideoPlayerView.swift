import SwiftUI
import AVKit

struct VideoPlayerView: View {
    let chunk: VideoChunk
    @Environment(\.dismiss) var dismiss
    
    @State private var player: AVPlayer?
    
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                
                if !fileExists {
                    VStack(spacing: 12) {
                        Image(systemName: "play.slash")
                            .font(.system(size: 48))
                            .foregroundColor(.gray)
                        Text("Local file no longer available")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text("This chunk was deleted after a successful upload.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 32)
                } else if let player = player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea()
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .navigationTitle("Chunk \(chunk.index + 1) (\(chunk.formattedFileSize))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        player?.pause()
                        dismiss()
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.2))
                    .clipShape(Capsule())
                }
            }
            .onAppear {
                guard fileExists else { return }
                let newPlayer = AVPlayer(url: chunk.localURL)
                self.player = newPlayer
                newPlayer.play()
            }
            .onDisappear {
                player?.pause()
            }
        }
    }
    
    private var fileExists: Bool {
        FileManager.default.fileExists(atPath: chunk.localURL.path)
    }
}
