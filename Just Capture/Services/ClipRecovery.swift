@preconcurrency import AVFoundation

/// Saves what it can of clips cut off by the app dying mid-recording, so the
/// last moments before a phone is taken aren't lost. Runs once per launch,
/// before anything starts uploading.
enum ClipRecovery {
    static func recoverInterruptedClips(in store: SessionStore) async {
        guard !store.saveIsBlocked else { return }
        let fileManager = FileManager.default
        let current = ChunkRecorder.stagingDirectory.standardizedFileURL
        let directories = (try? fileManager.contentsOfDirectory(at: ChunkRecorder.stagingRoot, includingPropertiesForKeys: nil)) ?? []
        for directory in directories where directory.standardizedFileURL != current {
            var keepDirectory = false
            let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for marker in files where marker.pathExtension == ChunkRecorder.markerExtension {
                if await !recoverClip(marker: marker, store: store) {
                    keepDirectory = true
                }
            }
            // Anything else here was a writer with no footage yet.
            if !keepDirectory { try? fileManager.removeItem(at: directory) }
        }
        await listFinishedClips(in: store)
        store.clearInterruptedSessions()
    }

    /// Returns false to try again next launch: the footage looks real, but
    /// couldn't be saved this time.
    private static func recoverClip(marker: URL, store: SessionStore) async -> Bool {
        let fileManager = FileManager.default
        let partial = marker.deletingPathExtension().appendingPathExtension("partial")
        guard let footage = largestFile(startingWith: partial.lastPathComponent, in: marker.deletingLastPathComponent()),
              let data = try? Data(contentsOf: marker),
              let info = try? JSONDecoder().decode(ChunkRecorder.ClipMarker.self, from: data),
              let session = store.sessions.first(where: { $0.id == info.sessionId }),
              !session.chunks.contains(where: { $0.index == info.index }) else {
            return true
        }
        let finalURL = session.directoryURL.appendingPathComponent("chunk_\(info.index).mp4")
        // Already moved into place, just before the app died. The scan for
        // unlisted clips below picks it up.
        guard !fileManager.fileExists(atPath: finalURL.path) else { return true }

        // AVFoundation goes by the extension, so `.partial` wouldn't open. It
        // must be `.mp4`: the writer's hidden file has no header, and as `.mov`
        // it fails with "Cannot Open". Its offsets assume no header, so adding
        // one breaks decoding.
        let source = partial.deletingPathExtension().appendingPathExtension("mp4")
        try? fileManager.moveItem(at: footage, to: source)
        let asset = AVURLAsset(url: source)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0,
              let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else {
            print("Interrupted clip \(info.index + 1) has no footage to recover.")
            return true
        }

        // Rewriting without re-encoding leaves a normal movie that plays in
        // Drive, instead of a file that stops abruptly with no final index.
        let exported = marker.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".mp4")
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else { return false }
        export.shouldOptimizeForNetworkUse = true
        do {
            try await export.export(to: exported, as: .mp4)
            _ = session.outputDirectory()
            try fileManager.moveItem(at: exported, to: finalURL)
        } catch {
            print("Couldn't recover interrupted clip \(info.index + 1): \(error.localizedDescription)")
            // Put the name back so the next launch finds it the same way.
            // The name is free of the empty file, or there'd be nothing to find.
            try? fileManager.removeItem(at: partial)
            try? fileManager.moveItem(at: source, to: partial)
            return false
        }
        print("Recovered \(String(format: "%.1f", duration.seconds)) s of interrupted clip \(info.index + 1).")
        await add(finalURL, index: info.index, to: session, store: store)
        return true
    }

    /// The file actually holding a clip's footage. With
    /// `shouldOptimizeForNetworkUse` on, AVFoundation leaves the output file
    /// empty until finishing and writes to `<name>.sb-<random>` beside it. That
    /// name is undocumented, so this looks for whichever file has the data
    /// rather than for that exact pattern.
    private static func largestFile(startingWith prefix: String, in directory: URL) -> URL? {
        let keys: [URLResourceKey] = [.fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        let sized = files.filter { $0.lastPathComponent.hasPrefix(prefix) }.map { file in
            (file: file, size: (try? file.resourceValues(forKeys: Set(keys)).fileSize) ?? 0)
        }
        return sized.filter { $0.size > 0 }.max { $0.size < $1.size }?.file
    }

    /// Finished clips the app died before listing: the file is complete, but
    /// nothing knows about it, so it would never upload.
    private static func listFinishedClips(in store: SessionStore) async {
        for session in store.sessions where store.interruptedSessionIDs.contains(session.id) {
            let files = (try? FileManager.default.contentsOfDirectory(at: session.directoryURL, includingPropertiesForKeys: nil)) ?? []
            for file in files {
                let name = file.deletingPathExtension().lastPathComponent
                guard file.pathExtension == "mp4", name.hasPrefix("chunk_"),
                      let index = Int(name.dropFirst("chunk_".count)),
                      !session.chunks.contains(where: { $0.index == index }) else { continue }
                await add(file, index: index, to: session, store: store)
            }
        }
    }

    private static func add(_ url: URL, index: Int, to session: RecordingSession, store: SessionStore) async {
        guard let duration = try? await AVURLAsset(url: url).load(.duration), duration.seconds > 0 else { return }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        session.chunks.append(VideoChunk(index: index, localURL: url, duration: duration.seconds, fileSize: size))
        session.chunks.sort { $0.index < $1.index }
        store.save()
    }
}
