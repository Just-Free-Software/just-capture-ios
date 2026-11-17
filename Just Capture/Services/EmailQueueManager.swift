import Foundation
import Observation
import CoreLocation

/// Retry policy shared by the upload + email queues. Delays grow exponentially
/// up to `maxDelay`, capping the inter-attempt gap so a transient outage
/// doesn't turn into a freeze. Total budget across all `maxAttempts` is roughly
/// the time to drain one full outage cycle.
enum RetryPolicy {
    static let initialDelay: TimeInterval = 5
    static let maxDelay: TimeInterval = 1200      // 20 minutes
    static let factor: Double = 2
    static let maxAttempts: Int = 10
    
    static func delay(forAttempt attempt: Int) -> TimeInterval {
        // attempt 1 -> no prior delay (we just failed); attempt N returns the
        // delay to wait before attempt N+1.
        var delay = initialDelay
        for _ in 1..<attempt { delay = min(maxDelay, delay * factor) }
        return delay
    }

    /// Whether a failure came from having no connection. These don't use up
    /// retries: nothing reached Google, and the retry happens when it returns.
    static func isOffline(_ error: Error) -> Bool {
        if !NetworkMonitor.shared.isOnline { return true }
        guard let urlError = error as? URLError else { return false }
        return urlError.code == .notConnectedToInternet || urlError.code == .dataNotAllowed
    }
}

/// Persistent outbox for emergency-alert emails. Enqueued jobs are stored to
/// disk so they survive a kill/relaunch mid-outage; on each launch unsent jobs
/// are resumed. Each send is retried with exponential backoff up to
/// `RetryPolicy.maxAttempts` tries while online; after that the job is left as
/// `.failed` until the app next retries failed work or the user retries it from
/// the dashboard.
@Observable
class EmailQueueManager {
    var jobs: [EmailJob] = []
    weak var sessionStore: SessionStore?
    weak var locationManager: LocationManager?
    
    /// How long the first send waits for a GPS fix when the job wants a
    /// location but none was known yet. Short, because getting the alert out
    /// matters more than the map link.
    static let locationWaitTimeout: TimeInterval = 6

