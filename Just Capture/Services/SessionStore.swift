import Foundation

@Observable
class SessionStore {
    var sessions: [RecordingSession] = []
    
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
    
    func save() {
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
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            sessions = try decoder.decode([RecordingSession].self, from: data)
            // Any session flagged active on disk was interrupted by a kill/relaunch;
            // finalize it so it stops appearing as "in progress". Chunk paths
            // are rebuilt because the container path may have changed.
            for session in sessions {
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