import Foundation
import Observation
import UIKit

/// Holds the active camera service so it can be swapped at runtime
/// (operator switches between the mock and the real camera).
@MainActor @Observable
final class CameraHub {
    private(set) var current: CameraService

    init(_ service: CameraService) { current = service }

    func replace(with service: CameraService, start: Bool) async {
        await current.stop()
        current = service
        if start { service.start() }
    }
}

enum ServerCheck: Equatable {
    case unknown
    case checking
    case ok(ServerConfig)
    case failed(String)
}

/// Composition root: owns settings, storage, uploads, camera and the booth flow.
@MainActor @Observable
final class AppModel {
    let settings: AppSettings
    let store: SessionStore
    let uploads: UploadQueue
    let cameraHub: CameraHub
    let booth: BoothController
    private(set) var serverCheck: ServerCheck = .unknown
    private(set) var designs: [DesignInfo] = []

    init(settings: AppSettings? = nil, store: SessionStore? = nil) {
        let settings = settings ?? AppSettings()
        self.settings = settings
        let store = store ?? SessionStore()
        self.store = store
        let uploads = UploadQueue(store: store, settings: settings)
        self.uploads = uploads
        let hub = CameraHub(Self.makeCamera(settings.cameraKind, settings: settings))
        cameraHub = hub
        booth = BoothController(settings: settings, store: store, uploads: uploads, camera: { hub.current })
    }

    var camera: CameraService { cameraHub.current }

    static func makeCamera(_ kind: CameraKind, settings: AppSettings) -> CameraService {
        switch kind {
        case .mock: return MockCameraService(preferences: { [weak settings] in settings?.cameraPreferences ?? CameraPreferences() })
        case .lumixUSB: return LumixUSBCameraService(preferences: { [weak settings] in settings?.cameraPreferences ?? CameraPreferences() })
        case .lumixWiFi: return LumixWiFiCameraService(preferences: { [weak settings] in settings?.cameraPreferences ?? CameraPreferences() })
        }
    }

    /// Camera released because the app went to the background (not by the operator).
    private var suspendedForBackground = false
    private var suspendTask: Task<Void, Never>?

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        if !settings.cameraReleased { camera.start() }
        uploads.start()
        Task { await checkServer() }
    }

    func switchCamera(to kind: CameraKind) async {
        guard kind != camera.kind else { return }
        await cameraHub.replace(with: Self.makeCamera(kind, settings: settings), start: !settings.cameraReleased)
    }

    // MARK: Camera connection control

    /// Operator: hand the camera back (its buttons are locked while the booth holds it).
    /// Sticky until `connectCamera()`, so the booth doesn't immediately re-pair.
    func releaseCamera() async {
        settings.cameraReleased = true
        await camera.stop()
    }

    func connectCamera() {
        settings.cameraReleased = false
        camera.start()
    }

    /// App is going to the background (or being closed): release the camera
    /// cleanly — stop the Wi-Fi stream / restore USB settings — instead of
    /// letting the session die when iOS suspends the app. Waits for an
    /// in-flight transfer, which the camera service serializes before stopping.
    func suspendCameraForBackground() async {
        guard !suspendedForBackground, !settings.cameraReleased else { return }
        suspendedForBackground = true
        let camera = self.camera
        let task = Task { await camera.stop() }
        suspendTask = task
        await task.value
    }

    /// Back in the foreground: reconnect unless the operator released the camera.
    func resumeCameraAfterBackground() {
        guard suspendedForBackground else { return }
        suspendedForBackground = false
        let pending = suspendTask
        suspendTask = nil
        Task {
            await pending?.value   // finish releasing before connecting again
            if !settings.cameraReleased, !suspendedForBackground { camera.start() }
        }
    }

    /// Fetches /api/config: confirms reachability and the API key, and learns
    /// the public gallery URL used for QR codes.
    func checkServer() async {
        serverCheck = .checking
        let client = APIClient(baseURL: settings.serverURL, apiKey: settings.apiKey)
        do {
            let cfg = try await client.config()
            settings.publicBaseURL = cfg.publicBaseUrl
            serverCheck = .ok(cfg)
            designs = (try? await client.designs()) ?? []
            uploads.retryNow()
        } catch {
            serverCheck = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }
}
