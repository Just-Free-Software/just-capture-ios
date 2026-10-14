//
//  ContentView.swift
//  Just App 2
//
//  Created by Michael Lee on 7/23/26.
//

import SwiftUI

struct ContentView: View {
    @Environment(GoogleAuthManager.self) private var authManager
    @Environment(CameraManager.self) private var cameraManager
    @Environment(UploadQueueManager.self) private var uploadManager
    @Environment(SessionStore.self) private var sessionStore
    @Environment(\.scenePhase) private var scenePhase
    
    var body: some View {
        if authManager.isSignedIn {
            TabView {
                RecordingView()
                    .tabItem {
                        Label("Record", systemImage: "video.fill")
                    }
                
                DashboardView()
                    .tabItem {
                        Label("Dashboard", systemImage: "square.grid.2x2.fill")
                    }
                
                SettingsView()
                    .tabItem {
                        Label("Settings", systemImage: "gearshape.fill")
                    }
            }
            .tint(.white)
            .onChange(of: scenePhase) { _, newPhase in
                // When the user switches away from the app, iOS suspends the camera
                // capture session, so any further chunks would be empty. Stop
                // recording cleanly, finalize the session, and tear down the Drive
                // upload pipeline instead of spamming 0-byte chunks.
                guard newPhase == .background else { return }
                guard cameraManager.isRecording else { return }
                cameraManager.stopRecording()
                if let session = sessionStore.currentSession, session.isActive {
                    session.isActive = false
                    sessionStore.save()
                    Task { await uploadManager.updatePlaylist(session: session, authManager: authManager) }
                }
            }
        } else {
            ZStack {
                Color.black.ignoresSafeArea()
                
                VStack(spacing: 24) {
                    Spacer()
                    
                    Image(systemName: "video.badge.waveform")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 80, height: 80)
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .purple],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    
                    VStack(spacing: 8) {
                        Text("Just")
                            .font(.system(size: 48, weight: .bold))
                            .foregroundColor(.white)
                        
                        Text("Continuous Video Recording & Upload")
                            .font(.subheadline)
                            .foregroundColor(.gray)
                    }
                    
                    Spacer()
                    
                    Button {
                        Task {
                            do {
                                try await authManager.signIn()
                            } catch {
                                print("Sign in failed: \(error)")
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "g.circle.fill") // Using generic 'g' as we don't have Google logo
                                .imageScale(.large)
                            Text("Sign in with Google")
                                .font(.headline)
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.blue)
                        )
                    }
                    .padding(.horizontal, 32)
                    .overlay {
                        if authManager.isAuthenticating {
                            ProgressView()
                                .tint(.white)
                        }
                    }
                    
                    Text("Sign in to enable automatic Google Drive uploads and emergency email alerts")
                        .font(.caption)
                        .foregroundColor(.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                        .padding(.bottom, 32)
                }
            }
        }
    }
}
