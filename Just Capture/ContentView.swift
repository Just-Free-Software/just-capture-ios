//  ContentView.swift

import SwiftUI
import UIKit
import GoogleSignIn

struct ContentView: View {
    @Environment(GoogleAuthManager.self) private var authManager
    @Environment(CameraManager.self) private var cameraManager
    @Environment(UploadQueueManager.self) private var uploadManager
    @Environment(SessionStore.self) private var sessionStore
    @Environment(EmailQueueManager.self) private var emailQueueManager
    @Environment(\.scenePhase) private var scenePhase
    
    @State private var signInError: String?
    
    var body: some View {
        content
            .onChange(of: cameraManager.isRecording) { wasRecording, isRecording in
                // Auto-lock would background the app, which suspends the camera
                // and ends the recording, so the screen stays on while recording.
                UIApplication.shared.isIdleTimerDisabled = isRecording
                // Single place that finalizes a session, whichever path stopped
                // recording (stop button, backgrounding, sign-out, camera failure).
                guard wasRecording, !isRecording else { return }
                if let session = sessionStore.currentSession, session.isActive {
                    session.isActive = false
                    sessionStore.save()
                    Task { await uploadManager.updatePlaylist(session: session, authManager: authManager) }
                }
            }
            .onChange(of: authManager.isSignedIn, initial: true) { _, signedIn in
                if signedIn {
                    // Drain anything left over from a previous launch or a
                    // previous sign-in: pending chunk uploads and unsent emails.
                    uploadManager.resumePendingUploads(authManager: authManager)
                    emailQueueManager.resumeAll(authManager: authManager)
                    Task { await uploadManager.checkPublicSharing(authManager: authManager) }
                } else {
                    // Signing out hides the camera; don't keep recording unseen.
                    cameraManager.stopRecording()
                    uploadManager.resetAccountState()
                }
            }
    }
    
    @ViewBuilder
    private var content: some View {
        if authManager.isSignedIn {
            TabView {
                RecordingView()
                    .tabItem {
                        Label("Record", systemImage: "video.fill")
                    }
                
                DashboardView()
                    .tabItem {
                        Label("My Clips", systemImage: "square.stack.fill")
                    }

                SharedView()
                    .tabItem {
                        Label("Watch", systemImage: "play.rectangle.fill")
                    }

                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gearshape.fill")
                    }
            }
            .tint(Theme.accent)
            .onChange(of: scenePhase) { _, newPhase in
                // When the user switches away from the app, iOS suspends the camera
                // capture session, so any further chunks would be empty. Stop
                // recording cleanly; the isRecording observer finalizes the session.
                guard newPhase == .background else { return }
                cameraManager.stopRecording()
            }
        } else {
            SignInView(isAuthenticating: authManager.isAuthenticating) {
                Task {
                    do {
                        try await authManager.signIn()
                    } catch {
                        // User-cancelled sign-in isn't worth an alert.
                        if (error as NSError).code != GIDSignInError.canceled.rawValue {
                            signInError = error.localizedDescription
                        }
                    }
                }
            }
            .alert("Couldn't Sign In", isPresented: Binding(
                get: { signInError != nil },
                set: { if !$0 { signInError = nil } }
            )) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(signInError ?? "")
            }
        }
    }
}

private struct SignInView: View {
    let isAuthenticating: Bool
    let onSignIn: () -> Void
    
    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            
            // Soft orange glow behind the logo, like the icon's.
            Circle()
                .fill(Theme.accent)
                .frame(width: 360, height: 360)
                .blur(radius: 120)
                .opacity(0.3)
                .offset(y: -220)
                .ignoresSafeArea()
            
            VStack(spacing: 0) {
                Spacer()
                
                Image("Logo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 112, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .strokeBorder(.white.opacity(0.08), lineWidth: 1)
                    )
                    .shadow(color: Theme.accent.opacity(0.35), radius: 24, y: 8)
                    .accessibilityHidden(true)
                    .padding(.bottom, 24)
                
                Text("Just Capture")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 24)
                Text("Record. Back up. Notify.")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(Theme.secondaryText)
                    .padding(.top, 4)
                
                VStack(alignment: .leading, spacing: 18) {
                    feature("icloud.and.arrow.up.fill", "As you record, each clip is uploaded to your Google Drive when you have a connection.")
                    feature("envelope.badge.fill", "The people you choose get an email with a link to watch.")
                }
                .padding(.top, 40)
                .padding(.horizontal, 36)
                
                Spacer()
                
                Button(action: onSignIn) {
                    HStack(spacing: 10) {
                        if isAuthenticating {
                            ProgressView().tint(.black)
                        } else {
                            Image(systemName: "person.crop.circle.fill")
                        }
                        Text(isAuthenticating ? "Signing in…" : "Continue with Google")
                    }
                    .font(.headline)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(isAuthenticating)
                .padding(.horizontal, 24)
                
                Text("Just Capture asks for permission to save to Drive and send email from your Gmail account.")
                    .font(.caption)
                    .foregroundStyle(Theme.tertiaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                    .padding(.top, 14)
                    .padding(.bottom, 24)
            }
        }
    }
    
    private func feature(_ systemImage: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
