import SwiftUI
import CoreLocation

struct RecordingView: View {
    @Environment(CameraManager.self) var cameraManager
    @Environment(GoogleAuthManager.self) var authManager
    @Environment(LocationManager.self) var locationManager
    @Environment(UploadQueueManager.self) var uploadManager
    @Environment(DriveStorageManager.self) var driveStorageManager
    @Environment(SessionStore.self) var sessionStore
    @Environment(EmailQueueManager.self) var emailQueueManager
    @Environment(\.openURL) private var openURL
    
    /// Opens the Settings tab at the setting a readiness pill stands for.
    var openSettings: (SettingsSection) -> Void = { _ in }
    
    @AppStorage("emailAlertsEnabled") private var emailAlertsEnabled: Bool = true
    @AppStorage("emailRecipients") private var emailRecipients: String = ""
    @AppStorage("locationEnabled") private var locationEnabled: Bool = true
    @AppStorage("chunkDuration") private var chunkDuration: Double = 30
    @State private var showLowStorageConfirm = false
    @State private var deviceFreeBytes: Int64?
    @State private var showOutOfStorageAlert = false
    @State private var storageEmailSentForSessionId: String?
    @AppStorage("hideSendClipTip") private var hideSendClipTip = false
    @State private var sendClipTipDismissed = false
    @State private var sendClipTipDontShowAgain = false
    
    private var recipientCount: Int {
        guard emailAlertsEnabled else { return 0 }
        return EmailSettings.parseRecipients(emailRecipients).count
    }
    
    private var liveSession: RecordingSession? {
        guard let session = sessionStore.currentSession, session.isActive else { return nil }
        return session
    }
    
    private var liveEmailJob: EmailJob? {
        guard let id = liveSession?.id else { return nil }
        return emailQueueManager.jobs.first { $0.sessionId == id }
    }
    
    private var locationAuthorized: Bool {
        locationManager.authorizationStatus == .authorizedWhenInUse || locationManager.authorizationStatus == .authorizedAlways
    }
    
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            
            if cameraManager.permissionDenied {
                cameraPermissionPlaceholder
            } else {
                CameraPreviewView(session: cameraManager.captureSession)
                    .ignoresSafeArea()
            }
            
