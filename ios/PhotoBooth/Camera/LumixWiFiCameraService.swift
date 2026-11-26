import CoreGraphics
import Foundation
import Observation

/// LUMIX S5II over Wi-Fi (camera's "Remote Shooting & View → Via Network").
///
/// Verified recipe (docs/lan-research-log.md, session 2):
///   pair → recmode (only from a confirmed idle playback state) → bind UDP →
///   startstream (live view; also keeps record mode) → per shot `camcmd capture`
///   and watch the card-write flag → after the session: stopstream → playmode →
///   get_content_info → Browse the newest items one at a time → GET each DO*.JPG
///   → recmode → startstream.
/// Safety: any err_busy or unexpected timeout halts all traffic until the
/// operator taps Reconnect; pairing refusals are never retried.
@MainActor @Observable
final class LumixWiFiCameraService: CameraService {
    let kind = CameraKind.lumixWiFi
    private(set) var state: CameraState = .stopped
    let preview = PreviewFeed()
    private(set) var info: CameraInfo?
    let log = DiagnosticsLog()
    private(set) var host: String?
    private(set) var reconnectCount = 0
    /// The camera does its own AF when `capture` arrives.
    var focusLeadTime: TimeInterval { 0 }

    @ObservationIgnored var preferences: () -> CameraPreferences
    @ObservationIgnored private var client: LumixWiFiClient?
    @ObservationIgnored private let receiver = WiFiLiveViewReceiver(port: 49199)
    @ObservationIgnored private var streaming = false
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var running = false
    @ObservationIgnored private var blocked = false     // refused or halted: wait for operator
    @ObservationIgnored private var superviseTask: Task<Void, Never>?
    @ObservationIgnored private var keepaliveTask: Task<Void, Never>?
    @ObservationIgnored private var lastHost: String?

    init(preferences: @escaping () -> CameraPreferences = { CameraPreferences() }) {
        self.preferences = preferences
        let feed = preview
        receiver.onFrame = { image in Task { @MainActor in feed.publish(image) } }
    }

    // MARK: Lifecycle

    func start() {
        guard !running else { return }
        running = true
        state = .searching
        superviseTask = Task { [weak self] in await self?.supervise() }
    }

    func stop() async {
        running = false
        superviseTask?.cancel()
        keepaliveTask?.cancel()
        if let c = client, streaming, await c.haltReason == nil {
            _ = try? await c.command("mode=stopstream", timeout: 4)
        }
        streaming = false
        receiver.stop()
        client = nil
        preview.clear()
        state = .stopped
        log.add("Wi-Fi camera released (the camera's session lapses on its own)")
    }

    /// Operator action: after checking the camera, clear a halt/refusal and start over.
    func reconnect() {
        log.add("operator requested reconnect")
        keepaliveTask?.cancel()
        client = nil
        streaming = false
        blocked = false
        reconnectCount += 1
        state = .searching
        if !running { start() }
    }

    private func supervise() async {
        var lastSearchLog = Date.distantPast
        while running && !Task.isCancelled {
            if client == nil && !blocked {
                if Date().timeIntervalSince(lastSearchLog) > 30 {
                    log.add("searching for the camera on this Wi-Fi network…")
                    lastSearchLog = Date()
                }
                await connect()
            }
            try? await Task.sleep(nanoseconds: (client == nil && !blocked ? 2 : 1) * 1_000_000_000)
        }
    }

    // MARK: Connect

    private func connect() async {
        let prefs = preferences()
        let preferred = prefs.wifiHost.isEmpty ? lastHost : prefs.wifiHost
        guard let found = await LumixWiFiDiscovery.find(preferredHost: preferred) else {
            if state != .searching { state = .searching }
            return
        }
        lastHost = found.host
        host = found.host
        state = .connecting
        log.add("found \(found.description.modelNumber) \"\(found.description.friendlyName)\" fw \(found.description.firmware) at \(found.host)")
        let c = LumixWiFiClient(host: found.host)
        await c.setLogger { [weak self] msg in Task { @MainActor in self?.log.add(msg) } }
        do {
            let sid = try await pair(c, udn: found.description.udn, name: prefs.wifiClientName)
            await c.setSession(sid)
            client = c
            try await enterRecordModeAndStream(c)
            info = CameraInfo(model: found.description.modelNumber, serial: found.description.friendlyName,
                              vendorExtensionID: 0, warnings: ["Wi-Fi: photos are fetched from the camera after each session's last shot."])
            state = .ready
            log.add("ready: session \(sid.prefix(6))…, live view on udp/\(receiver.port)")
            startKeepalive(c)
        } catch LumixWiFiError.refused {
            blocked = true
            client = nil
            state = .failed("Camera refused the connection — arm Remote Shooting on the camera, then tap Reconnect")
            log.add("pairing REFUSED — not retrying (repeated refusals lock the camera)")
        } catch {
            await fail(c, error, during: "connect")
        }
    }

