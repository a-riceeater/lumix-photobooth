import SwiftUI

/// Operator settings (behind the hidden gesture + PIN).
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var newPIN = ""
    @State private var guidedAccess = UIAccessibility.isGuidedAccessEnabled
    @State private var serverDraft = ""
    @State private var apiKeyDraft = ""

    var body: some View {
        @Bindable var s = model.settings
        NavigationStack {
            Form {
                statusSection
                serverSection
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
                Section {
                    Stepper("Photos per session: \(s.photosPerSession)", value: $s.photosPerSession, in: 1...8)
                    Stepper("Countdown before first photo: \(s.countdownSeconds) s", value: $s.countdownSeconds, in: 1...15)
                    Stepper("Countdown between photos: \(s.betweenPhotosCountdownSeconds) s", value: $s.betweenPhotosCountdownSeconds, in: 1...15)
                    Stepper(s.postCapturePreviewSeconds == 0 ? "Show each photo after capture: off" : "Show each photo after capture: \(s.postCapturePreviewSeconds) s",
                            value: $s.postCapturePreviewSeconds, in: 0...10)
                } header: {
                    Text("Photos & timing")
                } footer: {
                    Text("A session takes about \(sessionSeconds(s)) s. Designs only appear in the gallery if they are made for this number of photos\(designCountNote(s)).")
                }
                Section {
                    Toggle("Allow retake", isOn: $s.allowRetake)
                    if s.allowRetake {
                        Stepper(s.maxRetakes == 0 ? "Retakes per session: unlimited" : "Retakes per session: \(s.maxRetakes)",
                                value: $s.maxRetakes, in: 0...10)
                    }
                    Stepper("Review auto-continue: \(s.reviewTimeoutSeconds) s", value: $s.reviewTimeoutSeconds, in: 5...300, step: 5)
                    Toggle("Offer email delivery", isOn: $s.offerEmail)
                    Stepper("Return to start after: \(s.resetTimeoutSeconds) s", value: $s.resetTimeoutSeconds, in: 10...600, step: 10)
                } header: {
                    Text("Review & sharing")
                } footer: {
                    Text("After the review time the photos are kept automatically. Retakes are set to 0 = unlimited.")
                }
                Section("Look & sound") {
                    TextField("Welcome message (optional)", text: $s.welcomeMessage, axis: .vertical)
                    Toggle("Mirror preview (photos are never mirrored)", isOn: $s.mirrorPreview)
                    Toggle("Framing guides", isOn: $s.showFramingGuides)
                    Toggle("Fill screen with preview (crops edges)", isOn: $s.fillScreenPreview)
                    Toggle("Countdown beeps and shutter sound", isOn: $s.countdownSounds)
                    Toggle("Flash effect on capture", isOn: $s.flashEffect)
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
                    Text("Photos are only ever deleted after the server has verified its copy. They are also visible in the Files app under On My iPhone/iPad ▸ Lumix Booth.")
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

    private var serverSection: some View {
        let normalized = AppSettings.normalizeServerURL(serverDraft)
        let problem = AppSettings.serverURLProblem(normalized)
        let changed = normalized != model.settings.serverURL || apiKeyDraft != model.settings.apiKey
        return Section {
            TextField("https://photos.example.com", text: $serverDraft)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(saveServer)
            if !serverDraft.isEmpty, normalized != serverDraft.trimmingCharacters(in: .whitespaces) {
                Text("Will be saved as \(normalized)").font(.footnote).foregroundStyle(.secondary)
            }
            if let problem, !serverDraft.isEmpty {
                Text(problem).font(.footnote).foregroundStyle(.orange)
            }
            SecureField("API key (DEVICE_API_KEY from server/.env)", text: $apiKeyDraft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(changed ? "Save & test connection" : "Test connection", action: saveServer)
                .disabled(normalized.isEmpty)
            serverCheckRow
            if !model.settings.publicBaseURL.isEmpty {
                LabeledContent("QR codes link to", value: model.settings.publicBaseURL)
            }
        } header: {
            Text("Server endpoint")
        } footer: {
            Text("Where the booth uploads photos: the server's address on this network (e.g. http://192.168.1.20:8080) or its public https address. QR codes always use the server's PUBLIC_BASE_URL. The API key is stored in the Keychain.")
        }
        .onAppear {
            serverDraft = model.settings.serverURL
            apiKeyDraft = model.settings.apiKey
        }
    }

    private func saveServer() {
        let normalized = AppSettings.normalizeServerURL(serverDraft)
        guard !normalized.isEmpty else { return }
        if normalized != model.settings.serverURL {
            model.settings.serverURL = normalized
            model.settings.publicBaseURL = ""   // re-learned from the new server
        }
        if apiKeyDraft != model.settings.apiKey { model.settings.apiKey = apiKeyDraft }
        serverDraft = normalized
        Task { await model.checkServer() }
    }

    private func sessionSeconds(_ s: AppSettings) -> Int {
        let perShot = 2 + s.postCapturePreviewSeconds   // capture + transfer, then preview
        return s.countdownSeconds + (s.photosPerSession - 1) * s.betweenPhotosCountdownSeconds + s.photosPerSession * perShot
    }

    private func designCountNote(_ s: AppSettings) -> String {
        guard !model.designs.isEmpty else { return "" }
        let n = model.designs.filter { $0.photoCount == s.photosPerSession }.count
        return " (\(n) installed for \(s.photosPerSession) photo\(s.photosPerSession == 1 ? "" : "s"))"
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
