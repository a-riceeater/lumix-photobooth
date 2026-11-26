import AudioToolbox
import CoreGraphics
import Foundation
import ImageIO
import Observation

/// The guest workflow:
/// welcome → countdown → capture (× N) → review → share (QR + optional email) → welcome.
@MainActor @Observable
final class BoothController {
    enum Phase: Equatable {
        case welcome
        case countdown(shot: Int, remaining: Int)
        case capturing(shot: Int)
        /// The photo just taken, shown fullscreen for a moment.
        case showingShot(shot: Int)
        /// Wi-Fi camera: photos are being fetched from the camera's card.
        case transferring(received: Int, total: Int)
        case review
        case share
        case problem(String)
    }

    private(set) var phase: Phase = .welcome
    /// Downsampled copies of this session's photos for review/share screens.
    private(set) var thumbnails: [CGImage] = []
    /// Incremented on each capture to drive the flash animation.
    private(set) var flashCounter = 0
    private(set) var currentSessionId: String?
    private(set) var retryMessage: String?
    /// Seconds left before an automatic transition (review / share screens).
    private(set) var autoAdvanceRemaining: Int?
    /// Retakes used in the current session.
    private(set) var retakesUsed = 0

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private let uploads: UploadQueue
    @ObservationIgnored private let cameraProvider: () -> CameraService
    @ObservationIgnored private var flowTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored var tick: UInt64 = 1_000_000_000   // one "second" in ns; tests shorten this
    @ObservationIgnored private let clock = ContinuousClock()
    private var unit: Duration { .nanoseconds(Int64(tick)) }
    /// Real seconds scaled by `tick` (so tests run fast).
    private func seconds(_ s: Double) -> Duration { .nanoseconds(Int64(s * Double(tick))) }

    init(settings: AppSettings, store: SessionStore, uploads: UploadQueue, camera: @escaping () -> CameraService) {
        self.settings = settings
        self.store = store
        self.uploads = uploads
        self.cameraProvider = camera
    }

    var camera: CameraService { cameraProvider() }
    var currentSession: LocalSession? { currentSessionId.flatMap { store.session($0) } }
    var totalShots: Int { max(1, min(settings.photosPerSession, 12)) }
    var canRetake: Bool { settings.allowRetake && (settings.maxRetakes == 0 || retakesUsed < settings.maxRetakes) }

    // MARK: Guest actions

    func start() {
        guard phase == .welcome || isProblem else { return }
        flowTask?.cancel()
        flowTask = Task { await runCapture(newSession: true) }
    }

    func retake() {
        guard phase == .review, canRetake, let id = currentSessionId else { return }
        retakesUsed += 1
        timerTask?.cancel()
        autoAdvanceRemaining = nil
        flowTask = Task {
            // The camera can't shoot until the previous originals are saved.
            if let pending = originalsTask {
                phase = .transferring(received: 0, total: max(1, thumbnails.count))
                _ = await pending.value
            }
            try? store.discardPhotosForRetake(sessionId: id)
            thumbnails.removeAll()
            await runCapture(newSession: false)
        }
    }

    func accept() {
        guard phase == .review, let id = currentSessionId else { return }
        finalizeWhenPhotosSaved(id)
        enter(.share, timeout: settings.resetTimeoutSeconds) { [weak self] in self?.finish() }
    }

    func submitEmail(_ address: String) -> Bool {
        guard let id = currentSessionId, isValidEmail(address.trimmingCharacters(in: .whitespaces)) else { return false }
        try? store.addEmail(sessionId: id, address: address)
        uploads.trigger()
        return true
    }

    /// Any touch on review/share screens restarts the inactivity timer.
    func noteActivity() {
        switch phase {
        case .review: restartTimer(settings.reviewTimeoutSeconds) { [weak self] in self?.accept() }
        case .share: restartTimer(settings.resetTimeoutSeconds) { [weak self] in self?.finish() }
        default: break
        }
    }

    func finish() {
        flowTask?.cancel()
        timerTask?.cancel()
        autoAdvanceRemaining = nil
        // Safety net: never leave a captured session un-queued.
        if let id = currentSessionId, store.session(id)?.state == .capturing { finalizeWhenPhotosSaved(id) }
        currentSessionId = nil
        thumbnails.removeAll()
        retryMessage = nil
        retakesUsed = 0
        phase = .welcome
        uploads.trigger()
    }

    private var isProblem: Bool { if case .problem = phase { return true } else { return false } }

    // MARK: Flow

