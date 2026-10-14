//
//  Just_App_2App.swift
//  Just App 2
//
//  Created by Michael Lee on 7/23/26.
//

import SwiftUI
import GoogleSignIn

@main
struct Just_App_2App: App {
    @State private var authManager = GoogleAuthManager()
    @State private var cameraManager = CameraManager()
    @State private var locationManager = LocationManager()
    @State private var uploadQueueManager = UploadQueueManager()
    @State private var driveStorageManager = DriveStorageManager()
    @State private var emailQueueManager = EmailQueueManager()
    @State private var sessionStore = SessionStore()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(authManager)
                .environment(cameraManager)
                .environment(locationManager)
                .environment(uploadQueueManager)
                .environment(driveStorageManager)
                .environment(emailQueueManager)
                .environment(sessionStore)
                .preferredColorScheme(.dark)
                .onAppear {
                    uploadQueueManager.sessionStore = sessionStore
                    emailQueueManager.sessionStore = sessionStore
                    driveStorageManager.sessionStore = sessionStore
                }
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
                .task {
                    await authManager.restoreSignIn()
                    // After sign-in is restored, drain anything left over from a
                    // previous launch: pending chunk uploads and unsent alert emails.
                    uploadQueueManager.resumePendingUploads(authManager: authManager)
                    emailQueueManager.resumeAll(authManager: authManager)
                }
        }
    }
}
