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

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let store: SessionStore
    @ObservationIgnored private let uploads: UploadQueue
    @ObservationIgnored private let cameraProvider: () -> CameraService
    @ObservationIgnored private var flowTask: Task<Void, Never>?
    @ObservationIgnored private var timerTask: Task<Void, Never>?
    @ObservationIgnored var tick: UInt64 = 1_000_000_000   // tests shorten this

    init(settings: AppSettings, store: SessionStore, uploads: UploadQueue, camera: @escaping () -> CameraService) {
        self.settings = settings
        self.store = store
        self.uploads = uploads
        self.cameraProvider = camera
    }

    var camera: CameraService { cameraProvider() }
    var currentSession: LocalSession? { currentSessionId.flatMap { store.session($0) } }
    var totalShots: Int { max(1, min(settings.photosPerSession, 12)) }

    // MARK: Guest actions

    func start() {
        guard phase == .welcome || isProblem else { return }
        flowTask?.cancel()
        flowTask = Task { await runCapture(newSession: true) }
    }

    func retake() {
        guard phase == .review, let id = currentSessionId else { return }
        try? store.discardPhotosForRetake(sessionId: id)
        thumbnails.removeAll()
        flowTask = Task { await runCapture(newSession: false) }
    }

    func accept() {
        guard phase == .review, let id = currentSessionId else { return }
        try? store.finalize(sessionId: id)
        uploads.trigger()
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
        if let id = currentSessionId, store.session(id)?.state == .capturing { try? store.finalize(sessionId: id) }
        currentSessionId = nil
        thumbnails.removeAll()
        retryMessage = nil
        phase = .welcome
        uploads.trigger()
    }

    private var isProblem: Bool { if case .problem = phase { return true } else { return false } }

    // MARK: Flow

    private func runCapture(newSession: Bool) async {
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
            } catch {
                await showProblem("Something went wrong. Please try again.")
                return
            }
        }
        guard let id = currentSessionId else { return }

        for shot in 0..<totalShots {
            var attempt = 0
            while true {
                let countdown = attempt == 0 ? settings.countdownSeconds : min(3, settings.countdownSeconds)
                for remaining in stride(from: max(1, countdown), through: 1, by: -1) {
                    phase = .countdown(shot: shot, remaining: remaining)
                    try? await Task.sleep(nanoseconds: tick)
                    if Task.isCancelled { return }
                }
                phase = .capturing(shot: shot)
                flashCounter += 1
                do {
                    let jpeg = try await camera.capture()
                    try await store.addPhoto(sessionId: id, index: shot, jpeg: jpeg)
                    if let t = await Self.thumbnail(jpeg) { thumbnails.append(t) }
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
            // Brief pause so guests can see the shot and reset their pose.
            if shot < totalShots - 1 { try? await Task.sleep(nanoseconds: tick) }
        }

        if settings.allowRetake {
            enter(.review, timeout: settings.reviewTimeoutSeconds) { [weak self] in self?.accept() }
        } else {
            phase = .review
            accept()
        }
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