    private func runCapture(newSession: Bool) async {
        pendingOnCamera.removeAll()
        if newSession {
            guard camera.state.isReady else {
                await showProblem("The camera is getting ready. Please try again in a moment.")
                return
            }
            do {
                let s = try store.create(eventId: settings.eventId, eventName: settings.eventName, photoCount: totalShots,
                                         designId: settings.defaultDesignId, galleryBaseURL: settings.galleryBaseURL)
                currentSessionId = s.id
                thumbnails.removeAll()
                retakesUsed = 0
            } catch {
                await showProblem("Something went wrong. Please try again.")
                return
            }
        }
        guard let id = currentSessionId else { return }

        for shot in 0..<totalShots {
            var attempt = 0
            while true {
                let base = shot == 0 ? settings.countdownSeconds : settings.betweenPhotosCountdownSeconds
                let countdown = attempt == 0 ? base : min(3, base)
                // The camera works on its own schedule so the exposure lands on
                // the cue ("Smile!") instead of after it: autofocus starts
                // `focusLeadTime` early, the shutter fires `shutterLead` early.
                let clock = self.clock
                let cam = camera
                let cue = clock.now + unit * max(1, countdown)
                let shutterAt = cue - seconds(Double(settings.shutterLeadMilliseconds) / 1000)
                let focusAt = shutterAt - seconds(cam.focusLeadTime)
                let captureTask = Task { () throws -> CaptureResult in
                    try await clock.sleep(until: max(focusAt, clock.now))
                    try await cam.prepareCapture()
                    try await clock.sleep(until: max(shutterAt, clock.now))
                    return try await cam.capture()
                }
                for remaining in stride(from: max(1, countdown), through: 1, by: -1) {
                    phase = .countdown(shot: shot, remaining: remaining)
                    playSound(.tick)
                    try? await clock.sleep(until: cue - unit * (remaining - 1))
                    if Task.isCancelled { captureTask.cancel(); return }
                }
                phase = .capturing(shot: shot)
                playSound(.shutter)
                if settings.flashEffect { flashCounter += 1 }
                do {
                    switch try await captureTask.value {
                    case .jpeg(let jpeg):
                        try await store.addPhoto(sessionId: id, index: shot, jpeg: jpeg)
                        if let t = await Self.thumbnail(jpeg) { thumbnails.append(t) }
                    case .storedOnCamera:
                        // Fetched after the last shot; until then show the
                        // live-view frame from the moment of capture.
                        pendingOnCamera.append(shot)
                        if let frame = camera.preview.image { thumbnails.append(frame) }
                    }
                    retryMessage = nil
                    break
                } catch {
                    if Task.isCancelled { return }
                    attempt += 1
                    if attempt >= 3 {
                        // Keep what we have; it uploads as a shorter session.
                        if store.session(id)?.photos.isEmpty == false {
                            try? store.finalize(sessionId: id)
                            uploads.trigger()
                        }
                        currentSessionId = nil
                        await showProblem(Self.guestMessage(for: error))
                        return
                    }
                    retryMessage = (error as? CaptureError) == .focusFailed
                        ? "Hmm, that one was blurry. Let's try again!"
                        : "Oops, let's try that one again!"
                }
            }
            // Show the shot so guests can see it and reset their pose.
            let pause = settings.postCapturePreviewSeconds
            if pause > 0 {
                phase = .showingShot(shot: shot)
                try? await Task.sleep(nanoseconds: tick * UInt64(pause))
                if Task.isCancelled { return }
            }
        }

        if !pendingOnCamera.isEmpty {
            let ok = settings.wifiQuickPreviews
                ? await startQuickTransfer(sessionId: id)
                : await transferPhotosFromCamera(sessionId: id)
            guard ok else { return }
        }

        if canRetake {
            enter(.review, timeout: settings.reviewTimeoutSeconds) { [weak self] in self?.accept() }
        } else {
            phase = .review
            accept()
        }
    }

    /// Shots taken by a Wi-Fi camera that still have to be fetched.
    private var pendingOnCamera: [Int] = []
    /// Background download of the originals after quick previews (true = saved).
    private var originalsTask: Task<Bool, Never>?

    /// Queues the session for upload once every photo is on disk (immediately
    /// unless originals are still arriving in the background).
    private func finalizeWhenPhotosSaved(_ id: String) {
        let finalize = { [weak self] in
            guard let self, self.store.session(id)?.state == .capturing else { return }
            try? self.store.finalize(sessionId: id)
            self.uploads.trigger()
        }
        if let pending = originalsTask {
            Task { if await pending.value { finalize() } }
        } else {
            finalize()
        }
    }

    /// Quick previews → review right away; originals continue in the background.
    private func startQuickTransfer(sessionId id: String) async -> Bool {
        let shots = pendingOnCamera
        phase = .transferring(received: 0, total: shots.count)
        let previews: [Data]
        do {
            previews = try await camera.collectPreviews(count: shots.count)
        } catch {
            return await transferPhotosFromCamera(sessionId: id)   // camera is back in shooting mode
        }
        pendingOnCamera.removeAll()
        guard previews.count == shots.count else {
            // No previews: wait for the originals in the foreground.
            let ok = await saveOriginals(sessionId: id, shots: shots, showProgress: true)
            if !ok { await failTransfer(sessionId: id) }
            return ok
        }
        var quick: [CGImage] = []
        for p in previews { if let t = await Self.thumbnail(p) { quick.append(t) } }
        thumbnails = quick
        let task = Task { [weak self] () -> Bool in
            guard let self else { return false }
            let ok = await self.saveOriginals(sessionId: id, shots: shots, showProgress: false)
            if !ok {
                self.store.markNeedsAttention(sessionId: id, message: "Photos are still on the camera's card (newest \(shots.count)); they could not be transferred over Wi-Fi.")
            }
            self.originalsTask = nil
            return ok
        }
        originalsTask = task
        return true
    }