    /// How long the first send waits for the session's Drive folder, which is
    /// created in parallel when recording starts. Without this the email
    /// usually wins the race and goes out with no link at all. Folder creation
    /// is one API call, so this only runs long when the network is bad.
    static let folderWaitTimeout: TimeInterval = 10
    
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    /// The saved jobs couldn't be read, so saving now would overwrite them.
    private var saveIsBlocked = false
    private static var storageURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("email_jobs.json")
    }

    init() {
        loadAndPrepare()
    }

    private func loadAndPrepare() {
        load()
        // Any job that was mid-send when the process died is left in `.sending`
        // on disk; reset those so resumeAll picks them up cleanly.
        for job in jobs where job.status == .sending {
            job.status = .pending
        }
        if !jobs.isEmpty { save() }
    }

    /// Loads the saved jobs if a launch before the first unlock couldn't.
    func reloadIfNeeded() {
        if saveIsBlocked { loadAndPrepare() }
    }

    /// Sends are running or waiting to retry.
    var hasActiveWork: Bool { !activeTasks.isEmpty }

    /// Something still needs the app to run: an unsent email, or a link owed
    /// to someone who already got the alert.
    var hasOutstandingWork: Bool {
        jobs.contains { $0.status != .sent || $0.needsLinkFollowUp }
    }

    @discardableResult
    func enqueue(
        sessionId: String,
        recipients: [String],
        subject: String,
        bodyNote: String,
        includeTime: Bool,
        includeLocation: Bool,
        authManager: GoogleAuthManager
    ) -> EmailJob {
        let location = includeLocation ? locationManager?.freshLocation() : nil
        let job = EmailJob(
            sessionId: sessionId,
            recipients: recipients,
            subject: subject,
            bodyNote: bodyNote,
            includeTime: includeTime,
            includeLocation: includeLocation,
            address: location.flatMap { locationManager?.address(for: $0) },
            latitude: location?.coordinate.latitude,
            longitude: location?.coordinate.longitude
        )
        jobs.insert(job, at: 0)
        save()
        startSending(job, authManager: authManager)
        return job
    }
    
    /// Restarts every unsent job that isn't already running. `retryFailed`
    /// also gives jobs that ran out of tries a fresh set.
    func resumeAll(authManager: GoogleAuthManager, retryFailed: Bool) {
        for job in jobs where job.status != .sent && activeTasks[job.id] == nil {
            if job.status == .failed && !retryFailed { continue }
            startSending(job, authManager: authManager)
        }
        // Covers a follow-up that was owed when the app was killed.
        for sessionId in Set(jobs.filter(\.needsLinkFollowUp).map(\.sessionId)) {
            sendLinkFollowUps(forSessionId: sessionId, authManager: authManager)
        }
    }

    /// Sends the recording link to anyone whose alert went out before the
    /// session's Drive folder existed. Called when the folder is created, and
    /// does nothing until then.
    func sendLinkFollowUps(forSessionId sessionId: String, authManager: GoogleAuthManager) {
        guard sessionStore?.sessions.first(where: { $0.id == sessionId })?.driveFolderId != nil else { return }
        let owed = jobs.filter { $0.sessionId == sessionId && $0.status == .sent && $0.needsLinkFollowUp }
        for original in owed {
            original.needsLinkFollowUp = false
            let followUp = EmailJob(
                createdAt: original.createdAt,
                sessionId: sessionId,
                recipients: original.recipients,
                subject: "Recording link: \(original.subject)",
                bodyNote: "The link to the recording wasn't ready when the first email went out. Here it is.",
                includeTime: original.includeTime,
                includeLocation: false,
                address: nil,
                latitude: nil,
                longitude: nil
            )
            followUp.isLinkFollowUp = true
            jobs.insert(followUp, at: 0)
            startSending(followUp, authManager: authManager)
        }
        if !owed.isEmpty { save() }
    }
    
    /// Manual retry from the dashboard UI.
    func retry(_ job: EmailJob, authManager: GoogleAuthManager) {
        startSending(job, authManager: authManager)
    }
    
    /// Drops every job tied to a session (e.g. when the session is deleted).
    /// In-flight sends are cancelled first so they don't outlive the session.
    func removeJobs(forSessionId sessionId: String) {
        let toRemove = jobs.filter { $0.sessionId == sessionId }
        for job in toRemove {
            activeTasks[job.id]?.cancel()
            activeTasks.removeValue(forKey: job.id)
        }
        jobs.removeAll(where: { $0.sessionId == sessionId })
        save()
    }
    
    /// Fills in the job's location from a fresh fix if it doesn't have one,
    /// waiting briefly for GPS on the first attempt.
    private func resolveLocation(for job: EmailJob, waitUpTo timeout: TimeInterval) async {
        guard job.includeLocation, let locationManager else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let location = locationManager.freshLocation(),
               job.latitude == nil || location.timestamp > job.createdAt {
                job.latitude = location.coordinate.latitude
                job.longitude = location.coordinate.longitude
                // Keep the address paired with the coordinates it came from.
                job.address = locationManager.address(for: location)
            }
            if job.latitude != nil && job.address != nil { return }
            guard Date() < deadline, !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }
    
    /// Waits until the job's session has a Drive folder, or the timeout passes.
    private func waitForFolder(for job: EmailJob, waitUpTo timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            let session = sessionStore?.sessions.first(where: { $0.id == job.sessionId })
            // No session (e.g. deleted) means there's no folder to wait for.
            guard let session, session.driveFolderId == nil else { return }
            guard Date() < deadline, !Task.isCancelled else { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }

    private func startSending(_ job: EmailJob, authManager: GoogleAuthManager) {
        activeTasks[job.id]?.cancel()
        let task = Task { @MainActor in
            let background = BackgroundActivity(name: "Send alert email")
            defer { background.end() }
            // Tries left are counted per run, unlike `job.attempts`, so a job
            // restarted later isn't down to its last try. Offline tries don't count.
            var failures = 0
            while true {
                guard !Task.isCancelled else { return }
                guard job.status != .sent else {
                    self.activeTasks.removeValue(forKey: job.id)
                    return
                }

                job.attempts += 1
                let isFirstTry = job.attempts == 1
                job.lastAttemptAt = Date()
                job.status = .sending
                self.save()

                if isFirstTry {
                    await self.waitForFolder(for: job, waitUpTo: Self.folderWaitTimeout)
                }
                // The location wait counts from when the job was queued, so it
                // overlaps the folder wait instead of adding to it.
                let locationWait = isFirstTry
                    ? max(0, Self.locationWaitTimeout - Date().timeIntervalSince(job.createdAt))
                    : 0
                await self.resolveLocation(for: job, waitUpTo: locationWait)
                
                do {
                    let token = try await authManager.validAccessToken()
                    // Resolve the Drive folder link at send time so the email
                    // picks up the link once the folder is eventually created,
                    // even if it wasn't ready when the job was first queued.
                    let session = self.sessionStore?.sessions
                        .first(where: { $0.id == job.sessionId })
                    let driveLink = session?.driveFolderLink
                    try await GmailService.sendEmergencyEmail(
                        to: job.recipients,
                        subject: job.subject,
                        bodyNote: job.bodyNote,
                        startedAt: job.includeTime ? job.createdAt : nil,
                        address: job.address,
                        latitude: job.latitude,
                        longitude: job.longitude,
                        driveFolderLink: driveLink,
                        accessToken: token
                    )
                    job.status = .sent
                    if driveLink == nil && !job.isLinkFollowUp {
                        job.needsLinkFollowUp = true
                    }
                    self.save()
                    self.activeTasks.removeValue(forKey: job.id)
                    // The folder may have appeared while this was sending.
                    if job.needsLinkFollowUp {
                        self.sendLinkFollowUps(forSessionId: job.sessionId, authManager: authManager)
                    }
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    if RetryPolicy.isOffline(error) {
                        job.status = .pending
                        self.save()
                        await NetworkMonitor.shared.waitForRestoredConnection(upTo: RetryPolicy.maxDelay)
                        continue
                    }
                    failures += 1
                    if failures >= RetryPolicy.maxAttempts {
                        job.status = .failed
                        self.save()
                        self.activeTasks.removeValue(forKey: job.id)
                        print("Email to \(job.recipients.joined(separator: ", ")) failed after \(failures) attempts: \(error.localizedDescription)")
                        return
                    }
                    job.status = .pending
                    self.save()
                    let delay = RetryPolicy.delay(forAttempt: failures)
                    print("Email attempt \(failures) failed, retrying in \(Int(delay))s: \(error.localizedDescription)")
                    await NetworkMonitor.shared.waitForRestoredConnection(upTo: delay)
                }
            }
        }
        activeTasks[job.id] = task
    }
    
    private func save() {
        guard !saveIsBlocked else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(jobs)
            try data.write(to: Self.storageURL, options: .atomic)
        } catch {
            print("Failed to save email jobs: \(error)")
        }
    }
    
    private func load() {
        let url = Self.storageURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        // Before the first unlock the file exists but can't be read. Saving
        // then would replace real jobs with an empty list.
        guard let data = try? Data(contentsOf: url) else {
            saveIsBlocked = true
            return
        }
        saveIsBlocked = false
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            jobs = try decoder.decode([EmailJob].self, from: data)
        } catch {
            print("Failed to load email jobs: \(error)")
            // The next save would replace a file this build can't read with
            // the jobs it knows about, which is none. Keep a copy so the
            // outbox isn't destroyed by a decoding mistake.
            let copy = url.deletingLastPathComponent().appendingPathComponent("email_jobs.unreadable.json")
            try? FileManager.default.removeItem(at: copy)
            try? FileManager.default.copyItem(at: url, to: copy)
        }
    }
}