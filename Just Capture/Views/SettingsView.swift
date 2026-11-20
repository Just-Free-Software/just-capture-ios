import SwiftUI

/// A setting another screen can open Settings at (the Record tab's pills).
enum SettingsSection: Hashable {
    case storage, location
}

struct SettingsView: View {
    /// Set by another tab to scroll here to one setting; cleared once shown.
    @Binding var scrollTarget: SettingsSection?

    @Environment(GoogleAuthManager.self) var authManager
    @Environment(DriveStorageManager.self) var driveStorageManager
    @Environment(UploadQueueManager.self) var uploadManager

    @AppStorage("chunkDuration") private var chunkDuration: Double = 30
    @AppStorage("emailRecipients") private var emailRecipients: String = ""
    @AppStorage("emailSubject") private var emailSubject: String = ""
    @AppStorage("emailNote") private var emailNote: String = ""
    @AppStorage("emailAlertsEnabled") private var emailAlertsEnabled: Bool = true
    @AppStorage("includeTimeInEmail") private var includeTimeInEmail: Bool = true
    @AppStorage("locationEnabled") private var locationEnabled: Bool = true
    @FocusState private var focusedField: Field?

    @State private var testEmailState: TestEmailState = .idle
    /// Addresses shown as pills, and the text still being typed. Together
    /// they are the `emailRecipients` setting; see `saveRecipients()`.
    @State private var committedRecipients: [String] = []
    @State private var recipientDraft = ""
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

    /// Addresses to flag in the footer. What's still being typed is left out
    /// until the field loses focus, so a half-typed address isn't an error.
    private var invalidRecipients: [String] {
        let typing = focusedField == .recipients ? EmailSettings.parseRecipients(recipientDraft) : []
        return recipients.filter { !EmailSettings.isValidEmail($0) && !typing.contains($0) }
    }

    private var hasInvalidRecipient: Bool {
        recipients.contains { !EmailSettings.isValidEmail($0) }
    }

    /// Writes the pills plus whatever is in the field to the stored setting.
    /// The half-typed text is included so an address still gets the email if
    /// the user never presses return, as it did when this was one text field.
    private func saveRecipients() {
        emailRecipients = (committedRecipients + EmailSettings.parseRecipients(recipientDraft)).joined(separator: ", ")
    }

    private func loadRecipients() {
        committedRecipients = EmailSettings.parseRecipients(emailRecipients)
        recipientDraft = ""
    }

    /// Turns each valid address in the field into a pill; anything else stays
    /// in the field to be fixed.
    private func commitDraft() {
        var rejected: [String] = []
        for address in EmailSettings.parseRecipients(recipientDraft) {
            if !EmailSettings.isValidEmail(address) {
                rejected.append(address)
            } else if !committedRecipients.contains(where: { $0.caseInsensitiveCompare(address) == .orderedSame }) {
                committedRecipients.append(address)
            }
        }
        recipientDraft = rejected.joined(separator: ", ")
        saveRecipients()
    }

    private func removeRecipient(_ address: String) {
        committedRecipients.removeAll { $0 == address }
        saveRecipients()
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
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
                        Link("Website", destination: AppConfig.homepageURL)
                        Link("Privacy Policy", destination: AppConfig.privacyPolicyURL)
                        Link("Terms of Service", destination: AppConfig.termsURL)
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
                    loadRecipients()
                    Task { deviceFreeBytes = await DeviceStorage.availableBytes() }
                    if emailSubject.isEmpty {
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
                .task(id: scrollTarget) {
                    guard let target = scrollTarget else { return }
                    // The first time the tab is opened the form hasn't been laid
                    // out yet, and scrolling before that does nothing.
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    withAnimation { proxy.scrollTo(target, anchor: .center) }
                    scrollTarget = nil
                }
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

            Toggle("Save location", isOn: $locationEnabled)
                .id(SettingsSection.location)
        } header: {
            Text("Recording")
        } footer: {
            Text("Each clip starts uploading as soon as it ends. Your location is saved when you start recording and at the end of each clip. The origin location is also included in the notification email.")
        }
    }

