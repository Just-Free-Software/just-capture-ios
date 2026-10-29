@preconcurrency import AVFoundation
import CoreMedia
import Observation

@Observable
class CameraManager: NSObject {
    let captureSession = AVCaptureSession()
    private(set) var isRecording: Bool = false
    /// True between a stop request and the final chunk being written. A new
    /// recording can't start until this clears, otherwise the old session's
    /// last chunk would be handed to the new session.
    private(set) var isFinishing: Bool = false
    private(set) var currentChunkIndex: Int = 0
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var isTorchOn: Bool = false
    private(set) var isUsingFrontCamera: Bool = false
    private(set) var permissionDenied: Bool = false
    /// Set when recording had to stop on its own (e.g. the camera was
    /// interrupted or the device ran out of space). Cleared on the next start.
    var recordingError: String?
    var onChunkCompleted: ((VideoChunk) -> Void)?

    // Configured on sessionQueue, started/stopped from the main actor, as
    // AVFoundation allows.
    nonisolated(unsafe) private let movieFileOutput = AVCaptureMovieFileOutput()
    private let sessionQueue = DispatchQueue(label: "com.justapp.camera.session")

    private var currentVideoDevice: AVCaptureDevice?
    private var chunkDuration: TimeInterval = 30
    private var outputDirectory: URL?

    private var recordingTimer: Timer?
    private var chunkTimer: Timer?
    private var recordingStartDate: Date?
    private var currentChunkStartDate: Date?
    private var isSessionConfigured = false

    func setupSession() {
        guard !isSessionConfigured else { return }
        isSessionConfigured = true
        Task {
            // Ask up front: configuring the session before access is granted
            // leaves the preview black until the next launch.
            let videoGranted = await AVCaptureDevice.requestAccess(for: .video)
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            guard videoGranted else {
                permissionDenied = true
                isSessionConfigured = false
                return
            }
            permissionDenied = false
            configureAndStartSession()
        }
    }

    private func configureAndStartSession() {
        let useFront = isUsingFrontCamera
        sessionQueue.async {
            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .hd1920x1080

            let videoDevice = self.getDevice(for: useFront ? .front : .back)

            if let videoDevice = videoDevice, let videoInput = try? AVCaptureDeviceInput(device: videoDevice) {
                if self.captureSession.canAddInput(videoInput) {
                    self.captureSession.addInput(videoInput)
                }
            }

            if let audioDevice = AVCaptureDevice.default(for: .audio), let audioInput = try? AVCaptureDeviceInput(device: audioDevice) {
                if self.captureSession.canAddInput(audioInput) {
                    self.captureSession.addInput(audioInput)
                }
            }

            if self.captureSession.canAddOutput(self.movieFileOutput) {
                self.captureSession.addOutput(self.movieFileOutput)
            }
            self.configureVideoConnection(mirrored: useFront)

            self.captureSession.commitConfiguration()
            self.captureSession.startRunning()
            Task { @MainActor in
                self.currentVideoDevice = videoDevice
            }
        }
    }

    /// Applies orientation, stabilization and codec to the movie output's
    /// video connection. The connection is rebuilt whenever the video input
    /// changes, so this must run after every camera flip too.
    nonisolated private func configureVideoConnection(mirrored: Bool) {
        guard let connection = movieFileOutput.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }
        if connection.isVideoStabilizationSupported {
            connection.preferredVideoStabilizationMode = .auto
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
        if movieFileOutput.availableVideoCodecTypes.contains(.hevc) {
            movieFileOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
        }
    }

