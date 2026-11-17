import BackgroundTasks
import Foundation

/// The services that have to work with no UI. iOS can launch the app in the
/// background to deliver a finished upload or a wake-up, and SwiftUI may not
/// build any views then, so none of this can depend on `onAppear` or `.task`.
///
/// It also keeps clips and emails moving through three ways of getting time to
/// run: iOS holds uploads in `BackgroundTransfers`, a wake-up request runs the
/// app when a connection returns, and scheduled tasks are the backup for
/// whatever those miss.
final class AppServices {
    static let shared = AppServices()

    let authManager = GoogleAuthManager()
    let locationManager = LocationManager()
    let uploadQueueManager = UploadQueueManager()
    let driveStorageManager = DriveStorageManager()
    let emailQueueManager = EmailQueueManager()
    let sessionStore = SessionStore()
    private let transfers = BackgroundTransfers(maxConcurrentUploads: AppConfig.maxConcurrentUploads)

    private static let refreshTaskIdentifier = "fyi.justfreesoftware.JustCapture.refresh"
    private static let processingTaskIdentifier = "fyi.justfreesoftware.JustCapture.processing"

    /// Failed work gets a fresh set of tries at most this often, however many
    /// things ask. Each clip and email then backs off as usual.
    private static let failedRetryInterval: TimeInterval = 60
    /// Time spent finishing work in a background run. iOS allows about 30 s.
    private static let backgroundRunLimit: TimeInterval = 20
    /// Wake-ups are one small request and no Google API quota, but each one
    /// also runs the app. Offline they fire when a connection returns, at most
    /// this often. Online the connection isn't the problem, so they back off.
    private static let wakeUpMinimumGap: TimeInterval = 60
    private static let wakeUpInitialDelay: TimeInterval = 5 * 60
    private static let wakeUpMaxDelay: TimeInterval = 6 * 60 * 60
    private static let lastWakeUpKey = "lastWakeUpFiredAt"
    private static let wakeUpStepKey = "wakeUpBackoffStep"

    private var startupTask: Task<Void, Never>?
    private var lastFailedRetry: Date?
    private var isUpdatingWakeUp = false
    /// Sessions iOS finished delivering events for, and the handlers waiting.
    private var deliveredSessions: Set<String> = []

    private init() {
        uploadQueueManager.sessionStore = sessionStore
        uploadQueueManager.transfers = transfers
        uploadQueueManager.authManager = authManager
        emailQueueManager.sessionStore = sessionStore
        emailQueueManager.locationManager = locationManager
        driveStorageManager.sessionStore = sessionStore
        uploadQueueManager.onFolderCreated = { [emailQueueManager, authManager] session in
            emailQueueManager.sendLinkFollowUps(forSessionId: session.id, authManager: authManager)
        }
        uploadQueueManager.onChunkUploaded = { [driveStorageManager, authManager] chunk in
            driveStorageManager.recordUpload(bytes: chunk.fileSize, authManager: authManager)
        }
        uploadQueueManager.onWorkChanged = { [weak self] in
            self?.updateWakeUp()
        }
        transfers.onUploadFinished = { [uploadQueueManager] finished in
            uploadQueueManager.handleUploadFinished(finished)
        }
        transfers.onUploadProgress = { [uploadQueueManager] chunkId, fraction in
            uploadQueueManager.handleUploadProgress(chunkId: chunkId, fraction: fraction)
        }
        transfers.onWakeUpFired = { [weak self] in
            UserDefaults.standard.set(Date(), forKey: Self.lastWakeUpKey)
            self?.sweep()
        }
        transfers.onEventsDelivered = { [weak self] identifier in
            self?.deliveredSessions.insert(identifier)
        }
        NetworkMonitor.shared.onRestored = { [weak self] in
            self?.sweep()
        }
        NetworkMonitor.shared.onLost = { [weak self] in
            self?.updateWakeUp(connectionLost: true)
        }
    }

    // MARK: - Launch

    /// Call while the app is launching, foreground or background.
    func launch() {
        registerBackgroundTasks()
        startupTask = Task { @MainActor in
            await uploadQueueManager.reconnectBackgroundUploads()
            await ClipRecovery.recoverInterruptedClips(in: sessionStore)
            await authManager.restoreSignIn()
            startupTask = nil
            sweep()
        }
    }

    // MARK: - Sweeping

    /// Restarts whatever isn't running. Safe to call often: it does nothing for
    /// clips and emails already in progress, and tries that have failed are
    /// only restarted once per `failedRetryInterval`.
    func sweep() {
        // The startup task sweeps when it's done, and sweeping before it has
        // learned what iOS is holding could upload those clips twice.
        guard startupTask == nil else { return }
        sessionStore.reloadIfNeeded()
        emailQueueManager.reloadIfNeeded()
        if authManager.isSignedIn {
            let now = Date()
            let retryFailed = lastFailedRetry.map { now.timeIntervalSince($0) >= Self.failedRetryInterval } ?? true
            if retryFailed { lastFailedRetry = now }
            uploadQueueManager.resumePendingUploads(authManager: authManager, retryFailed: retryFailed)
            emailQueueManager.resumeAll(authManager: authManager, retryFailed: retryFailed)
            // An email is waiting on a link, with no clip to create the folder.
            for job in emailQueueManager.jobs where job.needsLinkFollowUp {
                if let session = sessionStore.sessions.first(where: { $0.id == job.sessionId }) {
                    uploadQueueManager.prepareFolder(for: session, authManager: authManager)
                }
            }
        }
        updateWakeUp()
    }

