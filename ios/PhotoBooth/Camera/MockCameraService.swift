import CoreGraphics
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// Draws the mock camera's synthetic scene (thread-safe, pure CoreGraphics).
enum MockScene {
    static func render(width: Int, height: Int, time t: Double, label: String) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        let w = CGFloat(width), h = CGFloat(height)
        let hue = CGFloat((t / 20).truncatingRemainder(dividingBy: 1))
        let top = color(hue: hue, s: 0.55, b: 0.95)
        let bottom = color(hue: (hue + 0.35).truncatingRemainder(dividingBy: 1), s: 0.75, b: 0.45)
        if let g = CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1]) {
            ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
        }
        // Moving circles give a sense of motion in the preview.
        for i in 0..<6 {
            let phase = t * 0.6 + Double(i) * 1.1
            let r = h * (0.08 + 0.03 * CGFloat(i % 3))
            let cx = w * (0.5 + 0.38 * CGFloat(sin(phase)))
            let cy = h * (0.5 + 0.32 * CGFloat(cos(phase * 1.3)))
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.18 + 0.05 * CGFloat(i % 3)))
            ctx.fillEllipse(in: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
        }
        // A "subject" silhouette in the centre third.
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.35))
        let headR = h * 0.11
        ctx.fillEllipse(in: CGRect(x: w / 2 - headR, y: h * 0.42, width: 2 * headR, height: 2 * headR))
        ctx.fill(CGRect(x: w / 2 - headR * 2, y: 0, width: headR * 4, height: h * 0.40))
        // Frame border and label.
        ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.6))
        ctx.setLineWidth(max(2, h * 0.006))
        ctx.stroke(CGRect(x: w * 0.03, y: h * 0.04, width: w * 0.94, height: h * 0.92))
        drawLabel(ctx, label, at: CGPoint(x: w * 0.05, y: h * 0.07), size: h * 0.07)
        return ctx.makeImage()
    }

    /// Blocky label drawn with rectangles so no font/UIKit is needed off-main.
    private static func drawLabel(_ ctx: CGContext, _ text: String, at p: CGPoint, size: CGFloat) {
        let glyphs: [Character: [String]] = [
            "M": ["10001", "11011", "10101", "10001", "10001"], "O": ["01110", "10001", "10001", "10001", "01110"],
            "C": ["01111", "10000", "10000", "10000", "01111"], "K": ["10010", "10100", "11000", "10100", "10010"],
            "0": ["01110", "10011", "10101", "11001", "01110"], "1": ["00100", "01100", "00100", "00100", "01110"],
            "2": ["11110", "00001", "01110", "10000", "11111"], "3": ["11110", "00001", "00110", "00001", "11110"],
            "4": ["10010", "10010", "11111", "00010", "00010"], "5": ["11111", "10000", "11110", "00001", "11110"],
            "6": ["01110", "10000", "11110", "10001", "01110"], "7": ["11111", "00010", "00100", "01000", "01000"],
            "8": ["01110", "10001", "01110", "10001", "01110"], "9": ["01110", "10001", "01111", "00001", "01110"],
            "#": ["01010", "11111", "01010", "11111", "01010"], " ": ["00000", "00000", "00000", "00000", "00000"],
        ]
        let px = size / 5
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.85))
        var x = p.x
        for ch in text.uppercased() {
            let rows = glyphs[ch] ?? glyphs[" "]!
            for (ri, row) in rows.enumerated() {
                for (ci, bit) in row.enumerated() where bit == "1" {
                    ctx.fill(CGRect(x: x + CGFloat(ci) * px, y: p.y + CGFloat(4 - ri) * px, width: px, height: px))
                }
            }
            x += px * 6
        }
    }

    private static func color(hue: CGFloat, s: CGFloat, b: CGFloat) -> CGColor {
        // HSB -> RGB
        let i = Int(hue * 6) % 6
        let f = hue * 6 - CGFloat(Int(hue * 6))
        let p = b * (1 - s), q = b * (1 - f * s), t = b * (1 - (1 - f) * s)
        let (r, g, bl): (CGFloat, CGFloat, CGFloat) = [(b, t, p), (q, b, p), (p, b, t), (p, q, b), (t, p, b), (b, p, q)][i]
        return CGColor(srgbRed: r, green: g, blue: bl, alpha: 1)
    }

    static func jpeg(_ image: CGImage, quality: Double = 0.9) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}

