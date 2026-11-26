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
            if phase == .active {
                // Guided Access / kiosk: keep the screen on and nudge uploads.
                UIApplication.shared.isIdleTimerDisabled = true
                model.uploads.trigger()
            }
        }
    }
}
