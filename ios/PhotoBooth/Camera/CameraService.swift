import CoreGraphics
import Foundation
import ImageIO
import Observation

/// Which camera implementation the booth uses (operator setting).
enum CameraKind: String, CaseIterable, Codable, Identifiable {
    case mock
    case lumixUSB
    case lumixWiFi

    var id: String { rawValue }
    var label: String {
        switch self {
        case .mock: return "Mock camera (no hardware)"
        case .lumixUSB: return "LUMIX S5II over USB"
        case .lumixWiFi: return "LUMIX S5II over Wi-Fi"
        }
    }
}

enum CameraState: Equatable {
    case stopped
    case searching
    case connecting
    case ready
    case reconnecting(String)
    case failed(String)
    /// Working on something else (e.g. finishing a photo transfer); back shortly.
    case busy(String)

    var isReady: Bool { self == .ready }

    /// Short operator-facing description.
    var label: String {
        switch self {
        case .stopped: return "Stopped"
        case .searching: return "Looking for camera…"
        case .connecting: return "Connecting…"
        case .ready: return "Connected"
        case .reconnecting(let why): return "Reconnecting (\(why))"
        case .failed(let why): return why
        case .busy(let what): return what
        }
    }
}

/// Latest liveview frame. Kept separate from the service so that only the
/// preview view re-renders at frame rate.
@MainActor @Observable
final class PreviewFeed {
    private(set) var image: CGImage?
    private(set) var fps: Double = 0
    private(set) var lastFrameAt: Date?
    @ObservationIgnored private var frameTimes: [Date] = []

    func publish(_ image: CGImage) {
        let now = Date()
        self.image = image
        lastFrameAt = now
        frameTimes.append(now)
        frameTimes.removeAll { now.timeIntervalSince($0) > 2 }
        fps = Double(frameTimes.count) / 2
    }

    func clear() {
        image = nil
        fps = 0
    }

    /// Decodes a JPEG off the main thread.
    nonisolated static func decode(_ jpeg: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
}

/// Rolling technical log for the operator diagnostics screen.
@MainActor @Observable
final class DiagnosticsLog {
    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let message: String
    }

    private(set) var entries: [Entry] = []

    func add(_ message: String) {
        entries.append(Entry(date: Date(), message: message))
        if entries.count > 300 { entries.removeFirst(entries.count - 300) }
        #if DEBUG
        print("[camera] \(message)")
        #endif
    }

    func clear() { entries.removeAll() }
}

/// Result of one shot. Over USB the JPEG arrives immediately; over Wi-Fi the
/// photo is written to the camera's card and fetched after the session's last
/// shot with `collectPhotos(count:progress:)`.
enum CaptureResult: Equatable {
    case jpeg(Data)
    case storedOnCamera
}

/// What the booth needs from a camera, independent of transport (USB,
/// Wi-Fi, or the mock).
@MainActor
protocol CameraService: AnyObject {
    var kind: CameraKind { get }
    var state: CameraState { get }
    var preview: PreviewFeed { get }
    var info: CameraInfo? { get }
    var log: DiagnosticsLog { get }
    /// Starts discovery/connection and keeps reconnecting until stopped.
    func start()
    func stop() async
    /// Seconds to start `prepareCapture()` ahead of the shutter (autofocus
    /// budget for the current focus mode; 0 if nothing needs preparing).
    var focusLeadTime: TimeInterval { get }
    /// Optional first half of a timed capture (autofocus), so the shutter can
    /// fire exactly on cue. A following `capture()` then skips its own AF.
    func prepareCapture() async throws
    /// Fires the shutter immediately; returns the full-resolution JPEG, or
    /// `.storedOnCamera` for cameras that deliver photos after the session.
    func capture() async throws -> CaptureResult
    /// Full-resolution JPEGs of the newest `count` photos, oldest first
    /// (only for cameras whose capture returns `.storedOnCamera`).
    func collectPhotos(count: Int, progress: @escaping @MainActor (Int) -> Void) async throws -> [Data]
    /// Quick path: small camera-made previews of the newest `count` photos.
    /// The camera then stays ready to deliver the originals with `collectOriginals`.
    /// Returns [] if previews are unavailable (originals still pending).
    func collectPreviews(count: Int, progress: @escaping @MainActor (Int) -> Void) async throws -> [Data]
    /// Originals for the photos of the last `collectPreviews` call, then the
    /// camera returns to shooting mode.
    func collectOriginals(progress: @escaping @MainActor (Int) -> Void) async throws -> [Data]
    /// Drops and re-establishes the connection (operator action).
    func reconnect()
}

extension CameraService {
    func collectPhotos(count: Int, progress: @escaping @MainActor (Int) -> Void) async throws -> [Data] { [] }
    func collectPreviews(count: Int, progress: @escaping @MainActor (Int) -> Void) async throws -> [Data] { [] }
    func collectOriginals(progress: @escaping @MainActor (Int) -> Void) async throws -> [Data] { [] }
}

/// Camera options derived from operator settings.
struct CameraPreferences: Equatable {
    var options = CameraOptions()
    var mockFailureRate: Double = 0
    /// Mock behaves like the Wi-Fi camera: photos are delivered after the session.
    var mockDeferredDelivery = false
    /// Wi-Fi: fixed camera address (empty = find it on the network).
    var wifiHost = ""
    /// Wi-Fi: name shown on the camera's connect prompt.
    var wifiClientName = "Photo Booth"
    var mockCaptureSize = CGSize(width: 3000, height: 2000)
}