    /// Downloads the originals (one retry by re-listing the newest photos) and stores them.
    private func saveOriginals(sessionId id: String, shots: [Int], showProgress: Bool) async -> Bool {
        let progress: @MainActor (Int) -> Void = { [weak self] n in
            if showProgress { self?.phase = .transferring(received: n, total: shots.count) }
        }
        var photos = (try? await camera.collectOriginals(progress: progress)) ?? []
        if photos.count != shots.count {
            photos = (try? await camera.collectPhotos(count: shots.count, progress: progress)) ?? []
        }
        guard photos.count == shots.count else { return false }
        for (k, shot) in shots.enumerated() {
            guard (try? await store.addPhoto(sessionId: id, index: shot, jpeg: photos[k])) != nil else { return false }
        }
        if showProgress {
            var rebuilt: [CGImage] = []
            for p in photos { if let t = await Self.thumbnail(p) { rebuilt.append(t) } }
            thumbnails = rebuilt
        }
        return true
    }

    private func failTransfer(sessionId id: String) async {
        store.markNeedsAttention(sessionId: id, message: "Photos are still on the camera's card; they could not be transferred over Wi-Fi.")
        currentSessionId = nil
        await showProblem("Your photos are safe on the camera, but we couldn't bring them over. Please ask the booth host for help.")
    }

    /// Fetches the session's photos from the camera, stores them, rebuilds the
    /// thumbnails. On failure the photos stay safe on the camera's card.
    private func transferPhotosFromCamera(sessionId id: String) async -> Bool {
        let shots = pendingOnCamera
        pendingOnCamera.removeAll()
        phase = .transferring(received: 0, total: shots.count)
        var lastError: Error?
        for _ in 0..<2 {
            do {
                let photos = try await camera.collectPhotos(count: shots.count) { [weak self] received in
                    self?.phase = .transferring(received: received, total: shots.count)
                }
                guard photos.count == shots.count else { throw CaptureError.noImage }
                for (k, shot) in shots.enumerated() {
                    try await store.addPhoto(sessionId: id, index: shot, jpeg: photos[k])
                }
                var rebuilt: [CGImage] = []
                if let s = store.session(id) {
                    for p in s.photos.sorted(by: { $0.index < $1.index }) {
                        if let data = try? Data(contentsOf: store.photoURL(s, index: p.index)), let t = await Self.thumbnail(data) { rebuilt.append(t) }
                    }
                }
                thumbnails = rebuilt
                return true
            } catch {
                lastError = error
                if Task.isCancelled { return false }
            }
        }
        if store.session(id)?.photos.isEmpty == false {
            try? store.finalize(sessionId: id)
            uploads.trigger()
        }
        currentSessionId = nil
        _ = lastError
        await showProblem("Your photos are safe on the camera, but we couldn't bring them over. Please ask the booth host for help.")
        return false
    }

    private func showProblem(_ message: String) async {
        phase = .problem(message)
        try? await Task.sleep(nanoseconds: tick * 5)
        if isProblem { finish() }
    }

    private func enter(_ p: Phase, timeout: Int, then action: @escaping () -> Void) {
        phase = p
        restartTimer(timeout, action)
    }

    private func restartTimer(_ seconds: Int, _ action: @escaping () -> Void) {
        timerTask?.cancel()
        autoAdvanceRemaining = seconds
        timerTask = Task { [weak self] in
            var left = seconds
            while left > 0 {
                try? await Task.sleep(nanoseconds: self?.tick ?? 1_000_000_000)
                if Task.isCancelled { return }
                left -= 1
                self?.autoAdvanceRemaining = left
            }
            action()
        }
    }

    private enum Sound: SystemSoundID {
        case tick = 1103      // keyboard tock
        case shutter = 1108   // camera shutter
    }

    private func playSound(_ s: Sound) {
        guard settings.countdownSounds else { return }
        AudioServicesPlaySystemSound(s.rawValue)
    }

    static func guestMessage(for error: Error) -> String {
        switch error as? CaptureError {
        case .focusFailed: return "The camera couldn't focus. Step into the light and try again!"
        case .notConnected: return "The camera is taking a short break. Please try again in a moment."
        default: return "Sorry, the camera didn't take that photo. Please try again!"
        }
    }

    nonisolated static func thumbnail(_ jpeg: Data, maxPixel: Int = 900) async -> CGImage? {
        await Task.detached(priority: .userInitiated) {
            guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
        }.value
    }
}
