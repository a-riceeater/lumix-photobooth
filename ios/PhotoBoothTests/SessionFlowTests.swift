import XCTest
@testable import PhotoBooth

/// In-memory stand-in for the server API, plugged into URLSession.
final class FakeServer: URLProtocol {
    struct Session { var photoCount: Int; var photos: [Int: String] = [:]; var complete = false; var emails: [String] = [] }
    nonisolated(unsafe) static var sessions: [String: Session] = [:]
    nonisolated(unsafe) static var failPhotoUploads = 0
    nonisolated(unsafe) static var offline = false
    nonisolated(unsafe) static var corruptStatus = false
    nonisolated(unsafe) static var requests: [String] = []
    static let lock = NSLock()

    static func reset() {
        lock.withLock { sessions = [:]; failPhotoUploads = 0; offline = false; corruptStatus = false; requests = [] }
    }

    static func urlSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [FakeServer.self]
        return URLSession(configuration: c)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (status, body) = Self.lock.withLock { Self.handle(request) }
        if status < 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func json(_ r: URLRequest) -> [String: Any] {
        var data = r.httpBody
        if data == nil, let stream = r.httpBodyStream {
            stream.open(); defer { stream.close() }
            var d = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; d.append(buf, count: n) }
            data = d
        }
        return (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
    }

    private static func handle(_ r: URLRequest) -> (Int, [String: Any]) {
        if offline { return (-1, [:]) }
        let url = r.url!
        let path = url.path
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        requests.append("\(r.httpMethod!) \(path)")
        guard r.value(forHTTPHeaderField: "Authorization") == "Bearer test-key" || path == "/api/config" else { return (401, ["error": "unauthorized"]) }
        let parts = path.split(separator: "/").map(String.init)   // api, sessions, id, action
        if path == "/api/config" { return (200, ["publicBaseUrl": "https://photos.test", "emailEnabled": true, "authenticated": true, "maxUploadBytes": 1]) }
        if r.httpMethod == "POST", path == "/api/sessions" {
            let b = json(r)
            let id = b["id"] as! String
            if sessions[id] == nil { sessions[id] = Session(photoCount: b["photoCount"] as! Int) }
            return (201, [:])
        }
        guard parts.count >= 3, var s = sessions[parts[2]] else { return (404, ["error": "not_found"]) }
        let id = parts[2]
        switch (r.httpMethod!, parts.count > 3 ? parts[3] : "") {
        case ("POST", "photos"):
            if failPhotoUploads > 0 { failPhotoUploads -= 1; return (500, ["error": "boom"]) }
            let idx = Int(q.first { $0.name == "index" }!.value!)!
            let sha = q.first { $0.name == "sha256" }!.value!
            if let existing = s.photos[idx] { return existing == sha ? (200, ["duplicate": true]) : (409, ["error": "conflict"]) }
            s.photos[idx] = sha
        case ("POST", "email"):
            s.emails.append(json(r)["email"] as! String)
            sessions[id] = s
            return (202, ["status": "pending"])
        case ("POST", "complete"):
            if s.photos.count < s.photoCount { return (409, ["error": "conflict"]) }
            s.complete = true
        case ("GET", "status"):
            let photos = s.photos.sorted { $0.key < $1.key }.map { ["index": $0.key, "sha256": corruptStatus ? "bad" : $0.value] as [String: Any] }
            return (200, ["id": id, "status": s.complete ? "complete" : "uploading", "photoCount": s.photoCount, "photos": photos,
                          "missing": [Int](), "galleryUrl": "https://photos.test/s/\(id)"])
        default: return (404, [:])
        }
        sessions[id] = s
        return (201, [:])
    }
}