    /// req_acc_g once, then poll the SAME req_acc_e (never re-arm while the camera prompts).
    private func pair(_ c: LumixWiFiClient, udn: String, name: String) async throws -> String {
        await c.expectUnresponsive(for: 300)
        _ = try? await c.cgi("mode=accctrl&type=req_acc_g", timeout: 6, withSession: false)
        let query = CamCGI.pairingQuery(udn: udn, clientName: name)
        var deadline = Date().addingTimeInterval(30)
        var rearms = 0
        var prompted = false
        while Date() < deadline {
            let body = try await c.cgi(query, timeout: 8, withSession: false)
            switch WiFiPairState(csv: body) {
            case .granted(let sid):
                _ = try? await c.cgi("mode=setsetting&type=device_name&value=\(name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "booth")", timeout: 6)
                await c.expectUnresponsive(for: 0)
                return sid
            case .promptingOperator:
                if !prompted {
                    prompted = true
                    deadline = Date().addingTimeInterval(240)
                    state = .connecting
                    log.add("camera is asking to allow \"\(name)\" — accept it on the camera screen")
                }
                try await Task.sleep(nanoseconds: 500_000_000)
            case .decidingSilently:
                try await Task.sleep(nanoseconds: 300_000_000)
            case .refused:
                throw LumixWiFiError.refused
            case .othersRequesting, .critical, .unknown:
                rearms += 1
                guard rearms <= 3 else { throw LumixWiFiError.notArmed("pairing stuck") }
                try await Task.sleep(nanoseconds: 1_000_000_000)
                _ = try? await c.cgi("mode=accctrl&type=req_acc_g", timeout: 6, withSession: false)
            }
        }
        throw LumixWiFiError.notArmed("pairing was not accepted in time")
    }

    /// recmode only from a positively confirmed idle playback state; then the stream.
    private func enterRecordModeAndStream(_ c: LumixWiFiClient) async throws {
        let st = try await c.state()
        if st.isRecordingVideo { throw LumixWiFiError.camera("the camera is recording video — stop it on the camera") }
        if !st.isRecordMode {
            guard st.isPlayMode else { throw LumixWiFiError.camera("unexpected camera mode \(st.camMode)") }
            try await switchToRecordMode(c)
        }
        try await startStream(c)
    }

    private func switchToRecordMode(_ c: LumixWiFiClient) async throws {
        await c.expectUnresponsive(for: 25)   // the HTTP server goes quiet during the switch
        _ = try? await c.cgi("mode=camcmd&value=recmode", timeout: 12)   // reply code is unreliable; trust getstate
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            if let s = try? await c.state(), s.isRecordMode {
                await c.expectUnresponsive(for: 0)
                return
            }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        await c.expectUnresponsive(for: 0)
        throw LumixWiFiError.camera("the camera did not enter shooting mode")
    }

    /// Never sends startstream while a stream may already be running.
    private func startStream(_ c: LumixWiFiClient) async throws {
        guard !streaming else { return }
        try receiver.start()
        try await c.command("mode=startstream&value=\(receiver.port)")
        streaming = true
    }

    private func stopStream(_ c: LumixWiFiClient) async throws {
        guard streaming else { return }
        try await c.command("mode=stopstream")
        streaming = false
    }

    // MARK: Keepalive

