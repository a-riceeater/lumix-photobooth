import Foundation
import Network
import Observation

/// Background uploader. Works through `ready` sessions oldest-first, one at a
/// time, so capturing never waits for the network:
///   create session → upload missing photos → submit email requests →
///   complete → verify server checksums → mark synced.
/// Every step is idempotent on the server, so retrying after any failure
/// (app restart, network loss, timeout) is safe. Failures back off
/// exponentially and retry immediately when connectivity returns.
@MainActor @Observable
final class UploadQueue {
    private(set) var isOnline = true
    private(set) var activeSessionId: String?
    private(set) var lastError: String?
    private(set) var lastSuccessAt: Date?

    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let urlSession: URLSession
    @ObservationIgnored private var loopTask: Task<Void, Never>?
    @ObservationIgnored private var wake: CheckedContinuation<Void, Never>?
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored var now: () -> Date = Date.init
    @ObservationIgnored var idleInterval: TimeInterval = 15

    init(store: SessionStore, settings: AppSettings, urlSession: URLSession = APIClient.makeURLSession()) {
        self.store = store
        self.settings = settings
        self.urlSession = urlSession
    }

    var pending: [LocalSession] { store.sessions.filter { $0.state == .ready } }
    var failed: [LocalSession] { store.sessions.filter { $0.state == .failed } }

    func start() {
        guard loopTask == nil else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let online = path.status == .satisfied
                if online && !self.isOnline { self.retryNow() }
                self.isOnline = online
            }
        }
        monitor.start(queue: DispatchQueue(label: "photobooth.network"))
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.processDue()
                await self.sleep(self.idleInterval)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
        monitor.cancel()
        trigger()
    }

    /// Wake the loop (new session, new email, connectivity change).
    func trigger() {
        let w = wake
        wake = nil
        w?.resume()
    }

    /// Operator / connectivity: clear backoff and failed states, then run.
    func retryNow(includeFailed: Bool = false) {
        for var s in store.sessions where s.state == .ready || (includeFailed && s.state == .failed) {
            s.nextAttemptAt = nil
            if s.state == .failed { s.state = .ready }
            try? store.update(s)
        }
        trigger()
    }

    private func sleep(_ seconds: TimeInterval) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            wake = c
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                self?.trigger()
            }
        }
    }

    /// One pass over every due session. Public for tests.
    func processDue() async {
        let client = APIClient(baseURL: settings.serverURL, apiKey: settings.apiKey, session: urlSession)
        for s in pending where (s.nextAttemptAt ?? .distantPast) <= now() {
            activeSessionId = s.id
            await process(s.id, client: client)
            activeSessionId = nil
        }
        // Emails added after a session was synced.
        for s in store.sessions where s.state == .synced && !s.pendingEmails.isEmpty {
            await sendEmails(s.id, client: client)
        }
        _ = store.applyRetention(settings.retention, days: settings.retentionDays)
    }

    private func process(_ id: String, client: APIClient) async {
        do {
            guard var s = store.session(id) else { return }
            if !s.serverCreated {
                try await client.createSession(s, deviceName: settings.deviceName)
                s.serverCreated = true
                try store.update(s)
            }
            for photo in s.photos where !photo.uploaded {
                try await client.uploadPhoto(sessionId: id, index: photo.index, sha256: photo.sha256,
                                             file: store.photoURL(s, index: photo.index))
                guard var cur = store.session(id), let i = cur.photos.firstIndex(where: { $0.index == photo.index }) else { return }
                cur.photos[i].uploaded = true
                try store.update(cur)
            }
            await sendEmails(id, client: client)
            s = store.session(id) ?? s
            try await client.complete(sessionId: id, sha256: s.photos.sorted { $0.index < $1.index }.map(\.sha256))
            // Verify before declaring success: the server must hold exactly our bytes.
            let status = try await client.status(sessionId: id)
            let expected = Dictionary(uniqueKeysWithValues: s.photos.map { ($0.index, $0.sha256) })
            let actual = Dictionary(uniqueKeysWithValues: status.photos.map { ($0.index, $0.sha256) })
            guard status.status == "complete", status.missing.isEmpty, expected == actual else {
                // Re-upload anything that does not match on the next pass.
                var cur = store.session(id) ?? s
                for i in cur.photos.indices where actual[cur.photos[i].index] != cur.photos[i].sha256 { cur.photos[i].uploaded = false }
                try store.update(cur)
                throw APIError.http(status: 500, code: "verify_failed", message: "server copy does not match")
            }
            var done = store.session(id) ?? s
            done.serverCompleted = true
            done.state = .synced
            done.syncedAt = now()
            done.lastError = nil
            done.nextAttemptAt = nil
            try store.update(done)
            lastSuccessAt = now()
            lastError = nil
        } catch {
            fail(id, error)
        }
    }

    private func sendEmails(_ id: String, client: APIClient) async {
        guard let s = store.session(id) else { return }
        for req in s.pendingEmails {
            do {
                try await client.requestEmail(sessionId: id, address: req.address!)
                mark(id, req.id, note: nil)
            } catch let e as APIError {
                switch e {
                case .http(400, _, _): mark(id, req.id, note: "rejected as invalid")
                case .http(503, _, _): mark(id, req.id, note: "email disabled on server")
                case .http(429, _, _) where s.state == .synced: mark(id, req.id, note: "email limit reached")
                default: break   // retried with the session
                }
            } catch {}
        }
    }

    /// The server has the request; forget the address on the device.
    private func mark(_ id: String, _ reqId: UUID, note: String?) {
        guard var s = store.session(id), let i = s.emails.firstIndex(where: { $0.id == reqId }) else { return }
        s.emails[i].delivered = note == nil
        s.emails[i].address = nil
        s.emails[i].note = note
        try? store.update(s)
    }

    private func fail(_ id: String, _ error: Error) {
        guard var s = store.session(id) else { return }
        let api = error as? APIError
        s.attempts += 1
        s.lastError = api?.errorDescription ?? error.localizedDescription
        if let api, !api.isTransient, api != .missingAPIKey, api != .invalidServerURL, api != .unauthorized {
            // e.g. 409 conflict: needs the operator; keep the files untouched.
            s.state = .failed
        } else {
            let delay = min(5 * pow(2, Double(min(s.attempts, 8) - 1)), 300)
            s.nextAttemptAt = now().addingTimeInterval(delay)
        }
        lastError = s.lastError
        try? store.update(s)
    }
}
