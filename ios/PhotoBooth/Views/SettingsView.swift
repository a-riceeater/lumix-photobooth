import SwiftUI

/// Operator settings (behind the hidden gesture + PIN).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var newPIN = ""
    @State private var guidedAccess = UIAccessibility.isGuidedAccessEnabled

    var body: some View {
        @Bindable var s = model.settings
        NavigationStack {
            Form {
                statusSection
                Section("Event") {
                    TextField("Event name", text: $s.eventName)
                    HStack {
                        TextField("Event identifier", text: $s.eventId)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("From name") { s.eventId = AppSettings.slug(s.eventName) }
                    }
                    if !AppSettings.isValidEventId(s.eventId) {
                        Text("Use lowercase letters, digits and dashes (e.g. summer-party-2026).").foregroundStyle(.red).font(.footnote)
                    }
                    Stepper("Photos per session: \(s.photosPerSession)", value: $s.photosPerSession, in: 1...6)
                    Stepper("Countdown: \(s.countdownSeconds) s", value: $s.countdownSeconds, in: 1...10)
                    Picker("Default strip design", selection: $s.defaultDesignId) {
                        Text("Server default").tag("")
                        ForEach(model.designs.filter { $0.photoCount == s.photosPerSession }) { d in
                            Text(d.name).tag(d.id)
                        }
                        if !s.defaultDesignId.isEmpty && !model.designs.contains(where: { $0.id == s.defaultDesignId }) {
                            Text(s.defaultDesignId).tag(s.defaultDesignId)
                        }
                    }
                }
                Section("Guest experience") {
                    Toggle("Mirror preview (photos are never mirrored)", isOn: $s.mirrorPreview)
                    Toggle("Framing guides", isOn: $s.showFramingGuides)
                    Toggle("Fill screen with preview (crops edges)", isOn: $s.fillScreenPreview)
                    Toggle("Allow retake", isOn: $s.allowRetake)
                    Toggle("Offer email delivery", isOn: $s.offerEmail)
                    Stepper("Review auto-continue: \(s.reviewTimeoutSeconds) s", value: $s.reviewTimeoutSeconds, in: 5...300, step: 5)
                    Stepper("Return to start after: \(s.resetTimeoutSeconds) s", value: $s.resetTimeoutSeconds, in: 10...600, step: 10)
                }
                Section {
                    TextField("Server URL", text: $s.serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API key (DEVICE_API_KEY)", text: $s.apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Test connection") { Task { await model.checkServer() } }
                    serverCheckRow
                    if !s.publicBaseURL.isEmpty {
                        LabeledContent("Gallery links use", value: s.publicBaseURL)
                    }
                } header: {
                    Text("Server")
                } footer: {
                    Text("The API key is stored in the Keychain. Gallery links use the server's PUBLIC_BASE_URL.")
                }
                cameraSection
                Section("Uploads") {
                    NavigationLink("Upload queue (\(model.uploads.pending.count) pending, \(model.uploads.failed.count) need attention)") {
                        UploadQueueView()
                    }
                    Button("Retry all uploads now") { model.uploads.retryNow(includeFailed: true) }
                }
                Section {
                    Picker("Local copies", selection: $s.retention) {
                        ForEach(RetentionPolicy.allCases) { Text($0.label).tag($0) }
                    }
                    if s.retention == .deleteAfterDays {
                        Stepper("After \(s.retentionDays) days", value: $s.retentionDays, in: 1...90)
                    }
                    LabeledContent("Photos on this device", value: ByteCountFormatter.string(fromByteCount: model.store.localBytes, countStyle: .file))
                } header: {
                    Text("Storage")
                } footer: {
                    Text("Photos are only ever deleted after the server has verified its copy. They are also visible in the Files app under On My iPhone/iPad ▸ Photo Booth.")
                }
                Section {
                    SecureField("New PIN (4–8 digits)", text: $newPIN).keyboardType(.numberPad)
                    Button("Change PIN") {
                        s.operatorPIN = newPIN
                        newPIN = ""
                    }
                    .disabled(newPIN.count < 4 || newPIN.count > 8 || !newPIN.allSatisfy(\.isNumber))
                    if s.operatorPIN == AppSettings.defaultPIN {
                        Label("The operator PIN is still the default (0000).", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    LabeledContent("Guided Access", value: guidedAccess ? "On" : "Off")
                } header: {
                    Text("Security & kiosk")
                } footer: {
                    Text("Open settings: hold the top-left corner of the booth screen for 3 seconds. For a locked kiosk enable Settings ▸ Accessibility ▸ Guided Access, then triple-click the side/home button in the booth.")
                }
            }
            .navigationTitle("Operator settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Back to booth") { dismiss() }.bold()
                }
            }
            .onChange(of: s.cameraKind) { _, kind in Task { await model.switchCamera(to: kind) } }
            .onReceive(NotificationCenter.default.publisher(for: UIAccessibility.guidedAccessStatusDidChangeNotification)) { _ in
                guidedAccess = UIAccessibility.isGuidedAccessEnabled
            }
        }
    }

    private var statusSection: some View {
        Section("Status") {
            LabeledContent("Camera", value: model.camera.state.label)
            LabeledContent("Network", value: model.uploads.isOnline ? "Online" : "Offline")
            LabeledContent("Waiting to upload", value: "\(model.uploads.pending.count)")
            if let err = model.uploads.lastError {
                Text("Last upload error: \(err)").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private var serverCheckRow: some View {
        switch model.serverCheck {
        case .unknown: EmptyView()
        case .checking: HStack { ProgressView(); Text("Checking…") }
        case .ok(let cfg):
            VStack(alignment: .leading, spacing: 4) {
                Label("Server reachable", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                Label(cfg.authenticated ? "API key accepted" : "API key NOT accepted",
                      systemImage: cfg.authenticated ? "key.fill" : "key.slash")
                    .foregroundStyle(cfg.authenticated ? .green : .red)
                Text(cfg.emailEnabled ? "Email delivery enabled" : "Email delivery disabled on the server").font(.footnote)
            }
        case .failed(let m): Label(m, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }

    private var cameraSection: some View {
        @Bindable var s = model.settings
        return Section {
            Picker("Camera", selection: $s.cameraKind) {
                ForEach(CameraKind.allCases) { Text($0.label).tag($0) }
            }
            NavigationLink("Camera diagnostics") { DiagnosticsView() }
            if s.cameraKind == .lumixUSB {
                Picker("Capture target", selection: $s.captureTarget) {
                    ForEach(CaptureTarget.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Switch camera to JPEG FINE", isOn: $s.forceJPEGFine)
                Toggle("Autofocus before each shot", isOn: $s.autofocusBeforeCapture)
                Picker("Liveview size", selection: $s.liveviewWidth) {
                    Text("640 × 432").tag(640)
                    Text("960 × 640").tag(960)
                    Text("1280 × 856").tag(1280)
                }
            } else {
                VStack(alignment: .leading) {
                    Text("Simulated capture failures: \(Int(s.mockFailureRate * 100))%")
                    Slider(value: $s.mockFailureRate, in: 0...0.5, step: 0.05)
                }
            }
        } header: {
            Text("Camera")
        } footer: {
            Text(s.cameraKind == .lumixUSB
                 ? "Set the S5II to USB mode PC(Tether), drive dial to single shot. Changes apply on the next (re)connect."
                 : "The mock camera lets you test the whole workflow without hardware.")
        }
    }
}
