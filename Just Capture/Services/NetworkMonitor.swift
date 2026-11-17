import Foundation
import Network

/// Tells the retry loops whether the phone has a connection, so being offline
/// doesn't use up a clip's or email's retries, and so they try again as soon as
/// the connection returns instead of sitting out a long backoff.
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    /// A connection that returns has to hold for this long before anything
    /// retries, so a flapping connection can't turn into a burst of requests.
    private static let settleDelay: Duration = .seconds(2)

    /// Assumed online until the first update, which arrives almost at once.
    private(set) var isOnline = true
    /// Called when a returning connection has settled.
    var onRestored: (() -> Void)?
    /// Called when the connection drops.
    var onLost: (() -> Void)?

    private let monitor = NWPathMonitor()
    private var settleTask: Task<Void, Never>?
    private var waiters: [UUID: Waiter] = [:]

    private struct Waiter {
        let continuation: CheckedContinuation<Void, Never>
        let timeout: Task<Void, Never>
    }

    private init() {
        monitor.pathUpdateHandler = { @Sendable [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in self?.update(online: online) }
        }
        monitor.start(queue: DispatchQueue(label: "com.justcapture.network"))
    }

    private func update(online: Bool) {
        guard online != isOnline else { return }
        isOnline = online
        settleTask?.cancel()
        settleTask = nil
        guard online else {
            onLost?()
            return
        }
        settleTask = Task { @MainActor in
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled, self.isOnline else { return }
            for id in Array(self.waiters.keys) { self.resume(id) }
            self.onRestored?()
        }
    }

    /// Returns after `timeout`, when a lost connection comes back, or when the
    /// calling task is cancelled, whichever is first. The timeout means a wrong
    /// reading of the network can only delay a retry, not stop it.
    func waitForRestoredConnection(upTo timeout: TimeInterval) async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let timer = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(timeout))
                    self.resume(id)
                }
                waiters[id] = Waiter(continuation: continuation, timeout: timer)
            }
        } onCancel: {
            Task { @MainActor in self.resume(id) }
        }
    }

    private func resume(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.timeout.cancel()
        waiter.continuation.resume()
    }
}
