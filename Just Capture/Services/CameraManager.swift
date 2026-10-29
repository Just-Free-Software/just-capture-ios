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

    // Configured on sessionQueue. Their sample buffers go to the recorder,
    // which writes them into chunk files.
    nonisolated(unsafe) private let videoDataOutput = AVCaptureVideoDataOutput()
    nonisolated(unsafe) private let audioDataOutput = AVCaptureAudioDataOutput()
    private let recorder = ChunkRecorder()
    private let sessionQueue = DispatchQueue(label: "com.justapp.camera.session")

    private var currentVideoDevice: AVCaptureDevice?

    private var recordingTimer: Timer?
    private var recordingStartDate: Date?
    private var isSessionConfigured = false
    /// Keeps the app running long enough to finish the last chunk's file if
    /// recording stopped because the app was backgrounded.
    private var finishingActivity: BackgroundActivity?

    override init() {
        super.init()
        recorder.onChunkStarted = { [weak self] index in
            self?.currentChunkIndex = index
        }
        recorder.onChunkFinished = { [weak self] chunk in
            self?.handleFinishedChunk(chunk)
        }
        recorder.onFailure = { [weak self] message in
            guard let self, self.isRecording else { return }
            self.recordingError = message
            self.stopRecording()
        }
        recorder.onStopped = { [weak self] in
            self?.isFinishing = false
            self?.finishingActivity?.end()
            self?.finishingActivity = nil
        }
        observeInterruptions()
    }

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

            // Late frames are dropped rather than queued so a slow encoder
            // can't back up into the camera's buffer pool.
            self.videoDataOutput.alwaysDiscardsLateVideoFrames = true
            self.videoDataOutput.setSampleBufferDelegate(self.recorder, queue: self.recorder.queue)
            if self.captureSession.canAddOutput(self.videoDataOutput) {
                self.captureSession.addOutput(self.videoDataOutput)
            }
            self.audioDataOutput.setSampleBufferDelegate(self.recorder, queue: self.recorder.queue)
            if self.captureSession.canAddOutput(self.audioDataOutput) {
                self.captureSession.addOutput(self.audioDataOutput)
            }
            self.configureVideoConnection(mirrored: useFront)

            self.captureSession.commitConfiguration()
            self.captureSession.startRunning()
            Task { @MainActor in
                self.currentVideoDevice = videoDevice
            }
        }
    }

    /// Applies orientation, stabilization and mirroring to the video output's
    /// connection and hands the recorder matching encoder settings. The
    /// connection is rebuilt whenever the video input changes, so this must
    /// run after every camera flip too.
    nonisolated private func configureVideoConnection(mirrored: Bool) {
        if let connection = videoDataOutput.connection(with: .video) {
            // Rotating here (not with a track transform) makes the frames
            // themselves upright, so every player shows them the right way up.
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
        }
        let codec: AVVideoCodecType = videoDataOutput.availableVideoCodecTypesForAssetWriter(writingTo: .mp4).contains(.hevc) ? .hevc : .h264
        let videoSettings = videoDataOutput.recommendedVideoSettings(forVideoCodecType: codec, assetWriterOutputFileType: .mp4)
        let audioSettings = audioDataOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mp4)
        recorder.updateSettings(video: videoSettings, audio: audioSettings)
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

    /// A phone call, Siri, or another app taking the camera stops the flow
    /// of frames. End the recording so the chunk so far is finished properly
    /// rather than left open.
    private func observeInterruptions() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: captureSession, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRecording else { return }
                self.recordingError = "Recording stopped because the camera was interrupted."
                self.stopRecording()
            }
        }
        center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: captureSession, queue: .main) { [weak self] notification in
            let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            MainActor.assumeIsolated {
                guard let self, self.isRecording else { return }
                self.recordingError = error?.localizedDescription ?? "The camera stopped recording unexpectedly."
                self.stopRecording()
            }
        }
    }

    func startRecording(chunkDuration: TimeInterval, outputDirectory: URL) {
        guard !isRecording, !isFinishing else { return }
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

        recorder.start(outputDirectory: outputDirectory, chunkDuration: chunkDuration)
    }

    /// Ends the current chunk immediately and hands it to the upload queue,
    /// without waiting for the configured chunk duration to elapse. The next
    /// chunk starts on the very next frame.
    func cutChunkNow() {
        guard isRecording else { return }
        recorder.cutNow()
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        recordingTimer?.invalidate()
        recordingTimer = nil
        isFinishing = true
        finishingActivity = BackgroundActivity(name: "Finish recording")
        recorder.stop()
    }

    private func handleFinishedChunk(_ chunk: RecordedChunk) {
        if let error = chunk.errorDescription {
            // Don't hand on a file that wasn't finished: it has no index and
            // won't play. Earlier chunks are unaffected.
            if recordingError == nil { recordingError = error }
            return
        }
        onChunkCompleted?(VideoChunk(index: chunk.index, localURL: chunk.url, duration: chunk.duration, fileSize: chunk.fileSize))
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
