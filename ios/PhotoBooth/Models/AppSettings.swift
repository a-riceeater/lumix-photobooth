import Foundation
import Observation
import UIKit

enum RetentionPolicy: String, CaseIterable, Codable, Identifiable {
    case keepForever
    case deleteAfterDays
    case deleteWhenSynced

    var id: String { rawValue }
    var label: String {
        switch self {
        case .keepForever: return "Keep all photos on this device"
        case .deleteAfterDays: return "Delete synced photos after some days"
        case .deleteWhenSynced: return "Delete as soon as the server has them"
        }
    }
}

/// Operator settings. Non-secret values live in UserDefaults; the API key
/// and operator PIN live in the Keychain.
@MainActor @Observable
final class AppSettings {
    static let defaultPIN = "0000"

    @ObservationIgnored private let defaults: UserDefaults

    var serverURL: String { didSet { save("serverURL", serverURL) } }
    /// Public gallery base URL reported by the server (/api/config); used for QR codes.
    var publicBaseURL: String { didSet { save("publicBaseURL", publicBaseURL) } }
    var eventName: String { didSet { save("eventName", eventName) } }
    var eventId: String { didSet { save("eventId", eventId) } }
    var photosPerSession: Int { didSet { save("photosPerSession", photosPerSession) } }
    /// Countdown before the first photo of a session.
    var countdownSeconds: Int { didSet { save("countdownSeconds", countdownSeconds) } }
    /// Countdown before each following photo.
    var betweenPhotosCountdownSeconds: Int { didSet { save("betweenPhotosCountdownSeconds", betweenPhotosCountdownSeconds) } }
    /// Seconds each photo is shown fullscreen right after it is taken (0 = only the thumbnail strip).
    var postCapturePreviewSeconds: Int { didSet { save("postCapturePreviewSeconds", postCapturePreviewSeconds) } }
    var mirrorPreview: Bool { didSet { save("mirrorPreview", mirrorPreview) } }
    var showFramingGuides: Bool { didSet { save("showFramingGuides", showFramingGuides) } }
    var fillScreenPreview: Bool { didSet { save("fillScreenPreview", fillScreenPreview) } }
    var allowRetake: Bool { didSet { save("allowRetake", allowRetake) } }
    /// Retakes allowed per session (0 = unlimited).
    var maxRetakes: Int { didSet { save("maxRetakes", maxRetakes) } }
    var countdownSounds: Bool { didSet { save("countdownSounds", countdownSounds) } }
    var flashEffect: Bool { didSet { save("flashEffect", flashEffect) } }
    /// Welcome screen subtitle; empty = "We'll take N photos — get ready to pose!".
    var welcomeMessage: String { didSet { save("welcomeMessage", welcomeMessage) } }
    var offerEmail: Bool { didSet { save("offerEmail", offerEmail) } }
    var defaultDesignId: String { didSet { save("defaultDesignId", defaultDesignId) } }
    var resetTimeoutSeconds: Int { didSet { save("resetTimeoutSeconds", resetTimeoutSeconds) } }
    var reviewTimeoutSeconds: Int { didSet { save("reviewTimeoutSeconds", reviewTimeoutSeconds) } }
    var retention: RetentionPolicy { didSet { save("retention", retention.rawValue) } }
    var retentionDays: Int { didSet { save("retentionDays", retentionDays) } }
    var cameraKind: CameraKind { didSet { save("cameraKind", cameraKind.rawValue) } }
    var captureTarget: CaptureTarget { didSet { save("captureTarget", Int(captureTarget.rawValue)) } }
    var forceJPEGFine: Bool { didSet { save("forceJPEGFine", forceJPEGFine) } }
    var autofocusBeforeCapture: Bool { didSet { save("autofocusBeforeCapture", autofocusBeforeCapture) } }
    var liveviewWidth: Int { didSet { save("liveviewWidth", liveviewWidth) } }
    var mockFailureRate: Double { didSet { save("mockFailureRate", mockFailureRate) } }

