import Foundation

struct ServerSettings: Equatable, Sendable, Codable {
    var url = ""
    var username = ""
    var password = ""

    var isComplete: Bool { !url.isEmpty && !username.isEmpty && !password.isEmpty }
}

/// Persists the connection settings.
protocol SettingsStore: Sendable {
    func load() -> ServerSettings
    func save(_ settings: ServerSettings) throws
    func clear() throws
}