    /// Back on screen: retries now, rather than leaving failed work until the
    /// next launch.
    func didBecomeActive() {
        if authManager.canRestoreSignIn {
            Task { @MainActor in
                await authManager.restoreSignIn()
                sweep()
            }
        } else {
            sweep()
        }
    }

    /// Leaving the screen. iOS treats a request made from here as urgent, but
    /// one made once the app is in the background as something it can delay.
    func willLeaveForeground() {
        updateWakeUp()
        scheduleBackgroundTasks()
    }

    /// Signed out, there's nothing the app could do if it were woken.
    private var needsAppToRun: Bool {
        authManager.isSignedIn && (uploadQueueManager.hasClipsNeedingApp || emailQueueManager.hasOutstandingWork)
    }

    // MARK: - Wake-ups

    /// Queues a wake-up if something needs the app and none is queued, and
    /// cancels it once nothing does, so an idle app is never woken. When the
    /// connection drops, a queued wake-up may be delayed by online backoff, so
    /// it's replaced with one that fires as soon as the connection returns.
    private func updateWakeUp(connectionLost: Bool = false) {
        guard !isUpdatingWakeUp else { return }
        isUpdatingWakeUp = true
        Task { @MainActor in
            defer { isUpdatingWakeUp = false }
            var isArmed = await transfers.isWakeUpArmed()
            let defaults = UserDefaults.standard
            guard needsAppToRun else {
                defaults.removeObject(forKey: Self.wakeUpStepKey)
                if isArmed { await transfers.cancelWakeUp() }
                return
            }
            if connectionLost && isArmed {
                await transfers.cancelWakeUp()
                isArmed = false
            }
            guard !isArmed else { return }
            if NetworkMonitor.shared.isOnline {
                let step = defaults.integer(forKey: Self.wakeUpStepKey)
                let delay = min(Self.wakeUpMaxDelay, Self.wakeUpInitialDelay * pow(2, Double(step)))
                defaults.set(step + 1, forKey: Self.wakeUpStepKey)
                transfers.armWakeUp(notBefore: Date().addingTimeInterval(delay))
            } else {
                let last = defaults.object(forKey: Self.lastWakeUpKey) as? Date
                let earliest = last?.addingTimeInterval(Self.wakeUpMinimumGap)
                transfers.armWakeUp(notBefore: earliest.flatMap { $0 > Date() ? $0 : nil })
            }
        }
    }

    // MARK: - Background runs

    /// iOS launched or resumed the app for a finished background session.
    /// `completion` tells iOS the app is done and may be suspended again.
    func handleBackgroundEvents(identifier: String, completion: @escaping () -> Void) {
        Task { @MainActor in
            await runInBackground()
            // Events usually arrive by now. If not, don't hold iOS up over it.
            let deadline = Date().addingTimeInterval(3)
            while !deliveredSessions.contains(identifier), Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            deliveredSessions.remove(identifier)
            completion()
        }
    }

    /// Does what it can in the short time a background run gets. Uses a real
    /// connection for emails and new upload links, then hands clips back to iOS.
    private func runInBackground() async {
        await startupTask?.value
        if authManager.canRestoreSignIn {
            await authManager.restoreSignIn()
        }
        sweep()
        let deadline = Date().addingTimeInterval(Self.backgroundRunLimit)
        // Offline, the work is only waiting, so there's no reason to stay awake.
        while uploadQueueManager.hasActiveWork || emailQueueManager.hasActiveWork,
              NetworkMonitor.shared.isOnline, Date() < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(250))
        }
        updateWakeUp()
    }

    // MARK: - Scheduled backup

    /// The backup for anything the wake-up misses. iOS decides when these run,
    /// possibly many hours later, and may not run them at all. Must be
    /// registered before launching finishes.
    private func registerBackgroundTasks() {
        for identifier in [Self.refreshTaskIdentifier, Self.processingTaskIdentifier] {
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
                MainActor.assumeIsolated {
                    self?.run(task)
                }
            }
            if !registered { print("Couldn't register background task \(identifier)") }
        }
    }

    private func run(_ task: BGTask) {
        scheduleBackgroundTasks()
        var isDone = false
        let finish = { (success: Bool) in
            guard !isDone else { return }
            isDone = true
            task.setTaskCompleted(success: success)
        }
        let work = Task { @MainActor in
            await runInBackground()
            finish(!Task.isCancelled)
        }
        // iOS doesn't promise which thread this runs on.
        task.expirationHandler = { @Sendable in
            DispatchQueue.main.async {
                work.cancel()
                finish(false)
            }
        }
    }

    /// Only asks for time while clips or emails are unfinished, including clips
    /// iOS is holding, since the app has to follow up when those finish.
    private func scheduleBackgroundTasks() {
        guard needsAppToRun || uploadQueueManager.hasUnfinishedClips else { return }
        let earliest = Date().addingTimeInterval(15 * 60)
        let refresh = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        refresh.earliestBeginDate = earliest
        let processing = BGProcessingTaskRequest(identifier: Self.processingTaskIdentifier)
        processing.earliestBeginDate = earliest
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        for request in [refresh, processing] as [BGTaskRequest] {
            do {
                try BGTaskScheduler.shared.submit(request)
            } catch {
                print("Couldn't schedule background task \(request.identifier): \(error.localizedDescription)")
            }
        }
    }
}
