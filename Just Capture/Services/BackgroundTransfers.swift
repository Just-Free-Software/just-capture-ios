import Foundation

/// A background upload that has ended, successfully or not.
nonisolated struct FinishedBackgroundUpload: Sendable {
    let chunkId: UUID
    /// Nil when no reply arrived.
    let statusCode: Int?
    let body: Data
    let error: (any Error)?
    /// The upload was cancelled, by this app or because the app was force-quit.
    let wasCancelled: Bool
}

/// The two background `URLSession`s. iOS runs their transfers outside the app,
/// waits for a connection by itself, and launches the app when they finish, even
/// if the app isn't running. iOS doesn't do this after a force-quit: it cancels
/// the transfers and doesn't launch the app until the user does.
///
/// They're separate because iOS wakes the app when a session's tasks have all
/// finished. A wake-up sharing a session with queued uploads could wait on them.
nonisolated final class BackgroundTransfers: NSObject, @unchecked Sendable {
    static let uploadSessionIdentifier = "fyi.justfreesoftware.JustCapture.uploads"
    static let wakeSessionIdentifier = "fyi.justfreesoftware.JustCapture.wake"
    /// Returns an empty reply, so a wake-up costs almost no data and no Google
    /// API quota. Finishing is all that matters, not what comes back.
    private static let wakeURL = URL(string: "https://www.gstatic.com/generate_204")!

    /// All called on the main queue.
    @MainActor var onUploadFinished: (@MainActor (FinishedBackgroundUpload) -> Void)?
    @MainActor var onUploadProgress: (@MainActor (UUID, Double) -> Void)?
    /// A wake-up request finished, which usually means a connection is back.
    @MainActor var onWakeUpFired: (@MainActor () -> Void)?
    /// iOS has delivered everything it held for a session after launching or
    /// resuming the app in the background.
    @MainActor var onEventsDelivered: (@MainActor (String) -> Void)?

    private var uploadSession: URLSession!
    private var wakeSession: URLSession!

    // Confined to `delegateQueue`, which runs one callback at a time.
    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var responseBodies: [Int: Data] = [:]
    private var lastReportedPercent: [Int: Int] = [:]

    init(maxConcurrentUploads: Int) {
        super.init()
        // Creating a session with the same identifier reconnects to transfers
        // from before the app was closed, so this must happen at every launch.
        uploadSession = URLSession(configuration: Self.configuration(identifier: Self.uploadSessionIdentifier, connections: maxConcurrentUploads), delegate: self, delegateQueue: delegateQueue)
        wakeSession = URLSession(configuration: Self.configuration(identifier: Self.wakeSessionIdentifier, connections: 1), delegate: self, delegateQueue: delegateQueue)
    }

    private static func configuration(identifier: String, connections: Int) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = true
        // Limits simultaneous uploads even when iOS runs them with the app closed.
        configuration.httpMaximumConnectionsPerHost = connections
        // How long iOS keeps trying, offline time included. Longer than an
        // upload link is likely to last, and the sweep recovers from either.
        configuration.timeoutIntervalForResource = 14 * 24 * 60 * 60
        return configuration
    }

    // MARK: - Uploads

    /// Hands a clip to iOS. `offset` is where to continue from, with the rest of
    /// the file prepared in `fileURL`. The upload link is the only credential
    /// the request carries, so an expired token can't stop it.
    func startUpload(chunkId: UUID, fileURL: URL, sessionURL: URL, offset: Int64, fileSize: Int64) {
        var request = URLRequest(url: sessionURL)
        request.httpMethod = "PUT"
        request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        request.setValue("bytes \(offset)-\(fileSize - 1)/\(fileSize)", forHTTPHeaderField: "Content-Range")
        let task = uploadSession.uploadTask(with: request, fromFile: fileURL)
        task.taskDescription = Self.description(chunkId: chunkId, offset: offset)
        task.resume()
    }

    /// Clips iOS is holding or sending right now.
    func liveUploadIDs() async -> Set<UUID> {
        let tasks = await uploadSession.allTasks
        return Set(tasks.filter { $0.state == .running || $0.state == .suspended }.compactMap { Self.parse($0.taskDescription)?.chunkId })
    }

    func cancelUploads(chunkIds: Set<UUID>) async {
        for task in await uploadSession.allTasks {
            if let chunkId = Self.parse(task.taskDescription)?.chunkId, chunkIds.contains(chunkId) {
                task.cancel()
            }
        }
    }

    private static func description(chunkId: UUID, offset: Int64) -> String {
        "\(chunkId.uuidString)|\(offset)"
    }

    private static func parse(_ description: String?) -> (chunkId: UUID, offset: Int64)? {
        guard let parts = description?.split(separator: "|"), parts.count == 2,
              let chunkId = UUID(uuidString: String(parts[0])), let offset = Int64(parts[1]) else { return nil }
        return (chunkId, offset)
    }

    // MARK: - Wake-ups

    /// Queues a tiny request that finishes once there's a connection, which
    /// wakes the app so it can refresh its token and do the work iOS can't do
    /// for it. `notBefore` delays it, for when the connection isn't the problem.
    func armWakeUp(notBefore: Date?) {
        var request = URLRequest(url: Self.wakeURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let task = wakeSession.downloadTask(with: request)
        task.earliestBeginDate = notBefore
        task.resume()
    }

    func isWakeUpArmed() async -> Bool {
        await wakeSession.allTasks.contains { $0.state == .running || $0.state == .suspended }
    }

    func cancelWakeUp() async {
        for task in await wakeSession.allTasks { task.cancel() }
    }
}

nonisolated extension BackgroundTransfers: URLSessionDataDelegate, URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseBodies[dataTask.taskIdentifier, default: Data()].append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard let (chunkId, offset) = Self.parse(task.taskDescription), totalBytesExpectedToSend > 0 else { return }
        let fraction = Double(offset + totalBytesSent) / Double(offset + totalBytesExpectedToSend)
        // Whole percents only, so a fast upload doesn't redraw for every packet.
        let percent = Int(fraction * 100)
        guard lastReportedPercent[task.taskIdentifier] != percent else { return }
        lastReportedPercent[task.taskIdentifier] = percent
        DispatchQueue.main.async { self.onUploadProgress?(chunkId, fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Required by the protocol. The wake-up's reply is empty and unused.
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        let wasCancelled = (error as? URLError)?.code == .cancelled
        if session.configuration.identifier == Self.wakeSessionIdentifier {
            guard !wasCancelled else { return }
            DispatchQueue.main.async { self.onWakeUpFired?() }
            return
        }

        let body = responseBodies.removeValue(forKey: task.taskIdentifier) ?? Data()
        lastReportedPercent.removeValue(forKey: task.taskIdentifier)
        guard let chunkId = Self.parse(task.taskDescription)?.chunkId else { return }
        let finished = FinishedBackgroundUpload(
            chunkId: chunkId,
            statusCode: (task.response as? HTTPURLResponse)?.statusCode,
            body: body,
            error: error,
            wasCancelled: wasCancelled
        )
        DispatchQueue.main.async { self.onUploadFinished?(finished) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        guard let identifier = session.configuration.identifier else { return }
        DispatchQueue.main.async { self.onEventsDelivered?(identifier) }
    }
}