    private func startKeepalive(_ c: LumixWiFiClient) {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            var misses = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self, self.client === c, !Task.isCancelled else { return }
                if await c.haltReason != nil { await self.fail(c, LumixWiFiError.halted(await c.haltReason ?? ""), during: "keepalive"); return }
                do {
                    let s = try await c.state()
                    misses = 0
                    if let b = Self.batteryPercent(s.battery) { self.info?.batteryPercent = b }
                    guard !self.busy else { continue }
                    if s.isPlayMode && !s.isRecordingVideo {
                        self.log.add("camera left shooting mode — restoring")
                        if self.streaming { try await self.stopStream(c) }
                        try await self.switchToRecordMode(c)
                        try await self.startStream(c)
                    } else if self.streaming, let gap = self.receiver.secondsSinceLastDatagram, gap > 6 {
                        self.log.add(String(format: "live view stalled (%.0f s) — restarting the stream", gap))
                        try await self.stopStream(c)
                        try await self.startStream(c)
                    }
                } catch {
                    misses += 1
                    if await c.haltReason != nil || misses >= 3 {
                        await self.fail(c, error, during: "keepalive")
                        return
                    }
                }
            }
        }
    }

    nonisolated static func batteryPercent(_ s: String) -> Int? {
        let p = s.split(separator: "/").compactMap { Int($0) }
        guard p.count == 2, p[1] > 0 else { return nil }
        return p[0] * 100 / p[1]
    }

    private func fail(_ c: LumixWiFiClient, _ error: Error, during: String) async {
        let msg = (error as? LocalizedError)?.errorDescription ?? "\(error)"
        keepaliveTask?.cancel()
        if let reason = await c.haltReason {
            blocked = true
            state = .failed("Camera needs a check (\(reason)). Look at the camera, then tap Reconnect.")
            log.add("halted during \(during): \(reason)")
        } else {
            state = .reconnecting(msg)
            log.add("\(during) failed: \(msg) — will reconnect")
        }
        if client === c { client = nil }
        streaming = false
        preview.clear()
    }

    // MARK: Capture

    func prepareCapture() async throws {}

    func capture() async throws -> CaptureResult {
        guard let c = client, state.isReady else { throw CaptureError.notConnected }
        guard !busy else { throw CaptureError.busy }
        busy = true
        defer { busy = false }
        let started = Date()
        do {
            try await c.command("mode=camcmd&value=capture")
            var sawWrite = false
            while Date().timeIntervalSince(started) < 10 {
                let s = try await c.state()
                if s.isWritingCard { sawWrite = true } else if sawWrite {
                    log.add(String(format: "capture: written to card after %.2f s", Date().timeIntervalSince(started)))
                    return .storedOnCamera
                }
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            log.add(sawWrite ? "capture: card still busy after 10 s" : "capture: no card write within 10 s (focus?)")
            throw CaptureError.noImage
        } catch let e as CaptureError {
            throw e
        } catch {
            await fail(c, error, during: "capture")
            throw CaptureError.notConnected
        }
    }

    func collectPhotos(count: Int, progress: @escaping @MainActor (Int) -> Void) async throws -> [Data] {
        guard count > 0 else { return [] }
        guard let c = client else { throw CaptureError.notConnected }
        busy = true
        defer { busy = false }
        let started = Date()
        var photos: [Data] = []
        var failure: Error?
        do {
            try await stopStream(c)
            try await c.command("mode=camcmd&value=playmode", timeout: 12)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let info = try await c.cgi("mode=get_content_info")
            guard CamCGI.result(info) == "ok", let total = CamCGI.tag("total_content_number", in: info).flatMap({ Int($0) }), total >= count else {
                throw LumixWiFiError.camera("content info unavailable")
            }
            var items: [CameraContentItem] = []
            for index in (total - count)..<total {
                guard let item = try await c.browse(start: index, count: 1).first else {
                    throw LumixWiFiError.camera("photo \(index + 1) has no JPEG — set the camera's quality to FINE or RAW+FINE")
                }
                items.append(item)
            }
            log.add("fetching " + items.map(\.originalFileName).joined(separator: ", "))
            for item in items {
                let data = try await c.download(item.jpegURL, expectedBytes: item.size)
                guard data.count > 3, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8 else { throw CaptureError.invalidImage }
                photos.append(data)
                progress(photos.count)
            }
            log.add(String(format: "fetched %d photo(s), %.1f MB in %.1f s", photos.count,
                           Double(photos.reduce(0) { $0 + $1.count }) / 1_048_576, Date().timeIntervalSince(started)))
        } catch {
            failure = error
            log.add("fetch failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }
        // Always return the camera to shooting mode for the next guest (unless halted).
        if await c.haltReason == nil {
            do {
                try await switchToRecordMode(c)
                try await startStream(c)
            } catch {
                await fail(c, error, during: "return to shooting mode")
            }
        } else {
            await fail(c, LumixWiFiError.halted(await c.haltReason ?? ""), during: "fetch")
        }
        if let failure { throw failure }
        return photos
    }
}
