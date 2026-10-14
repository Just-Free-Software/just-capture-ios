import Foundation
import Observation

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
}

/// Persistent outbox for emergency-alert emails. Enqueued jobs are stored to
/// disk so they survive a kill/relaunch mid-outage; on each launch unsent jobs
/// are resumed. Each send is retried with exponential backoff up to
/// `RetryPolicy.maxAttempts`; after that the job is left as `.failed` for a
/// manual retry from the dashboard.
@Observable
class EmailQueueManager {
    var jobs: [EmailJob] = []
    weak var sessionStore: SessionStore?
    
    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private static var storageURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("email_jobs.json")
    }
    
    init() {
        load()
        // Any job that was mid-send when the process died is left in `.sending`
        // on disk; reset those so resumeAll picks them up cleanly.
        for job in jobs where job.status == .sending {
            job.status = .pending
        }
        if !jobs.isEmpty { save() }
    }
    
    @discardableResult
    func enqueue(
        sessionId: String,
        recipients: [String],
        subject: String,
        bodyNote: String,
        includeTime: Bool,
        address: String?,
        latitude: Double?,
        longitude: Double?,
        authManager: GoogleAuthManager
    ) -> EmailJob {
        let job = EmailJob(
            sessionId: sessionId,
            recipients: recipients,
            subject: subject,
            bodyNote: bodyNote,
            includeTime: includeTime,
            address: address,
            latitude: latitude,
            longitude: longitude
        )
        jobs.insert(job, at: 0)
        save()
        startSending(job, authManager: authManager)
        return job
    }
    
    /// Re-attempt every job that isn't yet confirmed sent. Called from the app
    /// entrypoint after sign-in is restored.
    func resumeAll(authManager: GoogleAuthManager) {
        for job in jobs where job.status != .sent {
            startSending(job, authManager: authManager)
        }
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
    
    private func startSending(_ job: EmailJob, authManager: GoogleAuthManager) {
        activeTasks[job.id]?.cancel()
        let task = Task { @MainActor in
            var attempt = job.attempts
            while true {
                guard !Task.isCancelled else { return }
                guard job.status != .sent else { return }
                
                attempt += 1
                job.attempts = attempt
                job.lastAttemptAt = Date()
                job.status = .sending
                self.save()
                
                do {
                    let token = try await authManager.validAccessToken()
                    // Resolve the Drive folder link at send time so the email
                    // picks up the link once the folder is eventually created,
                    // even if it wasn't ready when the job was first queued.
                    let driveLink = self.sessionStore?.sessions
                        .first(where: { $0.id == job.sessionId })?
                        .driveFolderLink
                    try await GmailService.sendEmergencyEmail(
                        to: job.recipients,
                        subject: job.subject,
                        bodyNote: job.bodyNote,
                        includeTime: job.includeTime,
                        address: job.address,
                        latitude: job.latitude,
                        longitude: job.longitude,
                        driveFolderLink: driveLink,
                        accessToken: token
                    )
                    job.status = .sent
                    self.save()
                    return
                } catch {
                    if attempt >= RetryPolicy.maxAttempts {
                        job.status = .failed
                        self.save()
                        print("🛑 Email to \(job.recipients.joined(separator: ", ")) failed after \(attempt) attempts: \(error.localizedDescription)")
                        return
                    }
                    job.status = .pending
                    self.save()
                    let delay = RetryPolicy.delay(forAttempt: attempt)
                    print("📤 Email attempt \(attempt) failed, retrying in \(Int(delay))s: \(error.localizedDescription)")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        activeTasks[job.id] = task
    }
    
    private func save() {
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
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            jobs = try decoder.decode([EmailJob].self, from: data)
        } catch {
            print("Failed to load email jobs: \(error)")
        }
    }
}