/// Complete stand-in for the real camera: liveview at ~24 fps and
/// full-size 3:2 JPEG captures, with optional simulated failures.
@MainActor @Observable
final class MockCameraService: CameraService {
    let kind = CameraKind.mock
    private(set) var state: CameraState = .stopped
    let preview = PreviewFeed()
    private(set) var info: CameraInfo?
    let log = DiagnosticsLog()
    @ObservationIgnored var preferences: () -> CameraPreferences
    @ObservationIgnored private var frameTask: Task<Void, Never>?
    @ObservationIgnored private var shotCounter = 0
    @ObservationIgnored private var capturing = false
    /// Mimics AF-C autofocus (0.23–0.34 s measured on the S5II).
    var focusLeadTime: TimeInterval { 0.6 }

    init(preferences: @escaping () -> CameraPreferences = { CameraPreferences() }) {
        self.preferences = preferences
    }

    func start() {
        guard frameTask == nil else { return }
        state = .connecting
        log.add("mock camera starting")
        let feed = preview
        frameTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.state = .ready
            self?.info = CameraInfo(model: "Mock Camera", serial: "MOCK-0001", vendorExtensionID: 0x1C, batteryPercent: 100,
                                    remainingShots: 9999, focusMode: .afc, driveModeSingle: true, captureTarget: .pc,
                                    imageQuality: 0, liveview: LiveviewSetting(height: 640, width: 960, frameKB: 250, fps: 24))
            self?.log.add("mock camera ready")
            let start = Date()
            while !Task.isCancelled {
                let t = Date().timeIntervalSince(start)
                let img = await Task.detached(priority: .userInitiated) {
                    MockScene.render(width: 960, height: 640, time: t, label: "MOCK")
                }.value
                if let img { feed.publish(img) }
                try? await Task.sleep(nanoseconds: 41_000_000)
            }
        }
    }

    func stop() async {
        frameTask?.cancel()
        frameTask = nil
        state = .stopped
        preview.clear()
        log.add("mock camera stopped")
    }

    func reconnect() {
        Task {
            await stop()
            state = .reconnecting("operator request")
            start()
        }
    }

    func prepareCapture() async throws {
        guard state.isReady else { throw CaptureError.notConnected }
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    @ObservationIgnored private var deferred: [Data] = []

    func collectPhotos(count: Int, progress: @escaping @MainActor (Int) -> Void) async throws -> [Data] {
        var out: [Data] = []
        for (i, d) in deferred.suffix(count).enumerated() {
            try await Task.sleep(nanoseconds: 300_000_000)   // models the Wi-Fi download
            out.append(d)
            progress(i + 1)
        }
        deferred.removeAll()
        log.add("mock: delivered \(out.count) photo(s) after the session")
        return out
    }

    func capture() async throws -> CaptureResult {
        guard state.isReady else { throw CaptureError.notConnected }
        guard !capturing else { throw CaptureError.busy }
        capturing = true
        defer { capturing = false }
        let prefs = preferences()
        shotCounter += 1
        let n = shotCounter
        // The "exposure" happens now; the delay models in-camera processing and
        // USB transfer (release → JPEG ≈ 0.55 s + 0.3 s download on the S5II).
        try await Task.sleep(nanoseconds: 800_000_000)
        if prefs.mockFailureRate > 0, Double.random(in: 0..<1) < prefs.mockFailureRate {
            log.add("mock capture #\(n): simulated failure")
            throw CaptureError.noImage
        }
        let size = prefs.mockCaptureSize
        let data = await Task.detached(priority: .userInitiated) { () -> Data? in
            guard let img = MockScene.render(width: Int(size.width), height: Int(size.height), time: Double(n) * 3.7, label: "MOCK #\(n)") else { return nil }
            return MockScene.jpeg(img)
        }.value
        guard let data else { throw CaptureError.invalidImage }
        log.add("mock capture #\(n): \(data.count) bytes")
        if prefs.mockDeferredDelivery {
            deferred.append(data)
            return .storedOnCamera
        }
        return .jpeg(data)
    }
}
