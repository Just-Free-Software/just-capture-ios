@preconcurrency import AVFoundation
import CoreMedia

/// A chunk file the recorder has finished with, successfully or not.
nonisolated struct RecordedChunk: Sendable {
    let index: Int
    let url: URL
    let duration: TimeInterval
    let fileSize: Int64
    /// Set when the file couldn't be written; the file has been deleted.
    let errorDescription: String?
}

/// Writes the camera's sample buffers into back-to-back MP4 chunks with
/// `AVAssetWriter`. Capture never stops between chunks: each cut ends the old
/// writer and starts a new one on the same video frame, so there is no gap
/// and each chunk's duration comes from the media timestamps, not the clock.
///
/// Every chunk is a complete, standalone MP4 (ftyp → moov → mdat, `hvc1`),
/// so it plays on its own in Drive and in browsers. Only files whose writer
/// reached `.completed` are reported as successful; a file that wasn't
/// finished properly would have no usable index and wouldn't play.
///
/// All state is confined to `queue`, which is also the sample buffer queue.
nonisolated final class ChunkRecorder: NSObject, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.justcapture.camera.samples")

    /// Called on the main queue, in chunk order.
    @MainActor var onChunkStarted: (@MainActor (Int) -> Void)?
    @MainActor var onChunkFinished: (@MainActor (RecordedChunk) -> Void)?
    /// Called on the main queue when a chunk can't be written. The recorder
    /// has already stopped accepting frames; the caller should stop.
    @MainActor var onFailure: (@MainActor (String) -> Void)?
    /// Called on the main queue once, after `stop()`, when every chunk has
    /// been reported.
    @MainActor var onStopped: (@MainActor () -> Void)?

    // Confined to `queue` like the rest of the recorder's state.
    private final class Segment: @unchecked Sendable {
        let index: Int
        /// The `.partial` file in `stagingDirectory` being written.
        let url: URL
        /// Where the finished chunk is moved to.
        let outputDirectory: URL
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let audioInput: AVAssetWriterInput?
        let startTime: CMTime
        let dimensions: CMVideoDimensions
        /// Where the chunk ends: the next chunk's first frame for a cut, or
        /// the end of the last frame for a stop.
        var endTime: CMTime?
        var lastVideoEnd: CMTime
        /// End of the last audio buffer accepted for this chunk (queued or
        /// written), so the same buffer isn't taken twice.
        var queuedAudioEnd: CMTime = .invalid
        /// End of the last audio buffer the writer has actually taken.
        var writtenAudioEnd: CMTime = .invalid
        /// Audio waiting for the writer to accept it. Until a writer has its
        /// first video frame it reports its audio input as not ready, and
        /// audio runs ~0.5 s ahead of video, so a new chunk's opening audio
        /// always has to wait here.
        var pendingAudio: [CMSampleBuffer] = []
        /// Frames the camera or encoder dropped in this chunk's time range.
        var drops = FrameDrops()

        init(_ prepared: PreparedWriter, index: Int, startTime: CMTime, outputDirectory: URL) {
            self.index = index
            self.url = prepared.url
            self.outputDirectory = outputDirectory
            self.writer = prepared.writer
            self.videoInput = prepared.videoInput
            self.audioInput = prepared.audioInput
            self.startTime = startTime
            self.dimensions = prepared.dimensions
            self.lastVideoEnd = startTime
        }
    }

    /// Why and when a chunk lost frames, so the log shows which part of the
    /// pipeline lost them and whether they cluster at the cut.
    private struct FrameDrops {
        enum Reason: String {
            /// `queue` was still busy when the camera had the next frame.
            case late
            /// The camera's buffers were all held downstream (the encoder
            /// falling behind).
            case outOfBuffers
            /// The camera itself skipped, e.g. while reconfiguring.
            case discontinuity
            /// The frame arrived, but the writer's encoder wasn't ready.
            case writerBusy
            case unknown

            init(cameraReason: String?) {
                if cameraReason == kCMSampleBufferDroppedFrameReason_FrameWasLate as String {
                    self = .late
                } else if cameraReason == kCMSampleBufferDroppedFrameReason_OutOfBuffers as String {
                    self = .outOfBuffers
                } else if cameraReason == kCMSampleBufferDroppedFrameReason_Discontinuity as String {
                    self = .discontinuity
                } else {
                    self = .unknown
                }
            }
        }

        // Drops are rare; past this many, only the count grows.
        private static let maxRecorded = 20
        private(set) var count = 0
        /// Each drop's reason and its time from the chunk's start.
        private var recorded: [(reason: Reason, offset: Double)] = []

        var isEmpty: Bool { count == 0 }

        mutating func add(_ reason: Reason, offset: Double) {
            count += 1
            if recorded.count < Self.maxRecorded {
                recorded.append((reason, offset))
            }
        }

        var summary: String {
            let list = recorded
                .map { "\($0.reason.rawValue) at \(String(format: "%.2f", $0.offset)) s" }
                .joined(separator: ", ")
            let more = count > recorded.count ? " (+\(count - recorded.count) more)" : ""
            return "\(count) frames dropped: \(list)\(more)"
        }
    }

    /// A writer that has started writing but not its session, ready to take
    /// the next chunk's first frame. It isn't tied to a chunk or a recording:
    /// it writes into `stagingDirectory`, so one can be ready before the
    /// record button is pressed.
    private final class PreparedWriter: @unchecked Sendable {
        let url: URL
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let audioInput: AVAssetWriterInput?
        let dimensions: CMVideoDimensions
        /// The `settingsGeneration` it was built with.
        let settingsGeneration: Int

        init(url: URL, writer: AVAssetWriter, videoInput: AVAssetWriterInput, audioInput: AVAssetWriterInput?, dimensions: CMVideoDimensions, settingsGeneration: Int) {
            self.url = url
            self.writer = writer
            self.videoInput = videoInput
            self.audioInput = audioInput
            self.dimensions = dimensions
            self.settingsGeneration = settingsGeneration
        }

        func matches(_ dimensions: CMVideoDimensions, settingsGeneration: Int) -> Bool {
            self.settingsGeneration == settingsGeneration
                && self.dimensions.width == dimensions.width && self.dimensions.height == dimensions.height
        }

        func discard() {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
        }
    }

    // Lets a crash or kill mid-chunk keep everything up to the last fragment
    // instead of leaving a file with no index. finishWriting still rewrites
    // the file as a regular, non-fragmented movie.
    private static let fragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
    // Audio lags video by less than this; past it, a chunk waiting for its
    // last audio is finished anyway.
    private static let audioWaitLimit = CMTime(seconds: 1, preferredTimescale: 600)
    // Video reaches us much later than audio: stabilization holds frames
    // back (~1.6 s on an iPhone 17), while audio arrives within a few ms. So
    // when a chunk's first frame arrives, its first moments of audio arrived
    // long ago. Audio is kept for longer than the video delay so it can be
    // replayed into the new chunk.
    private static let audioHistoryMargin = CMTime(seconds: 0.5, preferredTimescale: 600)
    private static let minimumAudioHistory = CMTime(seconds: 1, preferredTimescale: 600)
    private static let maximumAudioHistory = CMTime(seconds: 5, preferredTimescale: 600)
    private static let minimumManualCutLength = CMTime(seconds: 1, preferredTimescale: 600)
    // Upper bound on audio held for a writer that isn't taking it, so a
    // stuck writer can't grow it forever. It's above the most audio a new
    // chunk is replayed (maximumAudioHistory at ~23 ms per buffer).
    private static let maxPendingAudioBuffers = 300
    // A new chunk starts with ~2 s of saved audio to write. Doing it all at
    // the cut keeps `queue` busy past the next frame, which the camera then
    // drops, so it's written a few buffers per callback instead (catching up
    // in about a quarter of a second).
    private static let audioBuffersPerCallback = 4
    // After a writer can't be prepared (e.g. the disk is full), wait this
    // long before trying again rather than retrying on every frame.
    private static let prepareRetryDelay = CMTime(seconds: 2, preferredTimescale: 600)

    /// Where chunks are written until they're finished, independent of the
    /// recording, so a writer can be prepared before recording starts.
    /// Finished chunks are moved to the recording's directory, which is on
    /// the same volume, so the move is a rename.
    private static let stagingDirectory: URL = {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Recording", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Builds the next chunk's writer ahead of the cut. Creating a writer and
    /// its encoder takes long enough that doing it on `queue` at the cut makes
    /// the camera drop the frames that arrive meanwhile.
    private let prepareQueue = DispatchQueue(label: "com.justcapture.camera.prepare")
    /// Closes finished writers. Flushing the last audio and the encoder
    /// takes long enough at a cut that doing it on `queue` drops a frame.
    private let finishQueue = DispatchQueue(label: "com.justcapture.camera.finish")

    private var videoSettings: [String: Any]?
    private var audioSettings: [String: Any]?
    private var prepared: PreparedWriter?
    private var isPreparing = false
    /// Host time before which a failed preparation isn't retried.
    private var nextPrepareAttempt: CMTime = .zero
    /// Bumped on every settings change, so a writer built with older
    /// settings is replaced instead of used.
    private var settingsGeneration = 0
    /// Bumped on every start and stop, so a stop timer from an earlier
    /// recording does nothing.
    private var generation = 0

    private var isActive = false
    private var isStopping = false
    private var outputDirectory: URL?
    private var chunkDuration = CMTime(seconds: 30, preferredTimescale: 600)
    private var nextChunkIndex = 0

    private var current: Segment?
    /// The previous chunk, cut on a video frame but still waiting for the
    /// audio up to that point.
    private var draining: Segment?
    private var cutRequested = false
    private var previousVideoTime: CMTime = .invalid
    /// The longest any video frame has taken to reach us after capture.
    /// The delay dips briefly when the camera drops frames to catch up; the
    /// audio history must not shrink with it, or the next chunk's opening
    /// audio is discarded before its first frame arrives.
    private var videoDelay: CMTime = .zero
    /// When stop was requested. Recording carries on until video captured
    /// up to this moment has arrived.
    private var stopTime: CMTime?

    private var audioHistoryLength: CMTime {
        let wanted = CMTimeAdd(videoDelay, Self.audioHistoryMargin)
        return CMTimeClampToRange(wanted, range: CMTimeRange(start: Self.minimumAudioHistory, end: Self.maximumAudioHistory))
    }
    private var recentAudio: [CMSampleBuffer] = []

    private var finishingCount = 0
    /// Chunks can finish out of order; they're held here so they're
    /// reported in index order.
    private var finishedChunks: [Int: RecordedChunk] = [:]
    private var nextIndexToReport = 0

    /// Sets the encoder settings for chunks started from now on. Must be
    /// called after any change to the capture outputs' connections.
    func updateSettings(video: [String: Any]?, audio: [String: Any]?) {
        nonisolated(unsafe) let video = video
        nonisolated(unsafe) let audio = audio
        queue.async {
            self.videoSettings = video
            self.audioSettings = audio
            self.settingsGeneration += 1
            // While recording, the stale prepared writer is left until the
            // next cut replaces it. A camera flip lands here while the old
            // camera's last ~1.6 s of frames are still being encoded, and
            // tearing down one encoder and starting another then stalls the
            // current one (~0.7 s of frames lost on an iPhone 17). When idle,
            // the next frame prepares a matching writer.
            if !self.isActive {
                self.discardPrepared()
            }
        }
    }

    /// Throws away the prepared writer. Call when the capture session is
    /// interrupted: in the background the app loses the hardware encoder,
    /// and a writer that sat through that may fail on its first frame.
    /// A new one is prepared when frames resume.
    func discardPreparedWriter() {
        queue.async { self.discardPrepared() }
    }

    func start(outputDirectory: URL, chunkDuration: TimeInterval) {
        queue.async {
            self.outputDirectory = outputDirectory
            self.chunkDuration = CMTime(seconds: chunkDuration, preferredTimescale: 600)
            self.nextChunkIndex = 0
            self.nextIndexToReport = 0
            self.finishedChunks = [:]
            self.cutRequested = false
            self.previousVideoTime = .invalid
            self.isStopping = false
            self.generation += 1
            self.isActive = true
        }
    }

    /// Ends the current chunk on the next video frame, unless it's under a
    /// second long — a file that short isn't worth uploading.
    func cutNow() {
        queue.async {
            guard self.isActive, let segment = self.current,
                  CMTimeSubtract(segment.lastVideoEnd, segment.startTime) >= Self.minimumManualCutLength else { return }
            self.cutRequested = true
        }
    }

    /// Ends the recording at the moment it's called. Video captured before
    /// then is still on its way (see `videoDelay`), so the last chunk stays
    /// open until a frame from after the stop arrives, or a few seconds pass
    /// without one (the camera was interrupted).
    func stop() {
        queue.async {
            guard self.isActive, self.current != nil, self.stopTime == nil else {
                if self.stopTime == nil { self.finishStopping() }
                return
            }
            self.stopTime = CMClockGetTime(CMClockGetHostTimeClock())
            let generation = self.generation
            let wait = min(self.videoDelay.seconds + 1, Self.maximumAudioHistory.seconds)
            self.queue.asyncAfter(deadline: .now() + wait) {
                guard self.generation == generation, self.stopTime != nil else { return }
                self.finishStopping()
            }
        }
    }

    private func finishStopping() {
        stopTime = nil
        isActive = false
        isStopping = true
        generation += 1
        // The prepared writer is kept for the next recording.
        if let draining {
            self.draining = nil
            finish(draining)
        }
        if let current {
            self.current = nil
            current.endTime = current.lastVideoEnd
            finish(current)
        }
        reportStoppedIfDone()
    }

    // MARK: - Samples

    private func handleVideo(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = sampleBuffer.imageBuffer else { return }
        let dimensions = CMVideoDimensions(
            width: Int32(CVPixelBufferGetWidth(pixelBuffer)),
            height: Int32(CVPixelBufferGetHeight(pixelBuffer))
        )
        let time = sampleBuffer.presentationTimeStamp
        // Capture timestamps are on the host clock.
        let delay = CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), time)
        if delay > videoDelay, delay < Self.maximumAudioHistory {
            videoDelay = delay
        }
        guard isActive else {
            // Keep a writer ready for the record button, matching the camera
            // and settings in use now. Otherwise the first chunk builds one
            // on its first frame, and the camera drops ~0.5 s meanwhile.
            if let prepared, !prepared.matches(dimensions, settingsGeneration: settingsGeneration) {
                discardPrepared()
            }
            prepareNextWriter(dimensions: dimensions)
            return
        }
        if let stopTime, time >= stopTime {
            finishStopping()
            return
        }

        if let segment = current {
            // A camera flip can change the frame size; a writer is set up for
            // one size, so that also starts a new chunk.
            let sizeChanged = dimensions.width != segment.dimensions.width || dimensions.height != segment.dimensions.height
            if cutRequested || sizeChanged || CMTimeSubtract(time, segment.startTime) >= chunkDuration {
                cutRequested = false
                cut(segment, at: time)
            }
        }

        if current == nil {
            guard startSegment(at: time, dimensions: dimensions) else { return }
        }
        guard let segment = current else { return }

        if !segment.videoInput.isReadyForMoreMediaData {
            segment.drops.add(.writerBusy, offset: CMTimeSubtract(time, segment.startTime).seconds)
        } else if !segment.videoInput.append(sampleBuffer) {
            fail(segment)
            return
        }
        let frameDuration = previousVideoTime.isValid && time > previousVideoTime
            ? CMTimeSubtract(time, previousVideoTime)
            : CMTime(value: 1, timescale: 30)
        previousVideoTime = time
        segment.lastVideoEnd = CMTimeAdd(time, frameDuration)

        // Taking video is what lets a writer take more audio.
        writePendingAudio(for: segment)
        if let draining {
            writePendingAudio(for: draining)
            finishDrainingIfComplete(videoTime: time)
        }
    }

    private func handleAudio(_ sampleBuffer: CMSampleBuffer) {
        // Kept even before recording starts: the first chunk begins on a
        // frame captured before the record button was pressed.
        recentAudio.append(sampleBuffer)
        let oldest = CMTimeSubtract(sampleBuffer.presentationTimeStamp, audioHistoryLength)
        while let first = recentAudio.first, first.presentationTimeStamp < oldest {
            recentAudio.removeFirst()
        }
        guard isActive else { return }

        if let draining {
            append(audio: sampleBuffer, to: draining)
            finishDrainingIfComplete(videoTime: nil)
        }
        if let current {
            append(audio: sampleBuffer, to: current)
        }
    }

    /// Queues audio that overlaps the segment's time range, then writes as
    /// much of the queue as the writer will take. A buffer that straddles a
    /// cut goes to both chunks; each writer trims it to its own range, so
    /// neither side loses audio at the cut.
    private func append(audio sampleBuffer: CMSampleBuffer, to segment: Segment) {
        guard segment.audioInput != nil else { return }
        let start = sampleBuffer.presentationTimeStamp
        let end = CMTimeAdd(start, sampleBuffer.duration)
        guard end > segment.startTime else { return }
        if let endTime = segment.endTime, start >= endTime { return }
        if segment.queuedAudioEnd.isValid, start < segment.queuedAudioEnd { return }
        segment.pendingAudio.append(sampleBuffer)
        segment.queuedAudioEnd = end
        if segment.pendingAudio.count > Self.maxPendingAudioBuffers {
            segment.pendingAudio.removeFirst()
            print("⚠️ Chunk \(segment.index + 1): writer isn't taking audio; dropped a buffer")
        }
        writePendingAudio(for: segment)
    }

    private func writePendingAudio(for segment: Segment) {
        guard let input = segment.audioInput else { return }
        var written = 0
        while written < Self.audioBuffersPerCallback, let next = segment.pendingAudio.first, input.isReadyForMoreMediaData {
            written += 1
            guard input.append(next) else {
                fail(segment)
                return
            }
            segment.pendingAudio.removeFirst()
            segment.writtenAudioEnd = CMTimeAdd(next.presentationTimeStamp, next.duration)
        }
    }

    /// Finishes the chunk waiting on its last audio once that audio is
    /// written, or once video is well past the cut and the audio clearly
    /// isn't coming (the microphone went away).
    private func finishDrainingIfComplete(videoTime: CMTime?) {
        guard let draining, let end = draining.endTime else { return }
        let audioDone = draining.writtenAudioEnd.isValid && draining.writtenAudioEnd >= end
        let gaveUp = videoTime.map { CMTimeSubtract($0, end) > Self.audioWaitLimit } ?? false
        guard audioDone || gaveUp else { return }
        self.draining = nil
        finish(draining)
    }

    // MARK: - Segments

    private func startSegment(at time: CMTime, dimensions: CMVideoDimensions) -> Bool {
        let index = nextChunkIndex
        let ready: PreparedWriter
        let directory: URL
        do {
            guard let outputDirectory else { throw RecorderError.cannotStart }
            directory = outputDirectory
            if let prepared, prepared.matches(dimensions, settingsGeneration: settingsGeneration),
               prepared.writer.status == .writing {
                ready = prepared
                self.prepared = nil
            } else {
                // A size or settings change, or the preparation hadn't
                // finished: build it here, at the cost of a frame or two.
                discardPrepared()
                guard let videoSettings else { throw RecorderError.cannotStart }
                ready = try Self.makeWriter(dimensions: dimensions, videoSettings: videoSettings, audioSettings: audioSettings, settingsGeneration: settingsGeneration)
            }
        } catch {
            isActive = false
            let message = "Couldn't start a new clip: \(error.localizedDescription)"
            DispatchQueue.main.async { self.onFailure?(message) }
            return false
        }

        ready.writer.startSession(atSourceTime: time)
        let segment = Segment(ready, index: index, startTime: time, outputDirectory: directory)
        current = segment
        nextChunkIndex += 1
        for buffer in recentAudio {
            append(audio: buffer, to: segment)
        }
        DispatchQueue.main.async { self.onChunkStarted?(index) }
        prepareNextWriter(dimensions: dimensions)
        return true
    }

    /// Builds the writer for the next chunk to start on `prepareQueue`. If
    /// it isn't ready by the cut, the cut builds its own.
    private func prepareNextWriter(dimensions: CMVideoDimensions) {
        guard prepared == nil, !isPreparing, let videoSettings,
              CMClockGetTime(CMClockGetHostTimeClock()) >= nextPrepareAttempt else { return }
        isPreparing = true
        let settingsGeneration = settingsGeneration
        nonisolated(unsafe) let video = videoSettings
        nonisolated(unsafe) let audio = audioSettings
        prepareQueue.async {
            let writer = try? Self.makeWriter(dimensions: dimensions, videoSettings: video, audioSettings: audio, settingsGeneration: settingsGeneration)
            self.queue.async {
                self.isPreparing = false
                guard let writer else {
                    self.nextPrepareAttempt = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), Self.prepareRetryDelay)
                    return
                }
                if self.prepared == nil, writer.settingsGeneration == self.settingsGeneration {
                    self.prepared = writer
                } else {
                    self.discard(writer)
                }
            }
        }
    }

    private func discardPrepared() {
        if let prepared { discard(prepared) }
        prepared = nil
    }

    /// Tearing down a writer's encoder can block long enough to drop a
    /// frame, so it's done on `finishQueue`. A prepared writer has no
    /// session and nothing appends to it, so that's safe.
    private func discard(_ writer: PreparedWriter) {
        finishQueue.async { writer.discard() }
    }

    private static func makeWriter(dimensions: CMVideoDimensions, videoSettings: [String: Any], audioSettings: [String: Any]?, settingsGeneration: Int) throws -> PreparedWriter {
        // Each writer gets its own file, moved to the recording's directory
        // as chunk_N.mp4 only once it's finished.
        let url = stagingDirectory.appendingPathComponent("\(UUID().uuidString).partial")

        // The recommended settings don't account for the connection's
        // rotation; the frames themselves have the right size.
        var videoSettings = videoSettings
        videoSettings[AVVideoWidthKey] = Int(dimensions.width)
        videoSettings[AVVideoHeightKey] = Int(dimensions.height)

        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
            // Puts the index before the media so Drive can start playing
            // without downloading the whole file.
            writer.shouldOptimizeForNetworkUse = true
            writer.movieFragmentInterval = fragmentInterval

            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = true
            guard writer.canAdd(videoInput) else { throw RecorderError.cannotAddInput }
            writer.add(videoInput)

            var audioInput: AVAssetWriterInput?
            if let audioSettings {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                input.expectsMediaDataInRealTime = true
                if writer.canAdd(input) {
                    writer.add(input)
                    audioInput = input
                }
            }

            guard writer.startWriting() else { throw writer.error ?? RecorderError.cannotStart }
            return PreparedWriter(url: url, writer: writer, videoInput: videoInput, audioInput: audioInput, dimensions: dimensions, settingsGeneration: settingsGeneration)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    /// Ends `segment` at `time`, the first frame of the next chunk. It
    /// finishes once the audio up to the cut has arrived.
    private func cut(_ segment: Segment, at time: CMTime) {
        current = nil
        segment.endTime = time
        // Only one chunk waits for audio at a time; chunks are at least a
        // second apart, so an older one has long had its audio.
        if let draining {
            self.draining = nil
            finish(draining)
        }
        if segment.audioInput == nil || (segment.writtenAudioEnd.isValid && segment.writtenAudioEnd >= time) {
            finish(segment)
        } else {
            draining = segment
        }
    }

    private func finish(_ segment: Segment) {
        let end = segment.endTime ?? segment.lastVideoEnd
        let duration = max(CMTimeSubtract(end, segment.startTime).seconds, 0.01)
        if !segment.drops.isEmpty {
            print("⚠️ Chunk \(segment.index + 1) (\(String(format: "%.2f", duration)) s): \(segment.drops.summary)")
        }
        finishingCount += 1
        // The segment is no longer current or draining, so nothing on
        // `queue` touches it from here on.
        finishQueue.async {
            self.close(segment, endingAt: end, duration: duration)
        }
    }

    private func close(_ segment: Segment, endingAt end: CMTime, duration: TimeInterval) {
        // Whatever audio is still queued: the writer takes it now that it's
        // getting no more video. A failed append shows up as the writer's
        // status below.
        if let input = segment.audioInput {
            while let next = segment.pendingAudio.first, input.isReadyForMoreMediaData, input.append(next) {
                segment.pendingAudio.removeFirst()
            }
        }
        if !segment.pendingAudio.isEmpty {
            print("⚠️ Chunk \(segment.index + 1): \(segment.pendingAudio.count) audio buffers never written")
        }
        segment.videoInput.markAsFinished()
        segment.audioInput?.markAsFinished()
        segment.writer.endSession(atSourceTime: end)
        segment.writer.finishWriting {
            self.queue.async {
                self.finishingCount -= 1
                let result: RecordedChunk
                let finalURL = segment.outputDirectory.appendingPathComponent("chunk_\(segment.index).mp4")
                do {
                    guard segment.writer.status == .completed else {
                        throw segment.writer.error ?? RecorderError.cannotFinish
                    }
                    try? FileManager.default.removeItem(at: finalURL)
                    try FileManager.default.moveItem(at: segment.url, to: finalURL)
                    let fileSize = (try? FileManager.default.attributesOfItem(atPath: finalURL.path)[.size] as? Int64) ?? 0
                    result = RecordedChunk(index: segment.index, url: finalURL, duration: duration, fileSize: fileSize, errorDescription: nil)
                } catch {
                    try? FileManager.default.removeItem(at: segment.url)
                    result = RecordedChunk(index: segment.index, url: finalURL, duration: duration, fileSize: 0, errorDescription: error.localizedDescription)
                }
                self.report(result)
            }
        }
    }

    /// The writer rejected a sample (usually the disk is full). Stops taking
    /// frames; the chunks already finished are still reported.
    private func fail(_ segment: Segment) {
        let message = segment.writer.error?.localizedDescription ?? "The camera stopped recording unexpectedly."
        segment.writer.cancelWriting()
        try? FileManager.default.removeItem(at: segment.url)
        if current === segment { current = nil }
        if draining === segment { draining = nil }
        isActive = false
        discardPrepared()
        report(RecordedChunk(index: segment.index, url: segment.url, duration: 0, fileSize: 0, errorDescription: message))
        DispatchQueue.main.async { self.onFailure?(message) }
    }

    private func report(_ chunk: RecordedChunk) {
        finishedChunks[chunk.index] = chunk
        while let next = finishedChunks.removeValue(forKey: nextIndexToReport) {
            nextIndexToReport += 1
            DispatchQueue.main.async { self.onChunkFinished?(next) }
        }
        reportStoppedIfDone()
    }

    private func reportStoppedIfDone() {
        guard isStopping, finishingCount == 0 else { return }
        isStopping = false
        DispatchQueue.main.async { self.onStopped?() }
    }

    private enum RecorderError: LocalizedError {
        case cannotAddInput
        case cannotStart
        case cannotFinish

        var errorDescription: String? {
            switch self {
            case .cannotAddInput: "The video encoder isn't available."
            case .cannotStart: "The file couldn't be created."
            case .cannotFinish: "The clip couldn't be saved."
            }
        }
    }
}

nonisolated extension ChunkRecorder: AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureAudioDataOutput {
            handleAudio(sampleBuffer)
        } else {
            handleVideo(sampleBuffer)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let reason = CMGetAttachment(sampleBuffer, key: kCMSampleBufferAttachmentKey_DroppedFrameReason, attachmentModeOut: nil) as? String
        recordDrop(FrameDrops.Reason(cameraReason: reason), at: sampleBuffer.presentationTimeStamp)
    }

    /// Charges a frame the camera dropped to the chunk it belongs to: the
    /// chunk still waiting on audio if it's from before that cut, otherwise
    /// the current one (a negative offset means just before its first frame).
    private func recordDrop(_ reason: FrameDrops.Reason, at time: CMTime) {
        let segment: Segment?
        if let draining, let end = draining.endTime, time.isValid, time < end {
            segment = draining
        } else {
            segment = current
        }
        guard let segment else { return }
        let offset = time.isValid ? CMTimeSubtract(time, segment.startTime).seconds : .nan
        segment.drops.add(reason, offset: offset)
    }
}
