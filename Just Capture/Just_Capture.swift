import SwiftUI
import GoogleSignIn

/// Runs for every launch, including background launches where SwiftUI may build
/// no views. It's also the only way iOS reports finished background transfers.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppServices.shared.launch()
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        AppServices.shared.handleBackgroundEvents(identifier: identifier, completion: completionHandler)
    }
}

@main
struct Just_Capture: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var authManager = AppServices.shared.authManager
    @State private var cameraManager = CameraManager()
    @State private var locationManager = AppServices.shared.locationManager
    @State private var uploadQueueManager = AppServices.shared.uploadQueueManager
    @State private var driveStorageManager = AppServices.shared.driveStorageManager
    @State private var emailQueueManager = AppServices.shared.emailQueueManager
    @State private var sessionStore = AppServices.shared.sessionStore
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
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}
