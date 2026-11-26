import Foundation

/// Errors a capture can end with. Guest-facing text lives in the UI layer.
enum CaptureError: Error, LocalizedError, Equatable {
    case notConnected
    case focusFailed
    case releaseRejected(String)
    case noImage
    case invalidImage
    case busy

    var errorDescription: String? {
        switch self {
        case .notConnected: return "Camera not connected"
        case .focusFailed: return "The camera could not focus"
        case .releaseRejected(let m): return "Shutter release rejected: \(m)"
        case .noImage: return "The camera did not deliver an image in time"
        case .invalidImage: return "The camera delivered an unreadable image"
        case .busy: return "A capture is already in progress"
        }
    }
}

/// Buffers camera events and the latest C101 status dump, with async waiting.
actor CameraEventHub {
    private var queue: [PTPEvent] = []
    private var waiters: [(codes: Set<UInt16>, cont: CheckedContinuation<PTPEvent?, Never>, id: UUID)] = []
    private(set) var status: [UInt32: Data] = [:]
    private(set) var statusSequence = 0
    private var statusWaiters: [(cont: CheckedContinuation<Void, Never>, id: UUID)] = []

    func push(_ ev: PTPEvent) {
        if let i = waiters.firstIndex(where: { $0.codes.contains(ev.code) }) {
            waiters.remove(at: i).cont.resume(returning: ev)
            return
        }
        queue.append(ev)
        if queue.count > 200 { queue.removeFirst(queue.count - 200) }
    }

    func drain() { queue.removeAll() }

    /// Next event with one of `codes` (queued or future), or nil after `timeout`.
    func next(_ codes: Set<UInt16>, timeout: TimeInterval) async -> PTPEvent? {
        if let i = queue.firstIndex(where: { codes.contains($0.code) }) { return queue.remove(at: i) }
        let id = UUID()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.expire(id)
        }
        return await withCheckedContinuation { waiters.append((codes, $0, id)) }
    }

    private func expire(_ id: UUID) {
        if let i = waiters.firstIndex(where: { $0.id == id }) { waiters.remove(at: i).cont.resume(returning: nil) }
        if let i = statusWaiters.firstIndex(where: { $0.id == id }) { statusWaiters.remove(at: i).cont.resume() }
    }

    func setStatus(_ s: [UInt32: Data]) {
        status = s
        statusSequence += 1
        let ws = statusWaiters
        statusWaiters.removeAll()
        ws.forEach { $0.cont.resume() }
    }

    /// Waits until a status dump newer than `sequence` arrives (or timeout).
    func waitForStatus(after sequence: Int, timeout: TimeInterval) async {
        if statusSequence > sequence { return }
        let id = UUID()
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            await self?.expire(id)
        }
        await withCheckedContinuation { statusWaiters.append(($0, id)) }
    }

    func cancelAll() {
        waiters.forEach { $0.cont.resume(returning: nil) }
        waiters.removeAll()
        statusWaiters.forEach { $0.cont.resume() }
        statusWaiters.removeAll()
    }
}

/// Facts read from the camera on connect (shown in operator diagnostics).
struct CameraInfo: Equatable {
    var model = ""
    var serial = ""
    var vendorExtensionID: UInt32 = 0
    var batteryPercent: Int?
    var remainingShots: Int?
    var focusMode: FocusMode?
    var driveModeSingle: Bool?
    var captureTarget: CaptureTarget?
    var imageQuality: UInt16?
    var liveview: LiveviewSetting?
    var liveviewOptions: [LiveviewSetting] = []
    var warnings: [String] = []
}

struct CameraOptions: Equatable {
    var captureTarget: CaptureTarget = .pc
    /// Switch image quality to JPEG FINE so every shot yields exactly one object.
    var forceJPEGFine = true
    /// Run one-shot AF before releasing (reports focus failure instead of a silent missing image).
    var autofocusBeforeCapture = true
    /// Preferred liveview width (nearest available entry is used).
    var liveviewWidth: UInt16 = 960
}

