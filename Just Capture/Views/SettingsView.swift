import SwiftUI

struct SettingsView: View {
    @Environment(GoogleAuthManager.self) var authManager
    @Environment(DriveStorageManager.self) var driveStorageManager
    @Environment(UploadQueueManager.self) var uploadManager

    @AppStorage("chunkDuration") private var chunkDuration: Double = 30
    @AppStorage("emailRecipients") private var emailRecipients: String = ""
    @AppStorage("emailSubject") private var emailSubject: String = ""
    @AppStorage("emailNote") private var emailNote: String = ""
    @AppStorage("emailAlertsEnabled") private var emailAlertsEnabled: Bool = true
    @AppStorage("includeTimeInEmail") private var includeTimeInEmail: Bool = true
    @AppStorage("includeLocationInEmail") private var includeLocationInEmail: Bool = true
    @FocusState private var focusedField: Field?

    @State private var testEmailState: TestEmailState = .idle
    @State private var isRefreshingStorage = false
    @State private var deviceFreeBytes: Int64?
    @State private var showSignOutConfirm = false

    private enum Field: Hashable {
        case recipients, subject, note
    }

    private enum TestEmailState: Equatable {
        case idle, sending, sent, failed(String)
    }

    private var recipients: [String] {
        EmailSettings.parseRecipients(emailRecipients)
    }

