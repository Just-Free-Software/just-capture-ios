import UIKit

/// Asks iOS for extra time to finish work (an upload, an alert email) if the
/// app is backgrounded mid-flight. Without this the process is suspended
/// within a few seconds and in-flight requests stall until the next launch.
final class BackgroundActivity {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }

    deinit {
        end()
    }
}