/// High-level S5II controller built only on PTPTransport (port of
/// lumix_usb.panasonic.Camera). Follows the "Recommended booth capture
/// algorithm" in lumix-usb-research/docs/capture.md.
final class LumixCamera: @unchecked Sendable {
    let transport: PTPTransport
    let hub = CameraEventHub()
    private var pump: Task<Void, Never>?
    private(set) var info = CameraInfo()
    private var originalTarget: CaptureTarget?
    private var originalQuality: UInt16?
    private(set) var liveviewOn = false
    var log: @Sendable (String) -> Void = { _ in }

    init(transport: PTPTransport) {
        self.transport = transport
        pump = Task { [weak self, transport] in
            for await ev in transport.events {
                guard let self else { return }
                if ev.code == PanasonicEvent.ackRequired, let p = ev.params.first {
                    // Ack from outside the event callback (research rule).
                    Task { await self.acknowledge(p) }
                }
                await self.hub.push(ev)
            }
        }
    }

    deinit { pump?.cancel() }

    private func acknowledge(_ param: UInt32) async {
        guard let r = try? await transport.read(PanasonicOp.ackEvent, param), r.isOK else { return }
        await hub.setStatus(TLV.parse(r.data))
    }

    // MARK: Session

    /// Session setup after the transport is open. Non-essential steps only add warnings.
    func connect(options: CameraOptions) async throws -> CameraInfo {
        var info = CameraInfo()
        let di = try DeviceInfo.parse(try await transport.read(PTPOp.getDeviceInfo).check().data)
        info.model = di.model
        info.serial = di.serialNumber
        info.vendorExtensionID = di.vendorExtensionID
        if di.vendorExtensionID != 0x1C { info.warnings.append("Unexpected PTP vendor extension 0x\(String(di.vendorExtensionID, radix: 16)) (Panasonic is 0x1c)") }

        // 0x9102 is optional (liveview and capture work without it) but sent like LUMIX Tether does.
        if let r = try? await transport.command(PanasonicOp.openSession, PanasonicParam.session), !r.isOK {
            info.warnings.append("Panasonic session open returned \(PTPResponseCode.name(r.code))")
        }

        // Capture target (persists in the camera; restored on disconnect).
        if let current = try? await captureTarget() {
            originalTarget = current
            if current != options.captureTarget { try await setCaptureTarget(options.captureTarget) }
        } else {
            try await setCaptureTarget(options.captureTarget)
        }
        info.captureTarget = try? await captureTarget()
        if info.captureTarget != options.captureTarget { info.warnings.append("Capture target could not be set to \(options.captureTarget.label)") }

        // JPEG-only so each shot produces exactly one object (SDRAM FIFO rule).
        if let q = try? await propertyValue(group: PanasonicParam.imageModeGroup, member: PanasonicParam.imageQuality) {
            info.imageQuality = UInt16(q)
            if options.forceJPEGFine, q != UInt32(ImageQuality.fine.rawValue) {
                originalQuality = UInt16(q)
                _ = try? await setProperty(PanasonicParam.imageQuality, value: UInt32(ImageQuality.fine.rawValue), size: 2)
                info.imageQuality = (try? await propertyValue(group: PanasonicParam.imageModeGroup, member: PanasonicParam.imageQuality)).map { UInt16($0) }
            }
        }

        // Physical dials: warn, never change.
        if let drive = try? await propertyValue(group: PanasonicParam.cameraModeGroup, member: PanasonicParam.driveMode) {
            info.driveModeSingle = drive == 0
            if drive != 0 { info.warnings.append("Drive dial is not on single shot (value \(drive)); captures will be delayed or repeated.") }
        }
        if let af = try? await propertyValue(group: PanasonicParam.afGroup, member: PanasonicParam.afMode) {
            info.focusMode = FocusMode(rawValue: UInt16(af))
        }
        info.batteryPercent = try? await batteryPercent()
        info.remainingShots = try? await remainingShots()

        // Liveview size.
        if let opts = try? await transport.read(PanasonicOp.getStatus, PanasonicParam.liveviewOptions), opts.isOK {
            info.liveviewOptions = LiveviewSetting.parseOptions(opts.data)
            if let best = info.liveviewOptions.min(by: { abs(Int($0.width) - Int(options.liveviewWidth)) < abs(Int($1.width) - Int(options.liveviewWidth)) }) {
                _ = try? await writeRetry(PanasonicOp.setLiveviewSetting, data: best.pack(), param: PanasonicParam.liveviewCurrent)
            }
        }
        if let cur = try? await transport.read(PanasonicOp.getStatus, PanasonicParam.liveviewCurrent), cur.isOK {
            info.liveview = LiveviewSetting.parseCurrent(cur.data)
        }

        // Anything left in the SDRAM queue (e.g. after a reconnect) blocks new events.
        await drainSDRAMQueue()
        self.info = info
        return info
    }

