import CoreGraphics
import Foundation
import ImageCaptureCore
import Observation

/// LUMIX S5II over USB (ImageCaptureCore). Supervises the connection:
/// discovers the camera, sets it up, polls liveview, captures, and reconnects
/// after cable pulls / power cycles (strategy from
/// lumix-usb-research/docs/troubleshooting.md: drop, re-enumerate, reopen,
/// re-send 0x9102, re-apply target and liveview size, restart liveview).
///
/// HARDWARE NOTE: not yet run against a physical camera on iOS. See
/// docs/hardware-testing.md for the validation checklist.
@MainActor @Observable
final class LumixUSBCameraService: CameraService {
    let kind = CameraKind.lumixUSB
    private(set) var state: CameraState = .stopped
    let preview = PreviewFeed()
    private(set) var info: CameraInfo?
    let log = DiagnosticsLog()
    private(set) var reconnectCount = 0
    private(set) var authorization = "unknown"
    private(set) var visibleCameras: [String] = []

    @ObservationIgnored var preferences: () -> CameraPreferences
    @ObservationIgnored private var browser: USBCameraBrowser?
    @ObservationIgnored private var camera: LumixCamera?
    @ObservationIgnored private var superviseTask: Task<Void, Never>?
    @ObservationIgnored private var liveviewTask: Task<Void, Never>?
    @ObservationIgnored private var statusTask: Task<Void, Never>?
    @ObservationIgnored private var running = false
    @ObservationIgnored private var capturing = false
    @ObservationIgnored private var forceReconnect = false
    /// Set by prepareCapture(): the next capture() releases without its own AF.
    @ObservationIgnored private var prepared = false

    private var autofocusEnabled: Bool {
        preferences().options.autofocusBeforeCapture && info?.focusMode != .manual
    }

    /// AF budgets from lumix-usb-research/docs/capture.md: in focus after
    /// 0.23–0.34 s (AF-C) / 0.45–0.63 s (AF-S), plus margin.
    var focusLeadTime: TimeInterval {
        guard autofocusEnabled else { return 0 }
        return info?.focusMode == .afc ? 0.6 : 0.9
    }

    init(preferences: @escaping () -> CameraPreferences = { CameraPreferences() }) {
        self.preferences = preferences
    }

    func start() {
        guard !running else { return }
        running = true
        state = .searching
        let browser = USBCameraBrowser()
        browser.onChange = { [weak self] in Task { @MainActor in self?.refreshDeviceList() } }
        self.browser = browser
        superviseTask = Task { [weak self] in await self?.supervise(browser) }
    }

    func stop() async {
        running = false
        superviseTask?.cancel()
        await dropConnection(reason: nil, restoreSettings: true)
        browser?.stop()
        browser = nil
        state = .stopped
        log.add("camera service stopped")
    }

    func reconnect() {
        forceReconnect = true
        log.add("operator requested reconnect")
    }

    private func refreshDeviceList() {
        visibleCameras = browser?.allCameraDescriptions ?? []
    }

    // MARK: Supervision