    private var invalidRecipients: [String] {
        recipients.filter { !EmailSettings.isValidEmail($0) }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                recordingSection
                emailSection
                if emailAlertsEnabled {
                    emailContentSection
                }
                storageSection

                Section {
                    LabeledContent("Version", value: appVersion)
                } header: {
                    Text("About")
                } footer: {
                    Text("Just Capture records in short clips and tries to upload each one to your Google Drive as it goes.")
                }
            }
            .navigationTitle("Settings")
            .scrollContentBackground(.hidden)
            .background(Theme.background.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .tint(Theme.accent)
            .animation(.default, value: emailAlertsEnabled)
            .onAppear {
                deviceFreeBytes = DeviceStorage.availableBytes()
                if EmailSettings.isDefaultSubject(emailSubject) {
                    emailSubject = EmailSettings.defaultSubject
                }
                if authManager.isSignedIn {
                    Task { await driveStorageManager.refreshIfStale(authManager: authManager) }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focusedField = nil }
                }
            }
            .confirmationDialog("Sign out of Google?", isPresented: $showSignOutConfirm, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) { authManager.signOut() }
            } message: {
                Text("Recording stops, and uploads and notification emails pause until you sign back in.")
            }
        }
    }

    // MARK: - Sections

    private var accountSection: some View {
        Section {
            HStack(spacing: 14) {
                AsyncImage(url: authManager.userPhotoURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Text(initial)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Theme.brandGradient)
                }
                .frame(width: 44, height: 44)
                .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(authManager.userName ?? "Google Account")
                        .font(.body.weight(.medium))
                    if let email = authManager.userEmail {
                        Text(email)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)

            Button("Sign Out", role: .destructive) {
                showSignOutConfirm = true
            }
        } header: {
            Text("Account")
        } footer: {
            if uploadManager.publicSharingBlocked {
                Label("This account doesn't allow public links, so the people you notify won't be able to open your videos. This is usually a work or school account policy. Sign in with a personal Google account instead.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.warning)
            }
        }
    }

    private var initial: String {
        String((authManager.userName ?? authManager.userEmail ?? "?").prefix(1)).uppercased()
    }

    private var recordingSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Text("Clip length")
                Picker("Clip length", selection: $chunkDuration) {
                    Text("10 sec").tag(10.0)
                    Text("30 sec").tag(30.0)
                    Text("60 sec").tag(60.0)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.vertical, 4)

            Toggle("Save location", isOn: $includeLocationInEmail)
        } header: {
            Text("Recording")
        } footer: {
            Text("Each clip starts uploading as soon as it ends. Shorter clips get footage off your phone sooner; longer clips use less data. Your location is saved when you start recording and at the end of each clip, on this phone and in Google Drive. Where you started is added to notification emails.")
        }
    }

    private var emailSection: some View {
        Section {
            Toggle("Email notifications", isOn: $emailAlertsEnabled)

            if emailAlertsEnabled {
                TextField("Recipients", text: $emailRecipients, prompt: Text(verbatim: "name@example.com, …"), axis: .vertical)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focusedField, equals: .recipients)

                Button {
                    sendTestEmail()
                } label: {
                    HStack {
                        Label("Send Test Email", systemImage: "paperplane")
                        Spacer()
                        testEmailStatus
                    }
                }
                .disabled(recipients.isEmpty || !invalidRecipients.isEmpty || testEmailState == .sending)
            }
        } header: {
            Text("Email Notifications")
        } footer: {
            if emailAlertsEnabled {
                if !invalidRecipients.isEmpty {
                    Text("Check \(invalidRecipients.joined(separator: ", ")) — \(invalidRecipients.count == 1 ? "it doesn't" : "they don't") look like an email address.")
                        .foregroundStyle(Theme.record)
                } else if recipients.isEmpty {
                    Text("Add at least one person to email when you start recording. Separate addresses with commas.")
                        .foregroundStyle(Theme.warning)
                } else {
                    Text("When you start recording, \(recipients.count == 1 ? "1 person gets" : "\(recipients.count) people get") an email with a link to the live recording in your Google Drive.")
                }
            } else {
                Text("No one will be notified when you start recording.")
            }
        }
    }

    @ViewBuilder
    private var testEmailStatus: some View {
        switch testEmailState {
        case .idle:
            EmptyView()
        case .sending:
            ProgressView()
        case .sent:
            Label("Sent", systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.success)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.record)
                .lineLimit(1)
        }
    }

    private var emailContentSection: some View {
        Section {
            TextField("Subject", text: $emailSubject, prompt: Text(EmailSettings.defaultSubject))
                .focused($focusedField, equals: .subject)
            TextField("Message (optional)", text: $emailNote, axis: .vertical)
                .lineLimit(2...5)
                .focused($focusedField, equals: .note)
            Toggle("Include start time", isOn: $includeTimeInEmail)
        } header: {
            Text("Email Content")
        } footer: {
            Text("\(EmailSettings.nameToken) in the subject is replaced with your name. A second email is sent if your Google Drive runs out of space mid-recording.")
        }
    }

    private var storageSection: some View {
        Section {
            LabeledContent("Google Drive") {
                driveStorageStatus
            }
            if let quota = driveStorageManager.quota, !quota.isUnlimited, let limit = quota.limit, limit > 0 {
                Gauge(value: Double(quota.usage), in: 0...Double(limit)) {
                    EmptyView()
                }
                .gaugeStyle(.linearCapacity)
                .tint(driveStorageManager.state == .ok ? Theme.accent : Theme.warning)
            }
            Button {
                isRefreshingStorage = true
                deviceFreeBytes = DeviceStorage.availableBytes()
                Task {
                    await driveStorageManager.refresh(authManager: authManager)
                    isRefreshingStorage = false
                }
            } label: {
                HStack {
                    Text("Refresh Storage")
                    Spacer()
                    if isRefreshingStorage { ProgressView() }
                }
            }
            .disabled(isRefreshingStorage)
            if let deviceFreeBytes {
                LabeledContent("This iPhone") {
                    Text("\(DriveStorageManager.formatBytes(deviceFreeBytes)) free")
                        .foregroundStyle(isDeviceStorageLow ? Theme.warning : .secondary)
                }
            }
        } header: {
            Text("Storage")
        } footer: {
            Text(storageFooter)
        }
    }

    @ViewBuilder
    private var driveStorageStatus: some View {
        switch driveStorageManager.state {
        case .ok, .low:
            if let quota = driveStorageManager.quota, let available = quota.availableBytes {
                Text("\(DriveStorageManager.formatBytes(available)) free")
                    .foregroundStyle(driveStorageManager.state == .low ? Theme.warning : .secondary)
            }
        case .out:
            Text("Full").foregroundStyle(Theme.record)
        case .unlimited:
            Text("Unlimited").foregroundStyle(.secondary)
        case .unavailable:
            Text("Unavailable").foregroundStyle(.secondary)
        }
    }

    private var isDeviceStorageLow: Bool {
        guard let deviceFreeBytes else { return false }
        return DeviceStorage.isLow(availableBytes: deviceFreeBytes, bytesPerSecond: driveStorageManager.bytesPerSecondEstimate)
    }

    private var storageFooter: String {
        var parts: [String] = []
        if let seconds = driveStorageManager.estimatedRecordingSeconds {
            parts.append("Enough space for about \(DriveStorageManager.formatRecordingTime(seconds)) of recording.")
        }
        parts.append("Clips stay on this phone after uploading.")
        if isDeviceStorageLow {
            parts.append("Your iPhone is running low on space; delete old sessions in My Clips to make room for new recordings.")
        }
        parts.append("Clips in Google Drive are never deleted by the app.")
        return parts.joined(separator: " ")
    }

    // MARK: - Actions

    private func sendTestEmail() {
        focusedField = nil
        let settings = EmailSettings.current
        testEmailState = .sending
        Task {
            do {
                let token = try await authManager.validAccessToken()
                try await GmailService.sendEmergencyEmail(
                    to: settings.recipients,
                    subject: "[Test] " + EmailSettings.personalize(settings.subject, name: authManager.userName, email: authManager.userEmail),
                    bodyNote: "This is a test from Just Capture. A real notification also includes a link to your recording in Google Drive." + (settings.note.isEmpty ? "" : "\n\n" + settings.note),
                    startedAt: settings.includeTime ? Date() : nil,
                    address: nil,
                    latitude: nil,
                    longitude: nil,
                    driveFolderLink: nil,
                    accessToken: token
                )
                testEmailState = .sent
            } catch {
                testEmailState = .failed("Couldn't send")
            }
            try? await Task.sleep(for: .seconds(4))
            if testEmailState != .sending { testEmailState = .idle }
        }
    }
}