    /// Restores the settings the app changed, stops liveview, closes the vendor session.
    func disconnect() async {
        if liveviewOn { _ = try? await liveviewStop() }
        if let q = originalQuality { _ = try? await setProperty(PanasonicParam.imageQuality, value: UInt32(q), size: 2) }
        if let t = originalTarget { try? await setCaptureTarget(t) }
        _ = try? await transport.command(PanasonicOp.closeSession, PanasonicParam.session)
        await hub.cancelAll()
        await transport.close()
        pump?.cancel()
    }

    // MARK: Properties

    func propertyValue(group: UInt32, member: UInt32) async throws -> UInt32 {
        let r = try await transport.read(PanasonicOp.getProperty, group).check()
        guard let body = TLV.parse(r.data)[member], let v = TLV.value(body) else { throw PTPError(opcode: PanasonicOp.getProperty, code: PTPResponseCode.invalidParameter) }
        return v
    }

    func setProperty(_ code: UInt32, value: UInt32, size: Int) async throws -> PTPResponse {
        try await writeRetry(PanasonicOp.setProperty, data: TLV.encode(code: code, value: value, size: size), param: code)
    }

    /// Setters transiently return InvalidParameter/DeviceBusy (e.g. right after liveview stop): retry after 300 ms.
    private func writeRetry(_ op: UInt16, data: Data, param: UInt32, tries: Int = 4) async throws -> PTPResponse {
        var last: PTPResponse!
        for i in 0..<tries {
            last = try await transport.write(op, data: data, param)
            if ![PTPResponseCode.invalidParameter, PTPResponseCode.deviceBusy].contains(last.code) || i == tries - 1 { break }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        return last
    }

    func captureTarget() async throws -> CaptureTarget? {
        let r = try await transport.read(PanasonicOp.getCaptureTarget, PanasonicParam.captureTargetQuery).check()
        guard let body = TLV.parse(r.data)[PanasonicParam.captureTargetProp], let v = TLV.value(body) else { return nil }
        return CaptureTarget(rawValue: UInt16(v))
    }

    func setCaptureTarget(_ t: CaptureTarget) async throws {
        try await writeRetry(PanasonicOp.setCaptureTarget, data: TLV.encode(code: PanasonicParam.captureTargetProp, value: UInt32(t.rawValue), size: 2), param: 0).check()
    }

    func batteryPercent() async throws -> Int {
        let r = try await transport.read(PanasonicOp.getStatus, PanasonicParam.batteryGroup).check()
        guard let b = TLV.parse(r.data)[PanasonicParam.batteryPercent], let v = b.le(UInt32.self, at: 0) else { throw CaptureError.invalidImage }
        return Int(v)
    }

    func remainingShots() async throws -> Int {
        let r = try await transport.read(PanasonicOp.getStatus, PanasonicParam.recordingGroup).check()
        guard let b = TLV.parse(r.data)[PanasonicParam.remainingShots], let v = TLV.value(b) else { throw CaptureError.invalidImage }
        return Int(v)
    }

    // MARK: Liveview

    func liveviewStart() async throws {
        try await transport.command(PanasonicOp.liveview, PanasonicParam.liveviewStart).check()
        liveviewOn = true
        try await Task.sleep(nanoseconds: 200_000_000)   // first fetch before ~200 ms returns DeviceBusy
    }

    func liveviewStop() async throws -> PTPResponse {
        liveviewOn = false
        return try await transport.command(PanasonicOp.liveview, PanasonicParam.liveviewStop)
    }

    /// One liveview JPEG, or nil while the camera is busy (sensor blackout during capture).
    func liveviewFrame() async throws -> Data? {
        let r = try await transport.read(PanasonicOp.liveviewImage, timeout: 5)
        if r.isOK, !r.data.isEmpty { return LiveviewFrameParser.jpeg(from: r.data) }
        if r.code == PTPResponseCode.deviceBusy || r.isOK { return nil }
        throw PTPError(opcode: PanasonicOp.liveviewImage, code: r.code)
    }

    // MARK: Capture

    /// One-shot AF; returns the AF result from the next C101 status dump.
    func autofocus(timeout: TimeInterval = 3) async throws -> AFState? {
        let seq = await hub.statusSequence
        let start = Date()
        try await transport.command(PanasonicOp.afControl, PanasonicParam.afOneShot).check()
        var lastSeq = seq
        while Date().timeIntervalSince(start) < timeout {
            await hub.waitForStatus(after: lastSeq, timeout: timeout - Date().timeIntervalSince(start))
            lastSeq = await hub.statusSequence
            guard lastSeq > seq else { continue }
            let status = await hub.status
            if let v = status[PanasonicParam.statusAF]?.le(UInt16.self, at: 0), let s = AFState(rawValue: v),
               s == .inFocus || s == .failed {
                return s
            }
        }
        return nil
    }

    /// Takes one photo and returns the full-resolution JPEG bytes.
    func capture(objectTimeout: TimeInterval = 15) async throws -> Data {
        await hub.drain()
        var r = try await transport.command(PanasonicOp.release, PanasonicParam.releaseShutter)
        if r.code == PTPResponseCode.generalError {
            // Refused briefly (e.g. right after AF): wait 1 s, retry once.
            try await Task.sleep(nanoseconds: 1_000_000_000)
            r = try await transport.command(PanasonicOp.release, PanasonicParam.releaseShutter)
        }
        guard r.isOK else { throw CaptureError.releaseRejected(PTPResponseCode.name(r.code)) }

        let deadline = Date().addingTimeInterval(objectTimeout)
        while Date() < deadline {
            guard let ev = await hub.next([PanasonicEvent.objectAddedPC, PanasonicEvent.objectAddedSD], timeout: deadline.timeIntervalSinceNow),
                  let handle = ev.params.first else { break }
            try await Task.sleep(nanoseconds: 50_000_000)   // object not readable immediately (libgphoto2)
            guard let oi = try? await objectInfo(handle) else { continue }
            if oi.format == PTPObjectFormat.association { continue }  // new folder on the card
            let data = try await download(handle, size: oi.compressedSize)
            if oi.isJPEG {
                guard data.count > 3, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8 else { throw CaptureError.invalidImage }
                if handle == PanasonicParam.sdramHandle { await drainSDRAMQueue() }
                log("captured \(oi.filename) \(data.count) bytes")
                return data
            }
            // RAW (or other) first: discarded; keep waiting for the JPEG.
            log("skipped object \(oi.filename) format 0x\(String(oi.format, radix: 16))")
        }
        throw CaptureError.noImage
    }

    /// AF (when enabled and the lens is not in MF), then capture.
    func captureWithAutofocus(_ useAF: Bool) async throws -> Data {
        if useAF, info.focusMode != .manual {
            let state = try await autofocus()
            if state == .failed {
                _ = try? await transport.command(PanasonicOp.afControl, PanasonicParam.afLockClear)
                throw CaptureError.focusFailed
            }
        }
        return try await capture()
    }

    func objectInfo(_ handle: UInt32) async throws -> ObjectInfo {
        let r = try await transport.read(PTPOp.getObjectInfo, handle)
        guard r.isOK else { throw PTPError(opcode: PTPOp.getObjectInfo, code: r.code) }
        return try ObjectInfo.parse(r.data)
    }

    /// GetObject in one transaction; ~10 MB JPEGs took 0.3 s on USB 2.0.
    func download(_ handle: UInt32, size: UInt64) async throws -> Data {
        let timeout = max(20, Double(size) / 2_000_000)
        return try await transport.read(PTPOp.getObject, handle, timeout: timeout).check().data
    }

    /// In PC target every queued object must be downloaded before new shots are announced.
    func drainSDRAMQueue() async {
        for _ in 0..<8 {
            guard let oi = try? await objectInfo(PanasonicParam.sdramHandle) else { return }
            log("draining queued object \(oi.filename)")
            guard (try? await download(PanasonicParam.sdramHandle, size: oi.compressedSize)) != nil else { return }
        }
    }
}