    private func supervise(_ browser: USBCameraBrowser) async {
        log.add("requesting camera control authorization")
        let ok = await browser.requestAuthorization()
        authorization = browser.authorizationDescription
        guard ok else {
            state = .failed("Camera access denied. Allow it in Settings, then restart the app.")
            log.add("control authorization: \(authorization)")
            return
        }
        browser.start()
        log.add("browsing for USB cameras (Panasonic VID 0x04DA, USB mode PC(Tether))")
        var lastLoggedSearch = Date.distantPast
        while running && !Task.isCancelled {
            if forceReconnect {
                forceReconnect = false
                await dropConnection(reason: "operator request", restoreSettings: false)
            }
            if camera == nil {
                if let device = browser.panasonicCamera {
                    await connect(device)
                } else {
                    // Keep showing "reconnecting" after a drop until the camera returns.
                    if case .reconnecting = state {} else if state != .searching { state = .searching }
                    if Date().timeIntervalSince(lastLoggedSearch) > 30 {
                        log.add("no Panasonic camera visible; ImageCaptureCore sees: \(browser.allCameraDescriptions.joined(separator: ", ").isEmpty ? "nothing" : browser.allCameraDescriptions.joined(separator: ", "))")
                        lastLoggedSearch = Date()
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func connect(_ device: ICCameraDevice) async {
        state = .connecting
        let started = Date()
        log.add("opening \(device.name ?? "camera") (USB \(String(format: "%04X:%04X", device.usbVendorID, device.usbProductID)))")
        let transport = ImageCaptureTransport(camera: device)
        let cam = LumixCamera(transport: transport)
        cam.log = { [weak self] msg in Task { @MainActor in self?.log.add(msg) } }
        do {
            try await transport.open()
            let info = try await cam.connect(options: preferences().options)
            try await cam.liveviewStart()
            self.camera = cam
            self.info = info
            state = .ready
            log.add(String(format: "connected to %@ in %.2f s; liveview %@; target %@; focus %@", info.model,
                           Date().timeIntervalSince(started), info.liveview?.label ?? "?", info.captureTarget?.label ?? "?",
                           info.focusMode?.label ?? "?"))
            info.warnings.forEach { log.add("warning: \($0)") }
            startLiveview(cam)
            startStatusPolling(cam)
        } catch {
            log.add("connect failed: \(describe(error))")
            await transport.close()
            state = .reconnecting(describe(error))
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    private func dropConnection(reason: String?, restoreSettings: Bool) async {
        liveviewTask?.cancel()
        statusTask?.cancel()
        liveviewTask = nil
        statusTask = nil
        guard let cam = camera else { return }
        camera = nil
        preview.clear()
        if restoreSettings {
            await cam.disconnect()
        } else {
            await cam.transport.close()
        }
        if let reason {
            reconnectCount += 1
            state = .reconnecting(reason)
            log.add("connection dropped: \(reason)")
        }
    }

    /// Transport failures mean the link is gone; PTP errors mean the camera answered.
    private func handle(_ error: Error, from cam: LumixCamera) async {
        guard cam === camera else { return }
        if error is PTPError {
            log.add("camera error: \(describe(error))")
            return
        }
        await dropConnection(reason: describe(error), restoreSettings: false)
    }

    // MARK: Liveview

    private func startLiveview(_ cam: LumixCamera) {
        let feed = preview
        liveviewTask = Task.detached(priority: .userInitiated) { [weak self] in
            var consecutiveErrors = 0
            while !Task.isCancelled {
                do {
                    if let jpeg = try await cam.liveviewFrame() {
                        consecutiveErrors = 0
                        if let img = PreviewFeed.decode(jpeg) { await feed.publish(img) }
                    } else {
                        try await Task.sleep(nanoseconds: 20_000_000)   // DeviceBusy: sensor blackout during capture
                    }
                } catch is CancellationError {
                    return
                } catch let error as PTPError {
                    // Camera answered with an error: liveview probably stopped (e.g. menu, playback). Restart it.
                    consecutiveErrors += 1
                    await self?.log.add("liveview: \(error); restarting liveview")
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    try? await cam.liveviewStart()
                    if consecutiveErrors > 20 { await self?.handle(error, from: cam); return }
                } catch {
                    await self?.handle(error, from: cam)
                    return
                }
            }
        }
    }

    private func startStatusPolling(_ cam: LumixCamera) {
        statusTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self, cam === self.camera else { return }
                if let b = try? await cam.batteryPercent() { self.info?.batteryPercent = b }
                if let r = try? await cam.remainingShots() { self.info?.remainingShots = r }
            }
        }
    }

    // MARK: Capture

    func prepareCapture() async throws {
        prepared = false
        guard autofocusEnabled else { return }
        guard let cam = camera, state.isReady else { throw CaptureError.notConnected }
        let started = Date()
        do {
            let state = try await cam.autofocus()
            log.add(String(format: "pre-focus: %@ in %.2f s", state.map { "\($0)" } ?? "no result", Date().timeIntervalSince(started)))
            if state == .failed {
                _ = try? await cam.transport.command(PanasonicOp.afControl, PanasonicParam.afLockClear)
                throw CaptureError.focusFailed
            }
            prepared = true
        } catch let error as CaptureError {
            throw error
        } catch let error as PTPError {
            log.add("pre-focus failed: \(error)")   // capture() will try AF again
        } catch {
            await handle(error, from: cam)
            throw CaptureError.notConnected
        }
    }

    func capture() async throws -> Data {
        guard let cam = camera, state.isReady else { throw CaptureError.notConnected }
        let useAF = preferences().options.autofocusBeforeCapture && !prepared
        prepared = false
        guard !capturing else { throw CaptureError.busy }
        capturing = true
        defer { capturing = false }
        let started = Date()
        do {
            let data = try await cam.captureWithAutofocus(useAF)
            log.add(String(format: "capture: %d bytes in %.2f s", data.count, Date().timeIntervalSince(started)))
            return data
        } catch let error as CaptureError {
            log.add("capture failed: \(describe(error))")
            throw error
        } catch let error as PTPError {
            log.add("capture failed: \(error)")
            throw CaptureError.releaseRejected(error.description)
        } catch {
            log.add("capture failed (link): \(describe(error))")
            await handle(error, from: cam)
            throw CaptureError.notConnected
        }
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
