import SwiftUI
import AVKit

struct VideoPlayerView: View {
    let chunk: VideoChunk
    @Environment(\.dismiss) var dismiss
    
    @State private var player: AVPlayer?
    
    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                
                if !fileExists {
                    ContentUnavailableView(
                        "Clip Not on This Phone",
                        systemImage: "icloud",
                        description: Text("It was removed after uploading. Open the session in Google Drive to watch it.")
                    )
                } else if let player = player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea()
                } else {
                    ProgressView()
                        .tint(.white)
                }
            }
            .navigationTitle("Clip \(chunk.index + 1) · \(Formatters.duration(chunk.duration)) · \(chunk.formattedFileSize)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        player?.pause()
                        dismiss()
                    }
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
