import CryptoKit
import Foundation
import Observation

enum StorageError: Error, LocalizedError {
    case notJPEG
    case alreadyExists(String)
    case unknownSession

    var errorDescription: String? {
        switch self {
        case .notJPEG: return "The camera image is not a JPEG"
        case .alreadyExists(let f): return "\(f) already exists"
        case .unknownSession: return "Unknown session"
        }
    }
}

/// Persistent session queue on disk:
///   Documents/Sessions/<eventId>/<sessionId>/session.json, 01.jpg, 02.jpg …
/// Every photo is written to disk (atomically, never overwriting) before any
/// upload is attempted. The Documents folder is visible in Finder/Files, so
/// the operator can always copy photos off the device by hand.
@MainActor @Observable
final class SessionStore {
    private(set) var sessions: [LocalSession] = []
    let root: URL
    @ObservationIgnored private let fm = FileManager.default
    @ObservationIgnored private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    @ObservationIgnored private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(root: URL? = nil) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.root = root ?? docs.appendingPathComponent("Sessions", isDirectory: true)
        try? fm.createDirectory(at: self.root, withIntermediateDirectories: true,
                                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        load()
    }

    // MARK: Loading / recovery

    /// Reads every session.json. Sessions interrupted mid-capture (app killed)
    /// are finalized with the photos they have, so nothing is lost.
    func load() {
        var out: [LocalSession] = []
        let events = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for ev in events where ev.hasDirectoryPath {
            for dir in (try? fm.contentsOfDirectory(at: ev, includingPropertiesForKeys: nil)) ?? [] where dir.hasDirectoryPath {
                guard let data = try? Data(contentsOf: dir.appendingPathComponent("session.json")),
                      var s = try? decoder.decode(LocalSession.self, from: data) else { continue }
                if s.state == .capturing {
                    if s.photos.isEmpty {
                        try? fm.removeItem(at: dir)
                        continue
                    }
                    s.photoCount = s.photos.count
                    s.state = .ready
                    try? persist(s)
                }
                out.append(s)
            }
        }
        sessions = out.sorted { $0.createdAt < $1.createdAt }
    }

    func directory(for s: LocalSession) -> URL {
        root.appendingPathComponent(s.eventId, isDirectory: true).appendingPathComponent(s.id, isDirectory: true)
    }

    func photoURL(_ s: LocalSession, index: Int) -> URL {
        directory(for: s).appendingPathComponent(LocalSession.filename(for: index))
    }

    func session(_ id: String) -> LocalSession? { sessions.first { $0.id == id } }

    // MARK: Mutations

    func create(eventId: String, eventName: String, photoCount: Int, designId: String?, galleryBaseURL: String) throws -> LocalSession {
        let s = LocalSession(id: LocalSession.newID(), eventId: eventId, eventName: eventName, createdAt: Date(),
                             photoCount: photoCount, designId: designId?.isEmpty == true ? nil : designId,
                             galleryBaseURL: galleryBaseURL)
        try fm.createDirectory(at: directory(for: s), withIntermediateDirectories: true)
        try persist(s)
        sessions.append(s)
        return s
    }

    /// Writes the JPEG atomically and never replaces an existing file.
    func addPhoto(sessionId: String, index: Int, jpeg: Data) async throws {
        guard var s = session(sessionId) else { throw StorageError.unknownSession }
        guard jpeg.count > 3, jpeg[jpeg.startIndex] == 0xFF, jpeg[jpeg.startIndex + 1] == 0xD8 else { throw StorageError.notJPEG }
        let dest = photoURL(s, index: index)
        let dir = directory(for: s)
        let digest = try await Task.detached(priority: .userInitiated) { () throws -> String in
            let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).jpg")
            try jpeg.write(to: tmp, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            do {
                // moveItem fails if dest exists: an original is never overwritten.
                try FileManager.default.moveItem(at: tmp, to: dest)
            } catch {
                try? FileManager.default.removeItem(at: tmp)
                throw StorageError.alreadyExists(dest.lastPathComponent)
            }
            return SHA256.hash(data: jpeg).map { String(format: "%02x", $0) }.joined()
        }.value
        s.photos.removeAll { $0.index == index }
        s.photos.append(.init(index: index, filename: dest.lastPathComponent, sha256: digest, bytes: jpeg.count))
        s.photos.sort { $0.index < $1.index }
        try update(s)
    }

