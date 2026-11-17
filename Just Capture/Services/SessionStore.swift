import Foundation

@Observable
class SessionStore {
    var sessions: [RecordingSession] = []
    /// Sessions still marked as recording when they were loaded, meaning the
    /// app died mid-recording. They may have clips that were never listed.
    private(set) var interruptedSessionIDs: Set<String> = []
    /// The saved sessions couldn't be read, so saving now would overwrite them.
    private(set) var saveIsBlocked = false

    private static var storageURL: URL {
        let paths = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        return paths[0].appendingPathComponent("sessions.json")
    }
    
    init() {
        load()
    }
    
    var currentSession: RecordingSession? {
        sessions.first(where: { $0.isActive }) ?? sessions.first
    }
    
    func add(_ session: RecordingSession) {
        sessions.insert(session, at: 0)
        save()
    }
    
    /// Removes a session from disk: deletes its local recording directory and
    /// drops it from the in-memory list. Callers are responsible for cancelling
    /// any in-flight uploads and removing related email jobs before calling
    /// this so nothing races back in and re-creates state.
    func delete(_ session: RecordingSession) {
        try? FileManager.default.removeItem(at: session.directoryURL)
        sessions.removeAll(where: { $0.id == session.id })
        save()
    }
    
    /// Loads the saved sessions if a launch before the first unlock couldn't.
    func reloadIfNeeded() {
        if saveIsBlocked { load() }
    }

    func clearInterruptedSessions() {
        interruptedSessionIDs = []
    }

    func save() {
        guard !saveIsBlocked else { return }
        do {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(sessions)
            try data.write(to: Self.storageURL, options: .atomic)
        } catch {
            print("Failed to save sessions: \(error)")
        }
    }
    
    private func load() {
        let url = Self.storageURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        // Before the first unlock the file exists but can't be read. Saving
        // then would replace real sessions with an empty list.
        guard let data = try? Data(contentsOf: url) else {
            saveIsBlocked = true
            return
        }
        saveIsBlocked = false
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            sessions = try decoder.decode([RecordingSession].self, from: data)
            // Any session flagged active on disk was interrupted by a kill/relaunch;
            // finalize it so it stops appearing as "in progress". Chunk paths
            // are rebuilt because the container path may have changed.
            for session in sessions {
                if session.isActive { interruptedSessionIDs.insert(session.id) }
                session.isActive = false
                for chunk in session.chunks {
                    chunk.localURL = session.directoryURL.appendingPathComponent(chunk.fileName)
                }
            }
            if !sessions.isEmpty {
                save()
            }
        } catch {
            print("Failed to load sessions: \(error)")
        }
    }
}