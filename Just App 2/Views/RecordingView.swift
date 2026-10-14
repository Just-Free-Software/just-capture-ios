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
    
    @AppStorage("emailAlertsEnabled") private var emailAlertsEnabled: Bool = true
    @AppStorage("emailRecipients") private var emailRecipients: String = ""
    @AppStorage("chunkDuration") private var chunkDuration: Double = 30
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showLowStorageConfirm = false
    @State private var showOutOfStorageAlert = false
    @State private var showQuotaExceededAlert = false
    @State private var showUploadsResumedAlert = false
    @State private var storageEmailSentForSessionId: String?
    
    private var recipientCount: Int {
        guard emailAlertsEnabled else { return 0 }
        let emails = emailRecipients
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return emails.count
    }
    
    private var emailNotificationText: String {
        let count = recipientCount
        if count == 0 {
            return "Email notifications not set up"
        } else if count == 1 {
            return "Recording will send emails to 1 person"
        } else {
            return "Recording will send emails to \(count) people"
        }
    }
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            CameraPreviewView(session: cameraManager.captureSession)
                .ignoresSafeArea()
            
            VStack {
                // Top Overlay
                ZStack(alignment: .top) {
                    LinearGradient(gradient: Gradient(colors: [.black.opacity(0.6), .clear]), startPoint: .top, endPoint: .bottom)
                        .frame(height: 100)
                        .ignoresSafeArea(edges: .top)
                    
                    HStack {
                        if cameraManager.isRecording {
                            HStack(spacing: 8) {
                                PulseIndicator()
                                Text("REC")
                                    .font(.headline.bold())
                                    .foregroundColor(.red)
                                Text(formatElapsedTime(cameraManager.elapsedTime))
                                    .font(.system(.headline, design: .monospaced))
                                    .foregroundColor(.white)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.ultraThinMaterial)
                            .clipShape(Capsule())
                            
                            Spacer()
                            
                            HStack(spacing: 8) {
                                Button {
                                    cameraManager.cutChunkNow()
                                } label: {
                                    Image(systemName: "scissors")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundColor(.white)
                                        .frame(width: 36, height: 36)
                                        .background(.ultraThinMaterial)
                                        .clipShape(Circle())
                                }
                                
                                Text("Chunk \(cameraManager.currentChunkIndex + 1)")
                                    .font(.subheadline.bold())
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 8)
                                    .background(.ultraThinMaterial)
                                    .clipShape(Capsule())
                            }
                        } else {
                            Spacer()
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                }
                
                Spacer()
                
                // Bottom Overlay
                VStack(spacing: 16) {
                    if !cameraManager.isRecording {
                        HStack(spacing: 6) {
                            Image(systemName: recipientCount > 0 ? "envelope.fill" : "envelope")
                                .font(.subheadline)
                            Text(emailNotificationText)
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                    }
                    
                    HStack(spacing: 40) {
                        Button {
                            cameraManager.toggleTorch()
                        } label: {
                            Image(systemName: cameraManager.isTorchOn ? "bolt.fill" : "bolt.slash.fill")
                                .font(.title2)
                                .foregroundColor(cameraManager.isTorchOn ? .yellow : .white)
                                .frame(width: 50, height: 50)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                        .disabled(cameraManager.isUsingFrontCamera)
                        .opacity(cameraManager.isUsingFrontCamera ? 0.5 : 1.0)
                        
                        Button {
                            toggleRecording()
                        } label: {
                            ZStack {
                                Circle()
                                    .stroke(Color.white, lineWidth: 3)
                                    .frame(width: 76, height: 76)
                                
                                if cameraManager.isRecording {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.red)
                                        .frame(width: 32, height: 32)
                                } else {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 64, height: 64)
                                }
                            }
                        }
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: cameraManager.isRecording)
                        
                        Button {
                            cameraManager.flipCamera()
                        } label: {
                            Image(systemName: "camera.rotate.fill")
                                .font(.title2)
                                .foregroundColor(.white)
                                .frame(width: 50, height: 50)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                    }
                    .padding(.bottom, 30)
                }
                .padding(.horizontal, 20)
                .background(
                    LinearGradient(gradient: Gradient(colors: [.clear, .black.opacity(0.8)]), startPoint: .top, endPoint: .bottom)
                        .ignoresSafeArea(edges: .bottom)
                )
            }
        }
        .onAppear {
            cameraManager.setupSession()
            locationManager.requestPermission()
            Task { await driveStorageManager.refreshIfStale(authManager: authManager) }
        }
        .onChange(of: uploadManager.storageExceeded) { old, exceeded in
            guard exceeded, !old else { return }
            handleStorageExceeded()
        }
        .onChange(of: uploadManager.storageExceeded) { old, resumed in
            guard old, !resumed else { return }
            showUploadsResumedAlert = true
        }
        .alert("Error", isPresented: $showError, actions: {
            Button("OK", role: .cancel) { }
        }, message: {
            Text(errorMessage)
        })
        .alert("Google Drive Storage Full", isPresented: $showOutOfStorageAlert, actions: {
            Button("OK", role: .cancel) { }
        }, message: {
            Text("You're out of Google Drive storage, so new clips can't be uploaded. Free up space in your Drive or upgrade your storage plan, then try recording again.")
        })
        .alert("Uploads Paused — Google Drive Storage Full", isPresented: $showQuotaExceededAlert, actions: {
            Button("OK", role: .cancel) { }
        }, message: {
            Text("New clips can't be uploaded because your Google Drive storage is full. Recording continues on this device, and an alert email has been sent. Uploads will resume automatically as soon as space is freed.")
        })
        .alert("Uploads Resumed", isPresented: $showUploadsResumedAlert, actions: {
            Button("OK", role: .cancel) { }
        }, message: {
            Text("Google Drive storage is available again. Queued clips are uploading.")
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
            cameraManager.stopRecording()
            if let session = sessionStore.currentSession, session.isActive {
                session.isActive = false
                sessionStore.save()
            }
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
        showQuotaExceededAlert = true
        if let session = sessionStore.currentSession, session.isActive,
           storageEmailSentForSessionId != session.id {
            storageEmailSentForSessionId = session.id
            enqueueStorageFullEmailIfNeeded(for: session)
        }
    }
    
    private func enqueueStorageFullEmailIfNeeded(for session: RecordingSession) {
        let alertsEnabled = (UserDefaults.standard.object(forKey: "emailAlertsEnabled") as? Bool) ?? true
        guard alertsEnabled else { return }
        
        let emails = UserDefaults.standard.string(forKey: "emailRecipients")?
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        guard !emails.isEmpty else { return }
        
        let baseSubject = UserDefaults.standard.string(forKey: "emailSubject")?
            .trimmingCharacters(in: .whitespaces)
        let subject = "Storage Full: \(baseSubject ?? "Alert! [your_name] is broadcasting")"
        
        let includeTime = (UserDefaults.standard.object(forKey: "includeTimeInEmail") as? Bool) ?? true
        let includeLocation = (UserDefaults.standard.object(forKey: "includeLocationInEmail") as? Bool) ?? true
        let address = includeLocation ? locationManager.currentAddress : nil
        let lat = includeLocation ? locationManager.currentLocation?.coordinate.latitude : nil
        let lon = includeLocation ? locationManager.currentLocation?.coordinate.longitude : nil
        
        let defaultNote = "Google Drive storage is full, so new clips cannot be uploaded right now. Recording is still in progress and the app will keep retrying — clips will upload automatically as soon as storage is freed."
        let note = UserDefaults.standard.string(forKey: "storageFullEmailNote")?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let bodyNote = note.isEmpty ? defaultNote : note
        
        emailQueueManager.enqueue(
            sessionId: session.id,
            recipients: emails,
            subject: subject,
            bodyNote: bodyNote,
            includeTime: includeTime,
            address: address,
            latitude: lat,
            longitude: lon,
            authManager: authManager
        )
    }
     
    private func startRecording() {
            uploadManager.storageExceeded = false
            let duration = TimeInterval(chunkDuration)
            let session = RecordingSession(chunkDuration: duration)
            sessionStore.add(session)
            
            cameraManager.onChunkCompleted = { chunk in
                session.chunks.append(chunk)
                sessionStore.save()
                uploadManager.enqueue(chunk: chunk, session: session, authManager: authManager)
            }
            
            locationManager.requestLocation()
            
            let outputDir = session.outputDirectory()
            
            cameraManager.startRecording(chunkDuration: duration, outputDirectory: outputDir)
            
            // Queue the emergency alert email (it will be retried automatically
            // by EmailQueueManager if the connection is poor). The Drive folder
            // link is resolved at send time, so the email still gets out ASAP
            // even if folder creation hasn't completed yet.
            enqueueAlertEmailIfNeeded(for: session)
            
            // Ensure the Drive folder is created early so the playlist can be
            // built and the folder link is ready for the email's next send
            // attempt. Retried with backoff; failures are non-fatal — the first
            // chunk upload will also retry folder creation.
            Task {
                var attempt = 0
                while true {
                    do {
                        let token = try await authManager.validAccessToken()
                        let driveResult = try await GoogleDriveService.createFolder(name: session.folderName, accessToken: token)
                        session.driveFolderId = driveResult.folderId
                        session.driveFolderLink = driveResult.webViewLink
                        sessionStore.save()
                        return
                    } catch {
                        attempt += 1
                        if attempt >= RetryPolicy.maxAttempts {
                            print("Failed to create Drive folder after \(attempt) attempts: \(error.localizedDescription)")
                            return
                        }
                        let delay = RetryPolicy.delay(forAttempt: attempt)
                        print("Drive folder attempt \(attempt) failed, retrying in \(Int(delay))s: \(error.localizedDescription)")
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                }
            }
    }
    
    private func enqueueAlertEmailIfNeeded(for session: RecordingSession) {
        let alertsEnabled = (UserDefaults.standard.object(forKey: "emailAlertsEnabled") as? Bool) ?? true
        guard alertsEnabled else {
            print("ℹ️ Email alerts are disabled in settings.")
            return
        }
        
        let emails = UserDefaults.standard.string(forKey: "emailRecipients")?
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty } ?? []
        guard !emails.isEmpty else {
            print("⚠️ Email alerts enabled but no recipient emails are set.")
            return
        }
        
        let customSubject = UserDefaults.standard.string(forKey: "emailSubject")?.trimmingCharacters(in: .whitespaces)
        let subject: String
        if let customSubject = customSubject, !customSubject.isEmpty, customSubject != "🚨 Emergency Recording Alert" {
            subject = customSubject
        } else {
            subject = "Alert! [your_name] is broadcasting"
        }
        let note = UserDefaults.standard.string(forKey: "emailNote") ?? ""
        let includeTime = (UserDefaults.standard.object(forKey: "includeTimeInEmail") as? Bool) ?? true
        let includeLocation = (UserDefaults.standard.object(forKey: "includeLocationInEmail") as? Bool) ?? true
        let address = includeLocation ? locationManager.currentAddress : nil
        let lat = includeLocation ? locationManager.currentLocation?.coordinate.latitude : nil
        let lon = includeLocation ? locationManager.currentLocation?.coordinate.longitude : nil
        
        emailQueueManager.enqueue(
            sessionId: session.id,
            recipients: emails,
            subject: subject,
            bodyNote: note,
            includeTime: includeTime,
            address: address,
            latitude: lat,
            longitude: lon,
            authManager: authManager
        )
    }
    
    private func formatElapsedTime(_ time: TimeInterval) -> String {
        let hours = Int(time) / 3600
        let minutes = Int(time) / 60 % 60
        let seconds = Int(time) % 60
        if hours > 0 {
            return String(format: "%02i:%02i:%02i", hours, minutes, seconds)
        } else {
            return String(format: "%02i:%02i", minutes, seconds)
        }
    }
}