    nonisolated private func getDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInUltraWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera
        ]

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: position
        )

        return discoverySession.devices.first
    }

    func startRecording(chunkDuration: TimeInterval, outputDirectory: URL) {
        guard !isRecording, !isFinishing else { return }
        self.chunkDuration = chunkDuration
        self.outputDirectory = outputDirectory
        self.currentChunkIndex = 0
        self.elapsedTime = 0
        self.recordingError = nil
        self.isRecording = true
        self.recordingStartDate = Date()

        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let startDate = self.recordingStartDate else { return }
                self.elapsedTime = Date().timeIntervalSince(startDate)
            }
        }

        startNextChunkSegment()
    }

    private func startNextChunkSegment() {
        guard let dir = outputDirectory else { return }
        let url = dir.appendingPathComponent("chunk_\(currentChunkIndex).mp4")

        if FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }

        movieFileOutput.startRecording(to: url, recordingDelegate: self)
        currentChunkStartDate = Date()
        scheduleChunkTimer()
    }

    private func scheduleChunkTimer() {
        chunkTimer?.invalidate()
        chunkTimer = Timer.scheduledTimer(withTimeInterval: chunkDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleChunkTimerFired()
            }
        }
    }

    private func handleChunkTimerFired() {
        guard isRecording else { return }
        movieFileOutput.stopRecording()
    }

    /// Ends the current chunk immediately and hands it to the upload queue,
    /// without waiting for the configured chunk duration to elapse. The next
    /// chunk starts automatically via the recording delegate.
    func cutChunkNow() {
        guard isRecording else { return }
        // Ignore taps within the first second of a chunk — a file that short
        // isn't worth uploading and often can't be written validly yet.
        if let chunkStart = currentChunkStartDate, Date().timeIntervalSince(chunkStart) < 1 { return }
        chunkTimer?.invalidate()
        chunkTimer = nil
        movieFileOutput.stopRecording()
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        chunkTimer?.invalidate()
        chunkTimer = nil
        // currentChunkStartDate is left alone: the delegate still needs it to
        // compute the final chunk's real duration.
        if movieFileOutput.isRecording {
            isFinishing = true
            movieFileOutput.stopRecording()
        }
    }

    func toggleTorch() {
        guard let device = currentVideoDevice, device.hasTorch else { return }
        let newTorchMode = !isTorchOn
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                if newTorchMode {
                    try device.setTorchModeOn(level: 1.0)
                } else {
                    device.torchMode = .off
                }
                device.unlockForConfiguration()
                Task { @MainActor in
                    self.isTorchOn = newTorchMode
                }
            } catch {
                print("Failed to toggle torch: \(error)")
            }
        }
    }

    func flipCamera() {
        isUsingFrontCamera.toggle()
        // The torch belongs to the back camera; switching away turns it off.
        isTorchOn = false
        let useFront = isUsingFrontCamera
        sessionQueue.async {
            self.captureSession.beginConfiguration()
            if let currentInput = self.captureSession.inputs.first(where: { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.video) == true }) {
                self.captureSession.removeInput(currentInput)
            }
            let newDevice = self.getDevice(for: useFront ? .front : .back)
            if let newDevice = newDevice, let newInput = try? AVCaptureDeviceInput(device: newDevice) {
                if self.captureSession.canAddInput(newInput) {
                    self.captureSession.addInput(newInput)
                }
            }
            self.configureVideoConnection(mirrored: useFront)
            self.captureSession.commitConfiguration()
            Task { @MainActor in
                self.currentVideoDevice = newDevice
            }
        }
    }
}

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        let isSuccessfullyWritten: Bool
        if let err = error as NSError? {
            isSuccessfullyWritten = (err.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool) ?? false
        } else {
            isSuccessfullyWritten = true
        }

        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputFileURL.path)[.size] as? Int64) ?? 0

        Task { @MainActor in
            let chunkIndex = self.currentChunkIndex
            let hasData = isSuccessfullyWritten && fileSize > 0

            // Only emit chunks that were actually written with data. When the
            // capture session is interrupted (backgrounding, a phone call) the
            // delegate fires with empty/truncated files — emitting those would
            // spam the upload queue with 0-byte chunks.
            if hasData {
                let actualDuration: TimeInterval
                if let chunkStart = self.currentChunkStartDate {
                    actualDuration = max(Date().timeIntervalSince(chunkStart), 0.01)
                } else {
                    actualDuration = self.chunkDuration
                }
                self.onChunkCompleted?(VideoChunk(index: chunkIndex, localURL: outputFileURL, duration: actualDuration, fileSize: fileSize))
            }

            if self.isRecording {
                if !hasData {
                    // A segment that produced nothing means the camera can't
                    // record right now (interrupted, out of disk). Restarting
                    // immediately would fail the same way in a tight loop.
                    self.recordingError = error?.localizedDescription ?? "The camera stopped recording unexpectedly."
                    self.stopRecording()
                    self.isFinishing = false
                    self.currentChunkStartDate = nil
                    return
                }
                self.currentChunkIndex += 1
                self.startNextChunkSegment()
            } else {
                self.isFinishing = false
                self.currentChunkStartDate = nil
            }
        }
    }
}