            VStack(spacing: 12) {
                topBar
                banners
                Spacer()
                callNotice
                bottomControls
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .background(alignment: .top) {
                LinearGradient(colors: [.black.opacity(0.55), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 160)
                    .ignoresSafeArea(edges: .top)
                    .allowsHitTesting(false)
            }
            .background(alignment: .bottom) {
                LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 260)
                    .ignoresSafeArea(edges: .bottom)
                    .allowsHitTesting(false)
            }
            .animation(.snappy, value: cameraManager.isRecording)
            .animation(.snappy, value: cameraManager.recordingError)
            .animation(.snappy, value: uploadManager.storageExceeded)
            .animation(.snappy, value: isDeviceStorageLow)
            .animation(.snappy, value: cameraManager.isCallRinging)
            .animation(.snappy, value: cameraManager.isMicPaused)
        }
        .task {
            // Local filesystem query only (no network), re-checked so the
            // warning appears if the phone fills up mid-recording.
            while !Task.isCancelled {
                deviceFreeBytes = await DeviceStorage.availableBytes()
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .onAppear {
            cameraManager.setupSession()
            if locationEnabled {
                locationManager.requestPermission()
            }
            Task { await driveStorageManager.refreshIfStale(authManager: authManager) }
        }
        .onChange(of: uploadManager.storageExceeded) { old, exceeded in
            guard exceeded, !old else { return }
            handleStorageExceeded()
        }
        .onChange(of: driveStorageManager.shouldSendLowStorageEmail) { _, shouldSend in
            if shouldSend { sendStorageLowEmail() }
        }
        .alert("Google Drive Storage Full", isPresented: $showOutOfStorageAlert, actions: {
            Button("OK", role: .cancel) { }
        }, message: {
            Text("You're out of Google Drive storage, so new clips can't be uploaded. Free up space in your Drive or upgrade your storage plan, then try recording again.")
        })
        .confirmationDialog("Low Google Drive Storage", isPresented: $showLowStorageConfirm, titleVisibility: .visible) {
            Button("Record Anyway", role: .destructive) {
                startRecording()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(lowStorageMessage)
        }
    }
    
    // MARK: - Top bar
    
    @ViewBuilder
    private var topBar: some View {
        if cameraManager.isRecording {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        PulseIndicator()
                        Text(Formatters.duration(cameraManager.elapsedTime))
                            .font(.system(.headline, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                    }
                    .overlayPill()
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Recording, \(Formatters.duration(cameraManager.elapsedTime))")
                
                    Spacer()
                
                    if let session = liveSession {
                        uploadPill(for: session)
                    }
                }
                // The notification's progress, under the timer where the
                // readiness lines were before recording started.
                if let job = liveEmailJob {
                    emailStatusLine(job)
                }
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        } else {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    readinessPill(
                        systemImage: "externaldrive.fill",
                        text: driveStorageText,
                        color: driveStorageColor,
                        accessibilityLabel: driveStorageAccessibilityLabel,
                        section: .storage
                    )
                    readinessPill(
                        systemImage: "iphone.gen3",
                        text: deviceFreeBytes.map(shortGigabytes) ?? "–",
                        color: isDeviceStorageLow ? Theme.warning : .white,
                        accessibilityLabel: deviceStorageAccessibilityLabel,
                        section: .storage
                    )
                    readinessPill(
                        systemImage: "location.fill",
                        trailingSystemImage: locationWillBeSaved ? "checkmark" : "xmark",
                        // Red only when the setting is on but iOS permission is
                        // missing; switched off on purpose isn't a problem.
                        color: locationWillBeSaved ? .white : (locationEnabled ? Theme.record : Theme.secondaryText),
                        accessibilityLabel: locationWillBeSaved ? "Location will be saved" : (locationEnabled ? "Location permission is off" : "Location won't be saved"),
                        section: .location
                    )
                }
                VStack(spacing: 2) {
                    Text("Recording in \(Int(chunkDuration))-second clips")
                        .foregroundStyle(Theme.secondaryText)
                    Text(recipientCount > 0 ? "Ready to email \(recipientCount) contact\(recipientCount == 1 ? "" : "s")" : "No contacts to email")
                        // Yellow only when notifications are on with nobody to
                        // send to; switching them off is a choice.
                        .foregroundStyle(recipientCount == 0 && emailAlertsEnabled ? Theme.warning : Theme.secondaryText)
                }
                .font(.footnote.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
    
    private func readinessPill(
        systemImage: String,
        text: String? = nil,
        trailingSystemImage: String? = nil,
        color: Color,
        accessibilityLabel: String,
        section: SettingsSection
    ) -> some View {
        Button {
            openSettings(section)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                if let text {
                    Text(text).monospacedDigit()
                }
                if let trailingSystemImage {
                    Image(systemName: trailingSystemImage)
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .overlayPill()
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens this setting")
    }
    
    private func uploadPill(for session: RecordingSession) -> some View {
        let queued = session.queuedCount
        let color: Color = uploadManager.storageExceeded ? Theme.record : (queued > 1 ? Theme.warning : .white)
        return HStack(spacing: 6) {
            Image(systemName: uploadManager.storageExceeded ? "exclamationmark.icloud.fill" : (queued > 0 ? "arrow.up.circle.fill" : "checkmark.icloud.fill"))
            Text("\(session.uploadedCount)/\(session.totalCount) up")
                .monospacedDigit()
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(color)
        .overlayPill()
        .accessibilityLabel("\(session.uploadedCount) of \(session.totalCount) clips uploaded")
    }
    
    /// Free Drive space as a short "12 GB"; the pill's color carries low and full.
    private var driveStorageText: String {
        switch driveStorageManager.state {
        case .ok, .low:
            return driveStorageManager.availableBytes.map(shortGigabytes) ?? "–"
        case .out: return "0 GB"
        case .unlimited: return "∞"
        case .unavailable: return "–"
        }
    }
    
    private func shortGigabytes(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return gb >= 10 ? "\(Int(gb)) GB" : String(format: "%.1f GB", gb)
    }
    
    private var deviceStorageAccessibilityLabel: String {
        guard let deviceFreeBytes else { return "iPhone storage unknown" }
        let free = shortGigabytes(deviceFreeBytes)
        return isDeviceStorageLow ? "iPhone storage is low, \(free) free" : "iPhone, \(free) free"
    }
    
    private var locationWillBeSaved: Bool {
        locationEnabled && locationAuthorized
    }
    
    private var driveStorageAccessibilityLabel: String {
        switch driveStorageManager.state {
        case .ok: return "Google Drive, \(driveStorageText) free"
        case .low: return "Google Drive is low, \(driveStorageText) free"
        case .out: return "Google Drive is full"
        case .unlimited: return "Google Drive, unlimited storage"
        case .unavailable: return "Google Drive storage unknown"
        }
    }
    
    
    private var isDeviceStorageLow: Bool {
        guard let deviceFreeBytes else { return false }
        return DeviceStorage.isLow(availableBytes: deviceFreeBytes, bytesPerSecond: driveStorageManager.bytesPerSecondEstimate)
    }
    
    private var driveStorageColor: Color {
        switch driveStorageManager.state {
        case .low: return Theme.warning
        case .out: return Theme.record
        default: return .white
        }
    }
    
    // MARK: - Banners
    
    @ViewBuilder
    private var banners: some View {
        if let error = cameraManager.recordingError {
            NoticeBanner(
                style: .error,
                systemImage: "video.slash.fill",
                title: "Recording stopped",
                message: "\(error) Clips recorded so far are saved on this phone, and the app will keep trying to upload them.",
                onDismiss: { cameraManager.recordingError = nil }
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        if uploadManager.storageExceeded {
            NoticeBanner(
                style: .warning,
                systemImage: "externaldrive.badge.exclamationmark",
                title: "Google Drive is full",
                message: "Clips are kept on this phone, and the app will try uploading them again once you free up space."
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        if isDeviceStorageLow, let free = deviceFreeBytes {
            let minutes = DriveStorageManager.formatRecordingTime(
                DeviceStorage.recordingSeconds(availableBytes: free, bytesPerSecond: driveStorageManager.bytesPerSecondEstimate)
            )
            NoticeBanner(
                style: .warning,
                systemImage: "iphone.gen3.badge.exclamationmark",
                title: "iPhone storage is low",
                message: "\(DriveStorageManager.formatBytes(free)) free, about \(minutes) of recording. Clips are kept on this phone, so delete old sessions in My Clips to free up space."
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        if uploadManager.publicSharingBlocked && recipientCount > 0 {
            NoticeBanner(
                style: .warning,
                systemImage: "link.badge.plus",
                title: "Contacts can't open your videos",
                message: "Your Google account (likely work or school) doesn't allow public links, so notification emails will link to a private folder. Sign in with a personal Google account to fix this."
            )
            .transition(.move(edge: .top).combined(with: .opacity))
        }
        if !cameraManager.isRecording && locationEnabled && !locationAuthorized && locationManager.authorizationStatus != .notDetermined {
            NoticeBanner(
                style: .info,
                systemImage: "location.slash.fill",
                title: "Location is off",
                message: "Recordings and notification emails won't include where you are.",
                actionTitle: "Turn On in Settings",
                action: openAppSettings
            )
        }
    }
    
    /// Sits low on the screen because the system's call banner covers the top.
    /// The padding clears the send clip button floating above the controls.
    @ViewBuilder
    private var callNotice: some View {
        Group {
            if cameraManager.isRecording && cameraManager.isCallRinging {
                NoticeBanner(
                    style: .warning,
                    systemImage: "phone.arrow.down.left.fill",
                    title: "Answering switches the mic to your call",
                    message: "Video keeps recording without sound until you hang up, as long as you stay in this app."
                )
            } else if cameraManager.isMicPaused {
                NoticeBanner(
                    style: .warning,
                    systemImage: "mic.slash.fill",
                    title: cameraManager.isRecording ? "Recording without sound" : "Mic is in use",
                    message: "A call or another app is using the mic. Video still records, and sound comes back when the mic is free."
                )
            }
        }
        .padding(.bottom, 60)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var cameraPermissionPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 44))
                .foregroundStyle(Theme.secondaryText)
            Text("Camera access needed")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("Just Capture needs the camera and microphone to record. You can turn them on in Settings.")
                .font(.subheadline)
                .foregroundStyle(Theme.secondaryText)
                .multilineTextAlignment(.center)
            Button("Open Settings", action: openAppSettings)
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
        }
        .padding(32)
    }
    
    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            openURL(url)
        }
    }
    
    // MARK: - Bottom controls
    
    private var bottomControls: some View {
        VStack(spacing: 18) {
            HStack {
                circleControl(
                    systemImage: cameraManager.isTorchOn ? "flashlight.on.fill" : "flashlight.off.fill",
                    tint: cameraManager.isTorchOn ? .yellow : .white,
                    label: cameraManager.isTorchOn ? "Turn torch off" : "Turn torch on",
                    action: cameraManager.toggleTorch
                )
                .disabled(cameraManager.isUsingFrontCamera || cameraManager.permissionDenied)
                .opacity(cameraManager.isUsingFrontCamera ? 0.4 : 1)
                // Floats above the torch without changing the row's layout.
                .overlay(alignment: .top) {
                    circleControl(
                        systemImage: "paperplane.fill",
                        tint: .white,
                        label: "Send clip now",
                        action: cameraManager.cutChunkNow
                    )
                    .disabled(!cameraManager.isRecording)
                    .opacity(cameraManager.isRecording ? 1 : 0.4)
                    .accessibilityHint(cameraManager.isRecording
                        ? "Ends clip \(cameraManager.currentChunkIndex + 1) early and starts uploading it"
                        : "Available while recording")
                    // Outside the disabled/opacity modifiers so the tip stays
                    // fully visible and tappable when not recording.
                    .overlay(alignment: .bottomLeading) {
                        if showSendClipTip {
                            sendClipTip
                                .fixedSize()
                                .offset(y: -(54 + 6))
                                .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .bottomLeading)))
                        }
                    }
                    .offset(y: -(54 + 14))
                }
                
                Spacer()
                recordButton
                Spacer()
                
                circleControl(
                    systemImage: "arrow.triangle.2.circlepath.camera.fill",
                    tint: .white,
                    label: "Switch camera",
                    action: cameraManager.flipCamera
                )
                .disabled(cameraManager.permissionDenied)
            }
            .padding(.horizontal, 24)
        }
        .padding(.bottom, 20)
    }
    
    // MARK: - Send clip tip
    
    private var showSendClipTip: Bool {
        !hideSendClipTip && !sendClipTipDismissed && !cameraManager.permissionDenied
    }
    
    private var sendClipTip: some View {
        let background = Color.black.opacity(0.8)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Send clip now")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Button(action: dismissSendClipTip) {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.secondaryText)
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Close tip")
                }
                Text("While recording, tap this to end the current clip early and start uploading it right away, instead of waiting for the \(Int(chunkDuration))-second clip to finish.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    sendClipTipDontShowAgain.toggle()
                } label: {
                    Label("Don't show again", systemImage: sendClipTipDontShowAgain ? "checkmark.square.fill" : "square")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(sendClipTipDontShowAgain ? Theme.accent : .white)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(sendClipTipDontShowAgain ? .isSelected : [])
            }
            .padding(12)
            .frame(width: 240, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            
            // Points down at the center of the 54pt send button.
            TipArrow()
                .fill(background)
                .frame(width: 16, height: 8)
                .padding(.leading, 27 - 8)
        }
        .foregroundStyle(.white)
    }
    
    private func dismissSendClipTip() {
        if sendClipTipDontShowAgain {
            hideSendClipTip = true
        }
        withAnimation(.snappy) {
            sendClipTipDismissed = true
        }
    }
    
    private func emailStatusLine(_ job: EmailJob) -> some View {
        let (text, icon, color): (String, String, Color) = {
            switch job.status {
            case .sent: return ("Notification sent to \(job.recipients.count)", "checkmark.circle.fill", Theme.success)
            case .sending: return ("Sending notification…", "paperplane.fill", .white)
            case .pending: return (job.attempts == 0 ? "Notification queued" : "Notification retrying (no connection?)", "clock.fill", Theme.warning)
            case .failed: return ("Notification failed — retry from My Clips", "exclamationmark.triangle.fill", Theme.record)
            }
        }()
        return Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .overlayPill()
    }
    
    private func circleControl(systemImage: String, tint: Color, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 54, height: 54)
        }
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
    
    private var recordButton: some View {
        Button(action: toggleRecording) {
            ZStack {
                Circle()
                    .strokeBorder(.white, lineWidth: 4)
                    .frame(width: 82, height: 82)
                RoundedRectangle(cornerRadius: cameraManager.isRecording ? 8 : 34, style: .continuous)
                    .fill(Theme.record)
                    .frame(
                        width: cameraManager.isRecording ? 32 : 68,
                        height: cameraManager.isRecording ? 32 : 68
                    )
            }
            .opacity(cameraManager.isFinishing ? 0.5 : 1)
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: cameraManager.isRecording)
        .disabled(cameraManager.isFinishing || cameraManager.permissionDenied)
        .sensoryFeedback(.impact(weight: .heavy), trigger: cameraManager.isRecording)
        .accessibilityLabel(cameraManager.isRecording ? "Stop recording" : "Start recording")
    }
    
    private var lowStorageMessage: String {
        var message = "Your Google Drive storage is running low."
        if let available = driveStorageManager.availableBytes {
            message += " \(DriveStorageManager.formatBytes(available)) left"
            if let seconds = driveStorageManager.estimatedRecordingSeconds {
                message += " — about \(DriveStorageManager.formatRecordingTime(seconds)) of recording"
            }
            message += "."
        }
        message += " If it fills up mid-recording, new clips can't be uploaded."
        return message
    }
    
    private func toggleRecording() {
        if cameraManager.isRecording {
            // ContentView finalizes the session when isRecording flips.
            cameraManager.stopRecording()
        } else {
            attemptStartRecording()
        }
    }
    
    private func attemptStartRecording() {
        Task { @MainActor in
            await driveStorageManager.refresh(authManager: authManager)
            switch driveStorageManager.state {
            case .out:
                showOutOfStorageAlert = true
            case .low:
                showLowStorageConfirm = true
            case .ok, .unlimited, .unavailable:
                startRecording()
            }
        }
    }
    
    private func handleStorageExceeded() {
        // Show "Drive full" now rather than the last free-space figure.
        driveStorageManager.markOutOfStorage()
        sendStorageEmailOnce(
            subject: EmailSettings.storageSubject(name: authManager.userName, email: authManager.userEmail),
            note: EmailSettings.storageFullNote
        )
    }

    /// Gmail shares the account's storage with Drive, so a full account may not
    /// be able to send at all. This warning goes out while it still can.
    private func sendStorageLowEmail() {
        sendStorageEmailOnce(
            subject: EmailSettings.storageSubject(name: authManager.userName, email: authManager.userEmail),
            note: EmailSettings.storageLowNote
        )
    }

    /// At most one storage email per recording, low or full.
    private func sendStorageEmailOnce(subject: String, note: String) {
        guard let session = sessionStore.currentSession, session.isActive,
              storageEmailSentForSessionId != session.id else { return }
        storageEmailSentForSessionId = session.id
        let settings = EmailSettings.current
        guard settings.canSend else { return }
        enqueueEmail(
            for: session,
            subject: subject,
            note: note,
            settings: settings
        )
    }
     
    private func startRecording() {
            // The previous recording's last chunk is still being written.
            guard !cameraManager.isRecording, !cameraManager.isFinishing else { return }
            uploadManager.storageExceeded = false
            let duration = TimeInterval(chunkDuration)
            let session = RecordingSession(chunkDuration: duration)
            sessionStore.add(session)
            
            let savesLocation = locationEnabled
            cameraManager.onChunkCompleted = { chunk in
                session.chunks.append(chunk)
                // Saved before the upload below, which also sends the trail to Drive.
                if savesLocation, EmailSettings.current.locationEnabled, locationManager.isAuthorized {
                    session.addClipToTrail(locationManager.lastKnownFix, clipFileName: chunk.fileName)
                }
                sessionStore.save()
                uploadManager.enqueue(chunk: chunk, session: session, authManager: authManager)
            }
            
            if savesLocation {
                locationManager.startTracking { location in
                    session.addStartToTrail(location)
                    sessionStore.save()
                    Task { await uploadManager.updateLocationFile(session: session, authManager: authManager) }
                }
                Task { await saveLocation(to: session) }
            }

            let outputDir = session.outputDirectory()
            
            cameraManager.startRecording(chunkDuration: duration, outputDirectory: outputDir)
            
            // Create the Drive folder right away so its link is ready for the
            // alert email and the playlist can be built.
            uploadManager.prepareFolder(for: session, authManager: authManager)

            // Queue the emergency alert email (it will be retried automatically
            // by EmailQueueManager if the connection is poor). The first send
            // waits briefly for the folder above so the email carries the link,
            // but goes out without it rather than stall on a bad network.
            enqueueAlertEmailIfNeeded(for: session)

            // Already low, so nothing will change and trigger the warning.
            if driveStorageManager.shouldSendLowStorageEmail { sendStorageLowEmail() }
    }

    /// Records where the session started, whether or not anyone is notified.
    /// A recent fix is saved right away in case GPS never answers, then replaced
    /// by one taken after recording started. The rest of the route is the trail.
    private func saveLocation(to session: RecordingSession) async {
        let deadline = Date().addingTimeInterval(30)
        var savedFixDate: Date?
        while Date() < deadline {
            if let location = locationManager.freshLocation() {
                let address = locationManager.address(for: location)
                if savedFixDate != location.timestamp || (session.locationAddress == nil && address != nil) {
                    savedFixDate = location.timestamp
                    session.latitude = location.coordinate.latitude
                    session.longitude = location.coordinate.longitude
                    session.locationAddress = address
                    session.locationDate = location.timestamp
                    sessionStore.save()
                    await uploadManager.updateLocationFile(session: session, authManager: authManager)
                }
                if location.timestamp >= session.startDate && address != nil { return }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private func enqueueAlertEmailIfNeeded(for session: RecordingSession) {
        let settings = EmailSettings.current
        guard settings.canSend else {
            print("Email alerts are disabled or have no recipients.")
            return
        }
        enqueueEmail(for: session, subject: settings.subject, note: settings.note, settings: settings)
    }
    
    private func enqueueEmail(for session: RecordingSession, subject: String, note: String, settings: EmailSettings) {
        uploadManager.requestLinkSharing(for: session, authManager: authManager)
        emailQueueManager.enqueue(
            sessionId: session.id,
            recipients: settings.recipients,
            subject: subject,
            bodyNote: note,
            includeTime: settings.includeTime,
            includeLocation: settings.locationEnabled,
            authManager: authManager
        )
    }
}

/// Downward-pointing triangle under the send clip tip.
private struct TipArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
