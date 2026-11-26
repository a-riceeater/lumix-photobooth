import Foundation
import ImageCaptureCore

/// Finds Panasonic cameras (USB VID 0x04DA) connected over USB with
/// ImageCaptureCore. The S5II must be in USB mode "PC(Tether)".
///
/// HARDWARE NOTE: the research verified the protocol on Windows (WPD). The
/// ImageCaptureCore path follows docs/ipados-compatibility.md but has not
/// been exercised against a physical camera on iOS/iPadOS yet.
final class USBCameraBrowser: NSObject, ICDeviceBrowserDelegate, @unchecked Sendable {
    static let panasonicVendorID = 0x04DA

    private let browser = ICDeviceBrowser()
    private let lock = NSLock()
    private var cameras: [ICCameraDevice] = []
    var onChange: (@Sendable () -> Void)?

    override init() {
        super.init()
        browser.delegate = self
        let mask = ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue
        if let m = ICDeviceTypeMask(rawValue: mask) { browser.browsedDeviceTypeMask = m }
    }

    var isBrowsing: Bool { browser.isBrowsing }

    /// Asks for permission to control camera devices (iOS 14+ system prompt).
    func requestAuthorization() async -> Bool {
        if browser.controlAuthorizationStatus == .authorized { return true }
        return await withCheckedContinuation { cont in
            browser.requestControlAuthorization { status in cont.resume(returning: status == .authorized) }
        }
    }

    var authorizationDescription: String {
        switch browser.controlAuthorizationStatus {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "not determined"
        default: return browser.controlAuthorizationStatus.rawValue
        }
    }

    func start() { if !browser.isBrowsing { browser.start() } }
    func stop() { if browser.isBrowsing { browser.stop() } }

    /// First connected Panasonic camera, if any.
    var panasonicCamera: ICCameraDevice? {
        lock.lock(); defer { lock.unlock() }
        return cameras.first { $0.usbVendorID == Self.panasonicVendorID }
    }

    /// All camera devices ImageCaptureCore currently sees (diagnostics).
    var allCameraDescriptions: [String] {
        lock.lock(); defer { lock.unlock() }
        return cameras.map { String(format: "%@ (USB %04X:%04X)", $0.name ?? "camera", $0.usbVendorID, $0.usbProductID) }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let cam = device as? ICCameraDevice else { return }
        lock.lock(); cameras.append(cam); lock.unlock()
        onChange?()
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        lock.lock(); cameras.removeAll { $0 === device }; lock.unlock()
        onChange?()
    }
}

/// PTPTransport over `ICCameraDevice.requestSendPTPCommand` (USB).
final class ImageCaptureTransport: NSObject, PTPTransport, ICCameraDeviceDelegate, @unchecked Sendable {
    let camera: ICCameraDevice
    let events: AsyncStream<PTPEvent>
    private let eventContinuation: AsyncStream<PTPEvent>.Continuation
    private let gate = AsyncLock()
    private let stateLock = NSLock()
    private var transactionID: UInt32 = 0
    private var closed = false
    private var readyContinuation: CheckedContinuation<Void, Never>?

    var name: String { camera.name ?? "Panasonic camera" }

    init(camera: ICCameraDevice) {
        self.camera = camera
        var cont: AsyncStream<PTPEvent>.Continuation!
        events = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { cont = $0 }
        eventContinuation = cont
        super.init()
        camera.delegate = self
        // Events arrive as raw PTP event containers (code, params).
        camera.ptpEventHandler = { [weak self] data in
            guard let self, let ev = PTPContainer.parseEvent(data) else { return }
            self.eventContinuation.yield(ev)
        }
    }

    /// Opens the ImageCaptureCore session and waits (briefly) for the device to be ready.
    func open() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            camera.requestOpenSession(options: nil) { error in
                if let error { cont.resume(throwing: CameraTransportError.sessionFailed(error.localizedDescription)) }
                else { cont.resume() }
            }
        }
        // In PC(Tether) mode the card catalog is not browsable, so ICC may never
        // report a complete catalog; continue after a short grace period.
        _ = try? await withTimeout(3, onTimeout: { CameraTransportError.timeout(opcode: 0) }) { [weak self] in
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                guard let self else { return c.resume() }
                self.stateLock.lock()
                self.readyContinuation = c
                self.stateLock.unlock()
            }
        }
        // If the grace period expired, release the still-pending wait.
        stateLock.lock()
        let pending = readyContinuation
        readyContinuation = nil
        stateLock.unlock()
        pending?.resume()
    }

    private func nextTransactionID() -> UInt32 {
        stateLock.lock(); defer { stateLock.unlock() }
        transactionID &+= 1
        return transactionID
    }

    func execute(_ opcode: UInt16, params: [UInt32], outData: Data?, timeout: TimeInterval) async throws -> PTPResponse {
        try await gate.withLock {
            stateLock.lock()
            let isClosed = closed
            stateLock.unlock()
            if isClosed { throw CameraTransportError.disconnected }
            // ImageCaptureCore owns the session; the transaction ID we put in
            // the container is expected to be managed by ICC (unverified on device).
            let command = PTPContainer.command(opcode: opcode, transactionID: nextTransactionID(), params: params)
            let cam = camera
            return try await withTimeout(timeout, onTimeout: { CameraTransportError.timeout(opcode: opcode) }) {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PTPResponse, Error>) in
                    cam.requestSendPTPCommand(command, outData: outData) { inData, responseData, error in
                        if let error {
                            cont.resume(throwing: CameraTransportError.commandFailed(error.localizedDescription))
                            return
                        }
                        do {
                            let (code, rparams) = try PTPContainer.parseResponse(responseData)
                            cont.resume(returning: PTPResponse(opcode: opcode, code: code, params: rparams, data: inData))
                        } catch {
                            cont.resume(throwing: CameraTransportError.commandFailed("malformed response \(responseData.hexPrefix)"))
                        }
                    }
                }
            }
        }
    }

    func close() async {
        stateLock.lock()
        let wasClosed = closed
        closed = true
        stateLock.unlock()
        eventContinuation.finish()
        guard !wasClosed else { return }
        camera.ptpEventHandler = { _ in }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            camera.requestCloseSession(options: nil) { _ in c.resume() }
        }
    }

    private func markDisconnected() {
        stateLock.lock(); closed = true; stateLock.unlock()
        eventContinuation.finish()
    }

    // MARK: ICDeviceDelegate

    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) { markDisconnected() }
    func didRemove(_ device: ICDevice) { markDisconnected() }
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {}
    func deviceDidBecomeReady(_ device: ICDevice) {}
    func device(_ device: ICDevice, didEncounterError error: Error?) {}

    // MARK: ICCameraDeviceDelegate (catalog callbacks are unused in tether mode)

    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) {
        // Only called when ptpEventHandler is nil; handled there.
        if let ev = PTPContainer.parseEvent(eventData) { eventContinuation.yield(ev) }
    }
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        stateLock.lock()
        let c = readyContinuation
        readyContinuation = nil
        stateLock.unlock()
        c?.resume()
    }
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}
}
