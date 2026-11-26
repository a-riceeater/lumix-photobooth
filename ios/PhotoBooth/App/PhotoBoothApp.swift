import SwiftUI

@main
struct PhotoBoothApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        let model = AppModel()
        _model = State(initialValue: model)
        if !isTesting { model.start() }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Guided Access / kiosk: keep the screen on and nudge uploads.
                UIApplication.shared.isIdleTimerDisabled = true
                model.uploads.trigger()
                model.resumeCameraAfterBackground()
            case .background:
                // Also the path taken when the app is swiped away: iOS always
                // backgrounds before terminating. Ask for time to release the
                // camera properly (not on .inactive: Control Center etc.).
                let app = UIApplication.shared
                var token = UIBackgroundTaskIdentifier.invalid
                token = app.beginBackgroundTask(withName: "Release camera") {
                    app.endBackgroundTask(token)
                    token = .invalid
                }
                Task { @MainActor in
                    await model.suspendCameraForBackground()
                    if token != .invalid { app.endBackgroundTask(token) }
                }
            default:
                break
            }
        }
    }
}
