import Foundation
import Observation
import UIKit

/// Holds the active camera service so it can be swapped at runtime
/// (operator switches between the mock and the real camera).
@MainActor @Observable
final class CameraHub {
    private(set) var current: CameraService

    init(_ service: CameraService) { current = service }

    func replace(with service: CameraService) async {
        await current.stop()
        current = service
        service.start()
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
        }
    }

    func start() {
        UIApplication.shared.isIdleTimerDisabled = true
        camera.start()
        uploads.start()
        Task { await checkServer() }
    }

    func switchCamera(to kind: CameraKind) async {
        guard kind != camera.kind else { return }
        await cameraHub.replace(with: Self.makeCamera(kind, settings: settings))
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
