import SwiftUI

/// Screens that can be pushed on top of the instance list.
enum Route: Hashable {
    case settings
    case instance(AMPInstance)
}

/// Shows the first-run setup until a server is configured, then the instances.
struct RootView: View {
    let app: AppModel
    @State private var path: [Route] = []

    var body: some View {
        Group {
            if let client = app.client {
                NavigationStack(path: $path) {
                    InstancesView(app: app, client: client, path: $path)
                        // New settings mean a new client: start the list over.
                        .id(ObjectIdentifier(client))
                        .navigationDestination(for: Route.self) { route in
                            switch route {
                            case .settings:
                                SettingsView(app: app, firstRun: false) { path.removeAll() }
                            case .instance(let instance):
                                InstanceDetailView(
                                    instance: instance, client: client, toasts: app.toasts)
                            }
                        }
                }
            } else {
                NavigationStack {
                    SettingsView(app: app, firstRun: true) {}
                }
            }
        }
        .onChange(of: app.isConfigured) { path.removeAll() }
        .toastOverlay(app.toasts)
    }
}