    var apiKey: String { didSet { Keychain.set("apiKey", apiKey) } }
    var operatorPIN: String { didSet { Keychain.set("operatorPIN", operatorPIN) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func str(_ k: String, _ d: String) -> String { defaults.string(forKey: k) ?? d }
        func int(_ k: String, _ d: Int) -> Int { defaults.object(forKey: k) == nil ? d : defaults.integer(forKey: k) }
        func bool(_ k: String, _ d: Bool) -> Bool { defaults.object(forKey: k) == nil ? d : defaults.bool(forKey: k) }
        serverURL = str("serverURL", "http://localhost:8080")
        publicBaseURL = str("publicBaseURL", "")
        eventName = str("eventName", "Photo Booth")
        eventId = str("eventId", "my-event")
        photosPerSession = int("photosPerSession", 3)
        countdownSeconds = int("countdownSeconds", 5)
        betweenPhotosCountdownSeconds = int("betweenPhotosCountdownSeconds", int("countdownSeconds", 5))
        postCapturePreviewSeconds = int("postCapturePreviewSeconds", 1)
        mirrorPreview = bool("mirrorPreview", true)
        showFramingGuides = bool("showFramingGuides", true)
        fillScreenPreview = bool("fillScreenPreview", false)
        allowRetake = bool("allowRetake", true)
        maxRetakes = int("maxRetakes", 1)
        countdownSounds = bool("countdownSounds", true)
        flashEffect = bool("flashEffect", true)
        welcomeMessage = str("welcomeMessage", "")
        offerEmail = bool("offerEmail", true)
        defaultDesignId = str("defaultDesignId", "")
        resetTimeoutSeconds = int("resetTimeoutSeconds", 60)
        reviewTimeoutSeconds = int("reviewTimeoutSeconds", 30)
        retention = RetentionPolicy(rawValue: str("retention", "")) ?? .keepForever
        retentionDays = int("retentionDays", 7)
        #if targetEnvironment(simulator)
        let defaultCamera = CameraKind.mock
        #else
        let defaultCamera = CameraKind.lumixUSB
        #endif
        cameraKind = CameraKind(rawValue: str("cameraKind", "")) ?? defaultCamera
        captureTarget = CaptureTarget(rawValue: UInt16(int("captureTarget", 1))) ?? .pc
        forceJPEGFine = bool("forceJPEGFine", true)
        autofocusBeforeCapture = bool("autofocusBeforeCapture", true)
        liveviewWidth = int("liveviewWidth", 960)
        mockFailureRate = defaults.object(forKey: "mockFailureRate") == nil ? 0 : defaults.double(forKey: "mockFailureRate")
        apiKey = Keychain.get("apiKey") ?? ""
        operatorPIN = Keychain.get("operatorPIN") ?? AppSettings.defaultPIN
    }

    private func save(_ key: String, _ value: Any) {
        defaults.set(value, forKey: key)
    }

    var deviceName: String { UIDevice.current.name }

    /// Base URL for gallery links: the server's public URL if known, else the upload URL.
    var galleryBaseURL: String {
        let base = publicBaseURL.isEmpty ? serverURL : publicBaseURL
        return base.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    var cameraPreferences: CameraPreferences {
        CameraPreferences(
            options: CameraOptions(captureTarget: captureTarget, forceJPEGFine: forceJPEGFine,
                                   autofocusBeforeCapture: autofocusBeforeCapture, liveviewWidth: UInt16(clamping: liveviewWidth)),
            mockFailureRate: mockFailureRate)
    }

    /// Cleans an operator-typed server address: trims spaces and trailing
    /// slashes, adds http:// to bare hosts like "192.168.1.20:8080".
    static func normalizeServerURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        if s.hasSuffix("/api") { s.removeLast(4) }
        if !s.isEmpty, !s.lowercased().hasPrefix("http://"), !s.lowercased().hasPrefix("https://") { s = "http://" + s }
        return s
    }

    /// nil if valid, else a short operator-facing problem description.
    static func serverURLProblem(_ s: String) -> String? {
        guard !s.isEmpty else { return "Enter the server address, e.g. https://photos.example.com or http://192.168.1.20:8080" }
        guard let u = URL(string: s), let scheme = u.scheme, ["http", "https"].contains(scheme), let host = u.host, !host.isEmpty else {
            return "Not a valid address"
        }
        if scheme == "http", !Self.isLocalHost(host) {
            return "iOS only allows plain http:// to local network addresses; use https:// for internet servers"
        }
        return nil
    }

    static func isLocalHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".local") || !host.contains(".") { return true }
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || parts[0] == 127 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1])) || (parts[0] == 169 && parts[1] == 254)
    }

    /// Event IDs must match the server's slug rule.
    static func isValidEventId(_ s: String) -> Bool {
        s.range(of: "^[a-z0-9](?:[a-z0-9-]{0,62}[a-z0-9])?$", options: .regularExpression) != nil
    }

    static func slug(_ s: String) -> String {
        let lowered = s.lowercased().folding(options: .diacriticInsensitive, locale: .current)
        let dashed = lowered.replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
        return String(dashed.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(64))
    }
}
