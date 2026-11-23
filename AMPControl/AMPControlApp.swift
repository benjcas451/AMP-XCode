import SwiftUI

@main
struct AMPControlApp: App {
    @State private var app: AppModel

    init() {
        let store = KeychainSettingsStore()
        #if DEBUG
        // Lets UI tests start from a clean first-run state.
        if ProcessInfo.processInfo.arguments.contains("-resetSettings") { try? store.clear() }
        #endif
        _app = State(initialValue: AppModel(store: store))
    }

    var body: some Scene {
        WindowGroup {
            RootView(app: app)
        }
    }
}
