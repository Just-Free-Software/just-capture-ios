import SwiftUI

struct SettingsView: View {
    @Environment(GoogleAuthManager.self) var authManager
    @Environment(DriveStorageManager.self) var driveStorageManager
    
    @AppStorage("chunkDuration") private var chunkDuration: Double = 30
    @AppStorage("emailRecipients") private var emailRecipients: String = ""
    @AppStorage("emailSubject") private var emailSubject: String = ""
    @AppStorage("emailNote") private var emailNote: String = ""
    @AppStorage("storageFullEmailNote") private var storageFullEmailNote: String = ""
    @AppStorage("emailAlertsEnabled") private var emailAlertsEnabled: Bool = true
    @AppStorage("includeTimeInEmail") private var includeTimeInEmail: Bool = true
    @AppStorage("includeLocationInEmail") private var includeLocationInEmail: Bool = true
    @AppStorage("saveChunksLocally") private var saveChunksLocally: Bool = true
    @FocusState private var isInputActive: Bool
    
    private var defaultSubject: String {
        return "Alert! [your_name] is broadcasting"
    }
    
    @ViewBuilder
    private var driveStorageStatus: some View {
        switch driveStorageManager.state {
        case .ok:
            if let available = driveStorageManager.availableBytes {
                Text(DriveStorageManager.formatBytes(available))
                    .foregroundColor(.secondary)
            }
        case .low:
            if let available = driveStorageManager.availableBytes {
                Text("\(DriveStorageManager.formatBytes(available)) left")
                    .foregroundColor(.yellow)
            }
        case .out:
            Text("Full")
                .foregroundColor(.red)
        case .unlimited:
            Text("Unlimited")
                .foregroundColor(.secondary)
        case .unavailable:
            Text("Unavailable")
                .foregroundColor(.secondary)
        }
    }
    
    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    if authManager.isSignedIn {
                        HStack(spacing: 16) {
                            Circle()
                                .fill(Color.blue.gradient)
                                .frame(width: 40, height: 40)
                                .overlay(
                                    Text(authManager.userName?.prefix(1).uppercased() ?? authManager.userEmail?.prefix(1).uppercased() ?? "?")
                                        .font(.headline)
                                        .foregroundColor(.white)
                                )
                            
                            VStack(alignment: .leading) {
                                Text(authManager.userName ?? "User")
                                    .font(.body)
                                    .foregroundColor(.white)
                                Text(authManager.userEmail ?? "")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            Spacer()
                            
                            Button("Sign Out") {
                                authManager.signOut()
                            }
                            .foregroundColor(.red)
                            .buttonStyle(.borderless)
                        }
                    } else {
                        Button("Sign In") {
                            Task { try? await authManager.signIn() }
                        }
                    }
                }
                .listRowBackground(Color.white.opacity(0.05))
                
                Section("Recording") {
                    Picker("Upload a clip every", selection: $chunkDuration) {
                        Text("10s").tag(10.0)
                        Text("30s").tag(30.0)
                        Text("60s").tag(60.0)
                    }
                }
                .listRowBackground(Color.white.opacity(0.05))
                
                Section("Email Alerts") {
                    Toggle("Enable Alerts", isOn: $emailAlertsEnabled)
                        .tint(.blue)
                    
                    if emailAlertsEnabled {
                        VStack(alignment: .leading, spacing: 4) {
                            TextField("comma-separated emails", text: $emailRecipients)
                                .keyboardType(.emailAddress)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .focused($isInputActive)
                            Text("Enter recipient email addresses, separated by commas")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        TextField("Subject", text: $emailSubject, prompt: Text(defaultSubject))
                            .focused($isInputActive)
                        
                        TextField("Optional note to include", text: $emailNote, axis: .vertical)
                            .lineLimit(2...5)
                            .focused($isInputActive)
                        
                        TextField("Storage full note", text: $storageFullEmailNote, axis: .vertical)
                            .lineLimit(2...5)
                            .focused($isInputActive)
                        
                        Toggle("Include Time", isOn: $includeTimeInEmail)
                            .tint(.blue)
                        
                        Toggle("Include Location", isOn: $includeLocationInEmail)
                            .tint(.blue)
                    }
                }
                .listRowBackground(Color.white.opacity(0.05))
                
                Section("Storage") {
                    if authManager.isSignedIn {
                        HStack {
                            Text("Google Drive")
                            Spacer()
                            driveStorageStatus
                        }
                        
                        if let quota = driveStorageManager.quota, !quota.isUnlimited {
                            Text("\(DriveStorageManager.formatBytes(quota.availableBytes ?? 0)) free of \(DriveStorageManager.formatBytes(quota.limit ?? 0))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        if let seconds = driveStorageManager.estimatedRecordingSeconds {
                            Text("That's about \(DriveStorageManager.formatRecordingTime(seconds)) of recording time left")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else if driveStorageManager.state == .unlimited {
                            Text("Unlimited storage — record as long as you like")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        
                        HStack {
                            Spacer()
                            Button("Refresh") {
                                Task { await driveStorageManager.refresh(authManager: authManager) }
                            }
                            .font(.caption)
                            .buttonStyle(.borderless)
                        }
                    }
                    
                    Toggle("Save Chunks Locally", isOn: $saveChunksLocally)
                        .tint(.blue)
                    Text("Keep recorded clips on device after upload. When off, local files are deleted once they're successfully sent; chunks are still written to disk until then so uploads can complete.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text("Clips sent to Google Drive will NOT be deleted.")
                        .font(.caption.bold())
                        .foregroundColor(.blue)
                }
                .listRowBackground(Color.white.opacity(0.05))
                
                Section("About") {
                    HStack {
                        Text("Just App 2")
                        Spacer()
                        Text("v1.0")
                            .foregroundColor(.secondary)
                    }
                    Text("Continuous video recording with Google Drive upload")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .listRowBackground(Color.white.opacity(0.05))
            }
            .navigationTitle("Settings")
            .scrollContentBackground(.hidden)
            .background(Color.black.ignoresSafeArea())
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture {
                isInputActive = false
            }
            .onAppear {
                if emailSubject.isEmpty || emailSubject == "🚨 Emergency Recording Alert" {
                    emailSubject = defaultSubject
                }
                if authManager.isSignedIn {
                    Task { await driveStorageManager.refreshIfStale(authManager: authManager) }
                }
            }
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        isInputActive = false
                    }
                }
            }
        }
    }
}
