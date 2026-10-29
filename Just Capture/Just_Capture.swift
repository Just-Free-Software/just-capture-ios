import SwiftUI
import GoogleSignIn

@main
struct Just_Capture: App {
    @State private var authManager = GoogleAuthManager()
    @State private var cameraManager = CameraManager()
    @State private var locationManager = LocationManager()
    @State private var uploadQueueManager = UploadQueueManager()
    @State private var driveStorageManager = DriveStorageManager()
    @State private var emailQueueManager = EmailQueueManager()
    @State private var sessionStore = SessionStore()
    @State private var sharedFolderStore = SharedFolderStore()

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
                .environment(sharedFolderStore)
                .preferredColorScheme(.dark)
                .onAppear {
                    uploadQueueManager.sessionStore = sessionStore
                    emailQueueManager.sessionStore = sessionStore
                    emailQueueManager.locationManager = locationManager
                    driveStorageManager.sessionStore = sessionStore
                    uploadQueueManager.onFolderCreated = { [emailQueueManager, authManager] session in
                        emailQueueManager.sendLinkFollowUps(forSessionId: session.id, authManager: authManager)
                    }
                }
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
                .task {
                    // Leftover uploads/emails are resumed by ContentView once
                    // this flips isSignedIn.
                    await authManager.restoreSignIn()
                }
        }
    }
}