@MainActor
final class SessionFlowTests: XCTestCase {
    var root: URL!
    var settings: AppSettings!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        settings = AppSettings(defaults: defaults)
        settings.serverURL = "https://upload.test"
        settings.apiKey = "test-key"
        settings.eventId = "test-event"
        settings.countdownSeconds = 1
        FakeServer.reset()
    }

    private func jpeg(_ n: Int) -> Data { MockScene.jpeg(MockScene.render(width: 300, height: 200, time: Double(n), label: "\(n)")!)! }

    private func readySession(_ store: SessionStore, photos: Int = 3) async throws -> LocalSession {
        let s = try store.create(eventId: "test-event", eventName: "Test", photoCount: photos, designId: nil, galleryBaseURL: "https://photos.test")
        for i in 0..<photos { try await store.addPhoto(sessionId: s.id, index: i, jpeg: jpeg(i)) }
        try store.finalize(sessionId: s.id)
        return store.session(s.id)!
    }

    // MARK: Store

    func testPhotosPersistAcrossRestartsAndAreNeverOverwritten() async throws {
        let store = SessionStore(root: root)
        let s = try store.create(eventId: "e", eventName: "E", photoCount: 3, designId: nil, galleryBaseURL: "https://x")
        try await store.addPhoto(sessionId: s.id, index: 0, jpeg: jpeg(0))
        do {
            try await store.addPhoto(sessionId: s.id, index: 0, jpeg: jpeg(1))
            XCTFail("overwrite must fail")
        } catch StorageError.alreadyExists {}
        XCTAssertEqual(try Data(contentsOf: store.photoURL(store.session(s.id)!, index: 0)), jpeg(0))
        do {
            try await store.addPhoto(sessionId: s.id, index: 1, jpeg: Data([1, 2, 3, 4]))
            XCTFail("non-JPEG must fail")
        } catch StorageError.notJPEG {}

        // App killed mid-capture: the session is recovered with the photos it has.
        let reloaded = SessionStore(root: root)
        let r = try XCTUnwrap(reloaded.session(s.id))
        XCTAssertEqual(r.state, .ready)
        XCTAssertEqual(r.photoCount, 1)
        XCTAssertEqual(r.photos.first?.sha256.count, 64)
    }

    func testRetakeKeepsDiscardedPhotosAside() async throws {
        let store = SessionStore(root: root)
        let s = try store.create(eventId: "e", eventName: "E", photoCount: 1, designId: nil, galleryBaseURL: "https://x")
        try await store.addPhoto(sessionId: s.id, index: 0, jpeg: jpeg(0))
        try store.discardPhotosForRetake(sessionId: s.id)
        XCTAssertTrue(store.session(s.id)!.photos.isEmpty)
        let retakes = store.directory(for: s).appendingPathComponent("retakes")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: retakes.path).count, 1)
        try await store.addPhoto(sessionId: s.id, index: 0, jpeg: jpeg(1))
    }

    // MARK: Uploads

    func testUploadsVerifyAndMarkSynced() async throws {
        let store = SessionStore(root: root)
        let s = try await readySession(store)
        try store.addEmail(sessionId: s.id, address: "guest@example.com")
        let q = UploadQueue(store: store, settings: settings, urlSession: FakeServer.urlSession())
        await q.processDue()
        let done = try XCTUnwrap(store.session(s.id))
        XCTAssertEqual(done.state, .synced)
        XCTAssertEqual(done.uploadedCount, 3)
        XCTAssertEqual(FakeServer.sessions[s.id]?.complete, true)
        XCTAssertEqual(FakeServer.sessions[s.id]?.emails, ["guest@example.com"])
        XCTAssertNil(done.emails.first?.address, "address is forgotten once the server has it")
        XCTAssertTrue(done.emails.first?.delivered ?? false)
    }

    func testInterruptedUploadResumesWithoutDuplicates() async throws {
        let store = SessionStore(root: root)
        let s = try await readySession(store)
        let q = UploadQueue(store: store, settings: settings, urlSession: FakeServer.urlSession())
        FakeServer.failPhotoUploads = 1
        // First pass: photo 0 fails (500) → backoff.
        await q.processDue()
        var cur = try XCTUnwrap(store.session(s.id))
        XCTAssertEqual(cur.state, .ready)
        XCTAssertEqual(cur.attempts, 1)
        XCTAssertNotNil(cur.nextAttemptAt)

        // Not due yet: nothing happens.
        await q.processDue()
        XCTAssertEqual(store.session(s.id)!.attempts, 1)

        // Simulate an app restart, then the retry succeeds.
        let store2 = SessionStore(root: root)
        let q2 = UploadQueue(store: store2, settings: settings, urlSession: FakeServer.urlSession())
        q2.retryNow()
        await q2.processDue()
        cur = try XCTUnwrap(store2.session(s.id))
        XCTAssertEqual(cur.state, .synced)
        XCTAssertEqual(FakeServer.sessions[s.id]?.photos.count, 3)
    }

    func testOfflineKeepsSessionQueued() async throws {
        let store = SessionStore(root: root)
        let s = try await readySession(store)
        FakeServer.offline = true
        let q = UploadQueue(store: store, settings: settings, urlSession: FakeServer.urlSession())
        await q.processDue()
        XCTAssertEqual(store.session(s.id)?.state, .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.photoURL(s, index: 2).path))
        FakeServer.offline = false
        q.retryNow()
        await q.processDue()
        XCTAssertEqual(store.session(s.id)?.state, .synced)
    }

    func testVerificationMismatchIsNotMarkedSynced() async throws {
        let store = SessionStore(root: root)
        let s = try await readySession(store)
        FakeServer.corruptStatus = true
        let q = UploadQueue(store: store, settings: settings, urlSession: FakeServer.urlSession())
        await q.processDue()
        let cur = try XCTUnwrap(store.session(s.id))
        XCTAssertNotEqual(cur.state, .synced)
        XCTAssertEqual(cur.uploadedCount, 0, "mismatched photos are queued for re-upload")
    }

    func testRetentionDeletesOnlySyncedPhotos() async throws {
        let store = SessionStore(root: root)
        let synced = try await readySession(store)
        let pending = try await readySession(store)
        var s = store.session(synced.id)!
        s.state = .synced
        s.syncedAt = Date()
        try store.update(s)
        XCTAssertEqual(store.applyRetention(.deleteWhenSynced, days: 0), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.photoURL(synced, index: 0).path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.photoURL(pending, index: 0).path))
    }

    // MARK: Booth flow with the mock camera

    func testMockCameraCapturesFullSizeJPEG() async throws {
        let cam = MockCameraService(preferences: { CameraPreferences(mockCaptureSize: CGSize(width: 600, height: 400)) })
        cam.start()
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(cam.state, .ready)
        guard case .jpeg(let data) = try await cam.capture() else { return XCTFail("expected a JPEG") }
        let img = try XCTUnwrap(PreviewFeed.decode(data))
        XCTAssertEqual([img.width, img.height], [600, 400])
        await cam.stop()
    }

    func testFullBoothSessionWithMockCamera() async throws {
        let store = SessionStore(root: root)
        let uploads = UploadQueue(store: store, settings: settings, urlSession: FakeServer.urlSession())
        let cam = MockCameraService(preferences: { CameraPreferences(mockCaptureSize: CGSize(width: 600, height: 400)) })
        cam.start()
        try await Task.sleep(nanoseconds: 700_000_000)
        let booth = BoothController(settings: settings, store: store, uploads: uploads, camera: { cam })
        booth.tick = 10_000_000
        booth.start()
        for _ in 0..<200 where booth.phase != .review { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(booth.phase, .review)
        XCTAssertEqual(booth.thumbnails.count, 3)
        let id = try XCTUnwrap(booth.currentSessionId)

        booth.accept()
        XCTAssertEqual(booth.phase, .share)
        XCTAssertTrue(booth.submitEmail("guest@example.com"))
        XCTAssertFalse(booth.submitEmail("not-an-email"))
        XCTAssertEqual(store.session(id)?.state, .ready)
        XCTAssertEqual(store.session(id)?.galleryURL?.absoluteString.hasPrefix("https://upload.test/s/"), true)

        await uploads.processDue()
        XCTAssertEqual(store.session(id)?.state, .synced)
        booth.finish()
        XCTAssertEqual(booth.phase, .welcome)
        await cam.stop()
    }

    func testRetakeLimitAndTimingSettings() async throws {
        settings.photosPerSession = 2
        settings.betweenPhotosCountdownSeconds = 2
        settings.postCapturePreviewSeconds = 1
        settings.maxRetakes = 1
        settings.countdownSounds = false
        let store = SessionStore(root: root)
        let uploads = UploadQueue(store: store, settings: settings, urlSession: FakeServer.urlSession())
        let cam = MockCameraService(preferences: { CameraPreferences(mockCaptureSize: CGSize(width: 300, height: 200)) })
        cam.start()
        try await Task.sleep(nanoseconds: 700_000_000)
        let booth = BoothController(settings: settings, store: store, uploads: uploads, camera: { cam })
        booth.tick = 10_000_000
        var sawPreview = false
        booth.start()
        for _ in 0..<300 where booth.phase != .review {
            if case .showingShot = booth.phase { sawPreview = true }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(sawPreview)
        XCTAssertTrue(booth.canRetake)
        booth.retake()
        for _ in 0..<300 where booth.phase != .review { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(booth.phase, .review)
        XCTAssertFalse(booth.canRetake, "only one retake allowed")
        booth.retake()   // ignored
        XCTAssertEqual(booth.phase, .review)
        XCTAssertEqual(booth.thumbnails.count, 2)
        await cam.stop()
    }

    func testPhotosDeliveredAfterTheSessionLikeWiFi() async throws {
        settings.photosPerSession = 3
        settings.wifiQuickPreviews = false
        settings.allowRetake = true
        let store = SessionStore(root: root)
        let uploads = UploadQueue(store: store, settings: settings, urlSession: FakeServer.urlSession())
        let cam = MockCameraService(preferences: { CameraPreferences(mockDeferredDelivery: true, mockCaptureSize: CGSize(width: 300, height: 200)) })
        cam.start()
        try await Task.sleep(nanoseconds: 700_000_000)
        let booth = BoothController(settings: settings, store: store, uploads: uploads, camera: { cam })
        booth.tick = 10_000_000
        var sawTransfer = false
        booth.start()
        for _ in 0..<400 where booth.phase != .review {
            if case .transferring = booth.phase { sawTransfer = true }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(sawTransfer, "photos are fetched after the last shot")
        XCTAssertEqual(booth.phase, .review)
        let id = try XCTUnwrap(booth.currentSessionId)
        XCTAssertEqual(store.session(id)?.photos.map(\.index), [0, 1, 2], "all photos stored locally before upload")
        XCTAssertEqual(booth.thumbnails.count, 3)
        await cam.stop()
    }

    func testQuickPreviewsThenOriginalsInTheBackground() async throws {
        settings.photosPerSession = 3
        settings.wifiQuickPreviews = true
        let store = SessionStore(root: root)
        let uploads = UploadQueue(store: store, settings: settings, urlSession: FakeServer.urlSession())
        let cam = MockCameraService(preferences: { CameraPreferences(mockDeferredDelivery: true, mockCaptureSize: CGSize(width: 300, height: 200)) })
        cam.start()
        try await Task.sleep(nanoseconds: 700_000_000)
        let booth = BoothController(settings: settings, store: store, uploads: uploads, camera: { cam })
        booth.tick = 10_000_000
        booth.start()
        for _ in 0..<400 where booth.phase != .review { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(booth.phase, .review)
        let id = try XCTUnwrap(booth.currentSessionId)
        XCTAssertEqual(booth.thumbnails.count, 3, "real previews shown before the originals arrive")
        XCTAssertLessThan(store.session(id)?.photos.count ?? 0, 3, "originals still downloading in the background")
        XCTAssertFalse(cam.state.isReady, "the next guest waits until the originals are saved")

        booth.accept()   // share screen right away; finalize happens after the originals
        XCTAssertEqual(booth.phase, .share)
        for _ in 0..<400 where store.session(id)?.state != .ready { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(store.session(id)?.state, .ready)
        XCTAssertEqual(store.session(id)?.photos.map(\.index), [0, 1, 2])
        XCTAssertTrue(cam.state.isReady)
        await cam.stop()
    }

    func testCaptureFailuresEndInFriendlyProblemAndKeepPhotos() async throws {
        let store = SessionStore(root: root)
        let uploads = UploadQueue(store: store, settings: settings, urlSession: FakeServer.urlSession())
        let cam = MockCameraService(preferences: { CameraPreferences(mockFailureRate: 1, mockCaptureSize: CGSize(width: 300, height: 200)) })
        cam.start()
        try await Task.sleep(nanoseconds: 700_000_000)
        let booth = BoothController(settings: settings, store: store, uploads: uploads, camera: { cam })
        booth.tick = 10_000_000
        booth.start()
        for _ in 0..<200 { if case .problem = booth.phase { break }; try await Task.sleep(nanoseconds: 50_000_000) }
        guard case .problem(let msg) = booth.phase else { return XCTFail("expected problem, got \(booth.phase)") }
        XCTAssertFalse(msg.contains("Error"), "guest message must not be technical")
        XCTAssertTrue(store.sessions.isEmpty, "a session without photos is discarded")
        await cam.stop()
    }
}
