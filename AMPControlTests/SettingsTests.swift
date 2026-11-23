import Foundation
import Testing

@testable import AMPControl

@MainActor
@Suite(.timeLimit(.minutes(1)))
final class SettingsTests {
    private let store = InMemorySettingsStore()
    private var requests: [RecordedRequest] = []
    private var app: AppModel!

    init() {
        app = makeApp()
    }

    /// An app whose server accepts only admin/secret.
    private func makeApp() -> AppModel {
        AppModel(store: store) { [unowned self] in
            MockTransport { [unowned self] request in
                requests.append(request)
                switch request.method {
                case "Core/GetModuleInfo":
                    return .json(["Author": "CubeCoders Limited", "AppName": "ADS"])
                case "Core/Login":
                    if request.body["username"] == "admin" && request.body["password"] == "secret" {
                        return .json(["success": true, "sessionID": "session"])
                    }
                    return .json(["success": false, "resultReason": "Bad credentials"])
                default:
                    return .json(["Status": true])
                }
            }
        }
    }

    private func form(url: String = "amp.local:8080/", user: String = " admin ", password: String)
        -> SettingsViewModel
    {
        let form = SettingsViewModel(app: app)
        form.url = url
        form.username = user
        form.password = password
        return form
    }

    @Test func saveStaysLockedThroughOldClientLogoutAndUsesTestedValues() async throws {
        #expect(await form(password: "secret").save())
        let testGate = Gate()
        let gate = Gate()
        var logouts = 0
        let oldSettings = store.load()
        let app = AppModel(store: store) {
            MockTransport { request in
                switch request.method {
                case "Core/GetModuleInfo":
                    return .json(["Author": "CubeCoders Limited", "AppName": "ADS"])
                case "Core/Login":
                    return .json(["success": true, "sessionID": "session"])
                case "Core/Logout":
                    logouts += 1
                    if logouts == 1 {
                        await testGate.wait()
                    } else {
                        await gate.wait()
                    }
                    return .json(["Status": true])
                default:
                    return .json([])
                }
            }
        }
        _ = try await app.client?.getInstances()
        let form = SettingsViewModel(app: app)
        let saving = Task { await form.save() }
        await waitUntil("connection test logout is pending") { testGate.waiters == 1 }
        form.username = "edited-after-test"
        testGate.open()
        await waitUntil("old client logout is pending") { gate.waiters == 1 }
        #expect(form.busy)
        #expect(await form.save() == false)
        #expect(await form.test() == false)
        #expect(await form.clear() == false)
        gate.open()
        #expect(await saving.value)
        #expect(store.load() == oldSettings)
        #expect(!form.busy)
    }

    private struct FailingStore: SettingsStore {
        let settings = ServerSettings(url: "http://amp.local", username: "admin", password: "secret")
        func load() -> ServerSettings { settings }
        func save(_ settings: ServerSettings) throws { throw AMPError("Speichern fehlgeschlagen") }
        func clear() throws { throw AMPError("Löschen fehlgeschlagen") }
    }

    @Test func failedSaveKeepsTheConfiguredClientAndSettings() async {
        let store = FailingStore()
        let app = AppModel(store: store)
        let client = app.client
        let error = await ampError {
            try await app.saveSettings(ServerSettings(url: "http://new", username: "new", password: "new"))
        }
        #expect(error?.message == "Speichern fehlgeschlagen")
        #expect(app.settings == store.settings)
        #expect(app.client === client)
    }

    @Test func failedClearKeepsTheConfiguredClientAndShowsAnError() async {
        let store = FailingStore()
        let app = AppModel(store: store)
        let client = app.client
        let form = SettingsViewModel(app: app)
        let clearing = Task { await form.clear() }
        await waitUntil("clear confirmation") { form.dialogs.isConfirming }
        form.dialogs.answerConfirmation(true)
        #expect(await clearing.value == false)
        #expect(app.settings == store.settings)
        #expect(app.client === client)
        #expect(app.toasts.current?.text == "Löschen fehlgeschlagen")
        #expect(app.toasts.current?.isError == true)
        #expect(!form.busy)
    }

    @Test func startsUnconfigured() {
        #expect(!app.isConfigured)
        #expect(app.client == nil)
    }

    @Test func validatesTheFormBeforeContactingTheServer() async {
        let form = form(url: "", user: " ", password: "")
        #expect(await form.save() == false)
        #expect(
            form.errors == [
                .url: "Bitte Server-URL eingeben",
                .username: "Bitte Benutzer eingeben",
                .password: "Bitte Passwort eingeben",
            ])
        #expect(requests.isEmpty)

        form.url = "http://"
        #expect(!form.validate())
        #expect(form.errors[.url] == "Ungültige URL")
    }

    @Test func testReportsTheServerWithoutSaving() async {
        let form = form(password: "secret")
        #expect(await form.test())
        #expect(app.toasts.current?.text == "Verbindung erfolgreich (ADS).")
        #expect(app.toasts.current?.isError == false)
        #expect(!app.isConfigured)
        #expect(requests.map(\.method) == ["Core/GetModuleInfo", "Core/Login", "Core/Logout"])
        #expect(!form.busy)
    }

    @Test func wrongCredentialsAreNotSaved() async {
        let form = form(password: "nope")
        #expect(await form.save() == false)
        #expect(app.toasts.current?.text == "Anmeldung fehlgeschlagen: Bad credentials")
        #expect(app.toasts.current?.isError == true)
        #expect(!app.isConfigured)
        #expect(store.load() == ServerSettings())
    }

    @Test func savingStoresNormalizedSettingsAndConnects() async {
        let form = form(password: "secret")
        #expect(await form.save())
        let saved = ServerSettings(url: "http://amp.local:8080", username: "admin", password: "secret")
        #expect(app.settings == saved)
        #expect(store.load() == saved)
        #expect(app.client?.baseURL == "http://amp.local:8080")
        #expect(app.toasts.current?.text == "Einstellungen gespeichert.")
    }

    @Test func savedSettingsAreRestoredOnLaunch() async {
        #expect(await form(password: "secret").save())
        let relaunched = makeApp()
        #expect(relaunched.isConfigured)
        #expect(relaunched.client != nil)
        #expect(SettingsViewModel(app: relaunched).url == "http://amp.local:8080")
    }

    @Test func newSettingsReplaceTheClient() async {
        #expect(await form(password: "secret").save())
        let first = app.client
        #expect(await form(url: "https://amp.example.com", password: "secret").save())
        #expect(app.client !== first)
        #expect(app.client?.baseURL == "https://amp.example.com")
    }

    @Test func clearingAsksFirstAndRemovesEverything() async {
        #expect(await form(password: "secret").save())
        let form = SettingsViewModel(app: app)

        let cancelled = Task { await form.clear() }
        await waitUntil("the confirmation is shown") { form.dialogs.isConfirming }
        #expect(form.dialogs.confirmation?.title == "Zugangsdaten löschen?")
        form.dialogs.answerConfirmation(false)
        #expect(await cancelled.value == false)
        #expect(app.isConfigured)

        let confirmed = Task { await form.clear() }
        await waitUntil("the confirmation is shown") { form.dialogs.isConfirming }
        form.dialogs.answerConfirmation(true)
        #expect(await confirmed.value)
        #expect(!app.isConfigured)
        #expect(app.client == nil)
        #expect(store.load() == ServerSettings())
    }
}
