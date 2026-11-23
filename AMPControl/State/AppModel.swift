import Foundation
import Observation

/// Holds the saved settings and the API client built from them.
@MainActor
@Observable
final class AppModel {
    private(set) var settings: ServerSettings

    /// `nil` until complete settings are saved. Replaced by a new client
    /// whenever the settings change.
    private(set) var client: AMPClient?

    let toasts = ToastCenter()

    @ObservationIgnored private let store: any SettingsStore
    @ObservationIgnored private let makeTransport: @MainActor () -> any HTTPTransport

    init(
        store: any SettingsStore,
        makeTransport: @escaping @MainActor () -> any HTTPTransport = { URLSessionTransport() }
    ) {
        self.store = store
        self.makeTransport = makeTransport
        settings = store.load()
        rebuildClient()
    }

    var isConfigured: Bool { settings.isComplete }

    /// A client for these settings, e.g. to test them before saving.
    func makeClient(for settings: ServerSettings) -> AMPClient {
        AMPClient(
            baseURL: settings.url,
            username: settings.username,
            password: settings.password,
            transport: makeTransport()
        )
    }

    func saveSettings(_ settings: ServerSettings) async throws {
        let normalized = ServerSettings(
            url: AMPClient.normalizeURL(settings.url),
            username: settings.username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: settings.password
        )
        try store.save(normalized)
        await client?.logout()
        self.settings = normalized
        rebuildClient()
    }

    func clearSettings() async throws {
        try store.clear()
        await client?.logout()
        settings = ServerSettings()
        rebuildClient()
    }

    private func rebuildClient() {
        client?.close()
        client = settings.isComplete ? makeClient(for: settings) : nil
    }
}