    private var emailSection: some View {
        Section {
            Toggle("Email notifications", isOn: $emailAlertsEnabled)

            if emailAlertsEnabled {
                // The chips and the field share one row, like a mail app's
                // "To" line: the field follows the last chip and wraps with it.
                FlowLayout(spacing: 8, lastFillsRow: true) {
                    ForEach(committedRecipients, id: \.self) { address in
                        RecipientPill(address: address, isValid: EmailSettings.isValidEmail(address)) {
                            withAnimation(.snappy) { removeRecipient(address) }
                        }
                    }

                    TextField("Add email address", text: $recipientDraft, prompt: Text(verbatim: "name@example.com"))
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focusedField, equals: .recipients)
                        // Wide enough to type in; below this it gets its own line.
                        .frame(minWidth: 150)
                        .onChange(of: recipientDraft) { _, draft in
                            // A comma, space or pasted list finishes an address.
                            if draft.contains(where: { ",; \n\t".contains($0) }) {
                                withAnimation(.snappy) { commitDraft() }
                            } else {
                                saveRecipients()
                            }
                        }
                        .onSubmit {
                            withAnimation(.snappy) { commitDraft() }
                            // Stay in the field to add another, unless this one needs fixing.
                            if recipientDraft.isEmpty { focusedField = .recipients }
                        }
                        .onChange(of: focusedField) { old, _ in
                            if old == .recipients { withAnimation(.snappy) { commitDraft() } }
                        }
                }
                .padding(.vertical, 4)

                Button {
                    sendTestEmail()
                } label: {
                    HStack {
                        Label("Send Test Email", systemImage: "paperplane")
                        Spacer()
                        testEmailStatus
                    }
                }
                .disabled(recipients.isEmpty || hasInvalidRecipient || testEmailState == .sending)
            }
        } header: {
            Text("Email Notifications")
        } footer: {
            if emailAlertsEnabled {
                if !invalidRecipients.isEmpty {
                    Text("Check \(invalidRecipients.joined(separator: ", ")) — \(invalidRecipients.count == 1 ? "it doesn't" : "they don't") look like an email address.")
                        .foregroundStyle(Theme.record)
                } else if recipients.isEmpty {
                    Text("Add at least one person to email when you start recording.")
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
                .multilineTextAlignment(.trailing)
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
            Text("A second email is sent if your Google Drive gets close to full while recording. Make sure your contacts can add storage to your account if that happens.")
        }
    }

    private var storageSection: some View {
        Section {
            LabeledContent("Google Drive") {
                driveStorageStatus
            }
            .id(SettingsSection.storage)
            if let quota = driveStorageManager.quota, !quota.isUnlimited, let limit = quota.limit, limit > 0 {
                Gauge(value: Double(quota.usage), in: 0...Double(limit)) {
                    EmptyView()
                }
                .gaugeStyle(.linearCapacity)
                .tint(driveStorageManager.state == .ok ? Theme.accent : Theme.warning)
            }
            Button {
                isRefreshingStorage = true
                Task {
                    deviceFreeBytes = await DeviceStorage.availableBytes()
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
                    subject: "[Test] " + settings.subject,
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


/// One accepted notification address, styled like a Gmail recipient chip:
/// a round initial, the address, and a button to remove it.
private struct RecipientPill: View {
    let address: String
    let isValid: Bool
    let onRemove: () -> Void

    @ScaledMetric(relativeTo: .subheadline) private var avatarSize: CGFloat = 24

    var body: some View {
        let color = isValid ? Theme.accent : Theme.record
        HStack(spacing: 6) {
            Text(isValid ? String(address.prefix(1)).uppercased() : "!")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: avatarSize, height: avatarSize)
                .background(color, in: Circle())
                .accessibilityHidden(true)
            // A long address is cut at the end, so who it is stays readable.
            Text(address)
                .font(.subheadline)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(4)
            }
            // Without this a tap anywhere in the form row presses every button in it.
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove \(address)")
        }
        .padding(.leading, 4)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .background(Theme.surfaceRaised, in: Capsule())
        .overlay(Capsule().strokeBorder(isValid ? Theme.stroke : Theme.record.opacity(0.7), lineWidth: 1))
    }
}
