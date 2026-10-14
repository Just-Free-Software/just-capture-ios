@preconcurrency import AVFoundation
import CoreMedia
import Observation

@Observable
class CameraManager: NSObject {
    let captureSession = AVCaptureSession()
    private(set) var isRecording: Bool = false
    private(set) var currentChunkIndex: Int = 0
    private(set) var elapsedTime: TimeInterval = 0
    private(set) var isTorchOn: Bool = false
    private(set) var isUsingFrontCamera: Bool = false
    var onChunkCompleted: ((VideoChunk) -> Void)?
    
    private let movieFileOutput = AVCaptureMovieFileOutput()
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
        sessionQueue.async {
            self.captureSession.beginConfiguration()
            self.captureSession.sessionPreset = .hd1920x1080
            
            let videoDevice = self.getDevice(for: self.isUsingFrontCamera ? .front : .back)
            self.currentVideoDevice = videoDevice
            
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
                if let connection = self.movieFileOutput.connection(with: .video) {
                    if connection.isVideoOrientationSupported {
                        connection.videoOrientation = .portrait
                    }
                    if connection.isVideoStabilizationSupported {
                        connection.preferredVideoStabilizationMode = .auto
                    }
                    if self.movieFileOutput.availableVideoCodecTypes.contains(.hevc) {
                        self.movieFileOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection)
                    }
                }
            }
            
            self.captureSession.commitConfiguration()
            self.captureSession.startRunning()
        }
    }
    
    private func getDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
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
        guard !isRecording else { return }
        self.chunkDuration = chunkDuration
        self.outputDirectory = outputDirectory
        self.currentChunkIndex = 0
        self.elapsedTime = 0
        self.isRecording = true
        self.recordingStartDate = Date()
        
        Task { @MainActor in
            self.recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                guard let self = self, let startDate = self.recordingStartDate else { return }
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
            Task { @MainActor in
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
        self.isRecording = false
        Task { @MainActor in
            self.recordingTimer?.invalidate()
            self.recordingTimer = nil
            self.chunkTimer?.invalidate()
            self.chunkTimer = nil
            self.currentChunkStartDate = nil
        }
        
        movieFileOutput.stopRecording()
    }
    
    func toggleTorch() {
        guard let device = currentVideoDevice, device.hasTorch else { return }
        sessionQueue.async {
            do {
                try device.lockForConfiguration()
                let newTorchMode = !self.isTorchOn
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
        sessionQueue.async {
            self.captureSession.beginConfiguration()
            if let currentInput = self.captureSession.inputs.first(where: { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.video) == true }) {
                self.captureSession.removeInput(currentInput)
            }
            let newDevice = self.getDevice(for: self.isUsingFrontCamera ? .front : .back)
            self.currentVideoDevice = newDevice
            if let newDevice = newDevice, let newInput = try? AVCaptureDeviceInput(device: newDevice) {
                if self.captureSession.canAddInput(newInput) {
                    self.captureSession.addInput(newInput)
                }
            }
            self.captureSession.commitConfiguration()
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
        var isSuccessfullyWritten = true
        if let err = error as NSError? {
            if let finished = err.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool {
                isSuccessfullyWritten = finished
            } else {
                isSuccessfullyWritten = false
            }
        }
        
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: outputFileURL.path)[.size] as? Int64) ?? 0
        
        Task { @MainActor in
            let chunkIndex = self.currentChunkIndex
            
            // Only emit chunks that were actually written with data. When the app is
            // backgrounded, iOS suspends the capture session and the delegate fires
            // with empty/truncated files — emitting those would spam the upload queue
            // with 0-byte chunks.
            if isSuccessfullyWritten && fileSize > 0 {
                let actualDuration: TimeInterval
                if let chunkStart = self.currentChunkStartDate {
                    actualDuration = max(Date().timeIntervalSince(chunkStart), 0.01)
                } else {
                    actualDuration = self.chunkDuration
                }
                self.onChunkCompleted?(VideoChunk(index: chunkIndex, localURL: outputFileURL, duration: actualDuration, fileSize: fileSize))
            }
            
            if self.isRecording {
                self.currentChunkIndex += 1
                self.startNextChunkSegment()
            }
        }
    }
}
