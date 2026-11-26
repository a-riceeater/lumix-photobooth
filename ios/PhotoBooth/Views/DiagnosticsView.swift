import SwiftUI

/// Operator-only camera diagnostics: connection state, camera facts,
/// warnings, a test capture and the technical log.
struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var testResult: String?
    @State private var testing = false

    var body: some View {
        let cam = model.camera
        List {
            Section("Connection") {
                LabeledContent("Implementation", value: cam.kind.label)
                LabeledContent("State", value: cam.state.label)
                LabeledContent("Preview", value: String(format: "%.1f fps", cam.preview.fps))
                if let usb = cam as? LumixUSBCameraService {
                    LabeledContent("Camera access", value: usb.authorization)
                    LabeledContent("Reconnects", value: "\(usb.reconnectCount)")
                    LabeledContent("Devices seen", value: usb.visibleCameras.isEmpty ? "none" : usb.visibleCameras.joined(separator: ", "))
                }
                Button("Reconnect camera") { cam.reconnect() }
            }
            if let info = cam.info {
                Section("Camera") {
                    LabeledContent("Model", value: info.model)
                    LabeledContent("Serial", value: info.serial)
                    LabeledContent("Battery", value: info.batteryPercent.map { "\($0)%" } ?? "?")
                    LabeledContent("Remaining shots", value: info.remainingShots.map(String.init) ?? "?")
                    LabeledContent("Focus mode", value: info.focusMode?.label ?? "?")
                    LabeledContent("Drive dial single", value: info.driveModeSingle.map { $0 ? "yes" : "NO" } ?? "?")
                    LabeledContent("Capture target", value: info.captureTarget?.label ?? "?")
                    LabeledContent("Image quality", value: info.imageQuality.map { $0 == 0 ? "JPEG FINE" : "code \($0)" } ?? "?")
                    LabeledContent("Liveview", value: info.liveview?.label ?? "?")
                }
                if !info.warnings.isEmpty {
                    Section("Warnings") {
                        ForEach(info.warnings, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                    }
                }
            }
            Section("Test capture") {
                Button(testing ? "Capturing…" : "Take a test photo (not saved)") {
                    testing = true
                    Task {
                        let start = Date()
                        do {
                            let data = try await cam.capture()
                            testResult = String(format: "OK: %.1f MB in %.2f s", Double(data.count) / 1_048_576, Date().timeIntervalSince(start))
                        } catch {
                            testResult = "Failed: \((error as? LocalizedError)?.errorDescription ?? "\(error)")"
                        }
                        testing = false
                    }
                }
                .disabled(testing || !cam.state.isReady || model.booth.phase != .welcome)
                if let testResult { Text(testResult).font(.callout.monospaced()) }
            }
            Section("Log") {
                ForEach(cam.log.entries.reversed()) { e in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(e.date, format: .dateTime.hour().minute().second()).font(.caption2).foregroundStyle(.secondary)
                        Text(e.message).font(.caption.monospaced())
                    }
                }
                Button("Clear log", role: .destructive) { cam.log.clear() }
            }
        }
        .navigationTitle("Camera diagnostics")
    }
}

/// Every local session and its upload state.
struct UploadQueueView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                LabeledContent("Network", value: model.uploads.isOnline ? "Online" : "Offline")
                if let t = model.uploads.lastSuccessAt {
                    LabeledContent("Last successful upload") { Text(t, style: .relative) }
                }
                Button("Retry everything now") { model.uploads.retryNow(includeFailed: true) }
            }
            Section("Sessions (newest first)") {
                ForEach(model.store.sessions.reversed()) { s in
                    SessionRow(session: s, active: model.uploads.activeSessionId == s.id)
                        .swipeActions {
                            if s.state == .synced {
                                Button("Forget", role: .destructive) { model.store.delete(s) }
                                if !s.localFilesDeleted {
                                    Button("Delete photos") { model.store.removeLocalPhotos(s) }.tint(.orange)
                                }
                            } else {
                                Button("Retry") { model.uploads.retryNow(includeFailed: true) }.tint(.blue)
                            }
                        }
                }
            }
        }
        .navigationTitle("Upload queue")
    }
}

private struct SessionRow: View {
    let session: LocalSession
    let active: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.createdAt, format: .dateTime.month().day().hour().minute())
                Spacer()
                badge
            }
            Text("\(session.eventId) · \(session.uploadedCount)/\(session.photoCount) photos uploaded · \(session.id.prefix(8))…")
                .font(.caption).foregroundStyle(.secondary)
            if !session.emails.isEmpty {
                Text(session.emails.map { "\($0.masked) \($0.delivered ? "✓" : ($0.note ?? "pending"))" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let e = session.lastError, session.state != .synced {
                Text("\(e) (attempt \(session.attempts))").font(.caption).foregroundStyle(.red)
            }
            if session.localFilesDeleted { Text("Local photos deleted after sync").font(.caption2).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var badge: some View {
        switch session.state {
        case .synced: Label("Online", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Label("Needs attention", systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
        case .ready: Label(active ? "Uploading" : "Waiting", systemImage: active ? "arrow.up.circle" : "clock").foregroundStyle(.orange)
        case .capturing: Label("Capturing", systemImage: "camera").foregroundStyle(.secondary)
        }
    }
}