    /// Retake: the current photos are moved to retakes/ (kept, never uploaded).
    func discardPhotosForRetake(sessionId: String) throws {
        guard var s = session(sessionId) else { throw StorageError.unknownSession }
        let dir = directory(for: s)
        let retakes = dir.appendingPathComponent("retakes", isDirectory: true)
        try fm.createDirectory(at: retakes, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        for p in s.photos {
            try? fm.moveItem(at: dir.appendingPathComponent(p.filename), to: retakes.appendingPathComponent("\(stamp)-\(p.filename)"))
        }
        s.photos.removeAll()
        try update(s)
    }

    /// Capture finished: queue for upload. A shortened session keeps the photos it has.
    func finalize(sessionId: String) throws {
        guard var s = session(sessionId) else { throw StorageError.unknownSession }
        if s.photos.isEmpty {
            try? fm.removeItem(at: directory(for: s))
            sessions.removeAll { $0.id == sessionId }
            return
        }
        s.photoCount = s.photos.count
        s.state = .ready
        try update(s)
    }

    /// Operator attention: e.g. photos that stayed on a Wi-Fi camera's card.
    /// The record is kept (even with no photos) so it shows in the upload queue.
    func markNeedsAttention(sessionId: String, message: String) {
        guard var s = session(sessionId) else { return }
        s.state = .failed
        s.lastError = message
        try? update(s)
    }

    func addEmail(sessionId: String, address: String) throws {
        guard var s = session(sessionId) else { throw StorageError.unknownSession }
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.emails.contains(where: { $0.address?.lowercased() == a.lowercased() }) else { return }
        s.emails.append(.init(address: a, masked: maskEmail(a), submittedAt: Date()))
        try update(s)
    }

    func update(_ s: LocalSession) throws {
        try persist(s)
        if let i = sessions.firstIndex(where: { $0.id == s.id }) { sessions[i] = s } else { sessions.append(s) }
    }

    private func persist(_ s: LocalSession) throws {
        let dir = directory(for: s)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try encoder.encode(s).write(to: dir.appendingPathComponent("session.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: Retention

    /// Deletes local photo files of synced sessions according to the policy.
    /// The session record is kept (marked) so the operator can see history.
    func applyRetention(_ policy: RetentionPolicy, days: Int, now: Date = Date()) -> Int {
        var removed = 0
        for s in sessions where s.state == .synced && !s.localFilesDeleted {
            let due: Bool
            switch policy {
            case .keepForever: due = false
            case .deleteWhenSynced: due = true
            case .deleteAfterDays: due = (s.syncedAt ?? s.createdAt) < now.addingTimeInterval(-Double(days) * 86_400)
            }
            guard due else { continue }
            removeLocalPhotos(s)
            removed += 1
        }
        return removed
    }

    func removeLocalPhotos(_ s: LocalSession) {
        var s = s
        let dir = directory(for: s)
        for p in s.photos { try? fm.removeItem(at: dir.appendingPathComponent(p.filename)) }
        try? fm.removeItem(at: dir.appendingPathComponent("retakes"))
        s.localFilesDeleted = true
        try? update(s)
    }

    /// Operator: forget a session entirely (only offered for synced sessions).
    func delete(_ s: LocalSession) {
        try? fm.removeItem(at: directory(for: s))
        sessions.removeAll { $0.id == s.id }
    }

    var localBytes: Int64 {
        sessions.filter { !$0.localFilesDeleted }.reduce(0) { $0 + Int64($1.photos.reduce(0) { $0 + $1.bytes }) }
    }
}
