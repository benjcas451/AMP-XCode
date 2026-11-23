import Foundation
import Observation

/// State and actions of the connection settings form.
@MainActor
@Observable
final class SettingsViewModel {
    enum Field: Hashable, Sendable {
        case url, username, password
    }

    var url: String
    var username: String
    var password: String
    private(set) var busy = false
    private(set) var errors: [Field: String] = [:]

    let dialogs = DialogCoordinator()

    @ObservationIgnored private let app: AppModel

    init(app: AppModel) {
        self.app = app
        url = app.settings.url
        username = app.settings.username
        password = app.settings.password
    }

    /// The entered values the way they are saved, so that the connection
    /// test checks exactly what will be used later.
    private var current: ServerSettings {
        ServerSettings(
            url: AMPClient.normalizeURL(url),
            username: username.trimmingCharacters(in: .whitespacesAndNewlines),
            password: password
        )
    }

    func validate() -> Bool {
        var errors: [Field: String] = [:]
        let normalized = AMPClient.normalizeURL(url)
        if normalized.isEmpty {
            errors[.url] = "Bitte Server-URL eingeben"
        } else if (URLComponents(string: normalized)?.host ?? "").isEmpty {
            errors[.url] = "Ungültige URL"
        }
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors[.username] = "Bitte Benutzer eingeben"
        }
        if password.isEmpty {
            errors[.password] = "Bitte Passwort eingeben"
        }
        self.errors = errors
        return errors.isEmpty
    }

    /// Tries to log in with the entered values. Returns `true` on success.
    @discardableResult
    func test(quiet: Bool = false) async -> Bool {
        guard !busy, validate() else { return false }
        busy = true
        defer { busy = false }
        return await testConnection(current, quiet: quiet)
    }

    private func testConnection(_ settings: ServerSettings, quiet: Bool) async -> Bool {
        let client = app.makeClient(for: settings)
        defer { client.close() }
        do {
            let appName = try await client.testConnection()
            await client.logout()
            if !quiet { app.toasts.show("Verbindung erfolgreich (\(appName)).") }
            return true
        } catch let failure as AMPError {
            app.toasts.show(failure.message, isError: true)
            return false
        } catch {
            return false
        }
    }

    /// Saves the settings if they work. Returns `true` when they were saved.
    @discardableResult
    func save() async -> Bool {
        guard !busy, validate() else { return false }
        busy = true
        defer { busy = false }
        let settings = current
        guard await testConnection(settings, quiet: true) else { return false }
        do {
            try await app.saveSettings(settings)
        } catch {
            app.toasts.show(error.localizedDescription, isError: true)
            return false
        }
        app.toasts.show("Einstellungen gespeichert.")
        return true
    }

    /// Removes the saved settings after confirmation. Returns `true` when
    /// they were removed.
    @discardableResult
    func clear() async -> Bool {
        guard !busy else { return false }
        busy = true
        defer { busy = false }
        let confirmed = await dialogs.confirm(
            ConfirmationPrompt(
                title: "Zugangsdaten löschen?",
                message: "Server-URL, Benutzer und Passwort werden von diesem Gerät entfernt.",
                confirmLabel: "Löschen",
                isDestructive: true
            ))
        guard confirmed else { return false }
        do {
            try await app.clearSettings()
            return true
        } catch {
            app.toasts.show(error.localizedDescription, isError: true)
            return false
        }
    }
}
