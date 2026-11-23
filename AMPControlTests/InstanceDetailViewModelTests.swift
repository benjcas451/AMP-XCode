import Foundation
import Testing

@testable import AMPControl

@MainActor
@Suite(.timeLimit(.minutes(1)))
final class InstanceDetailViewModelTests {
    private var requests: [RecordedRequest] = []
    /// Responses by `Module/Method`, the same for every instance.
    private var responses: [String: JSONValue] = [
        "Core/GetUpdates": ["Status": ["State": 10], "ConsoleEntries": []],
        "Core/GetStatus": ["State": 10],
        "Core/GetUserList": [:],
        "LocalFileBackupPlugin/GetBackups": [],
        "FileManagerPlugin/GetDirectoryListing": [],
        "Core/GetSettingsSpec": [:],
        "Core/GetScheduleData": ["PopulatedTriggers": []],
        "Core/GetAuditLogEntries": [],
        "Core/UpdateApplication": ["Status": true],
    ]
    private var missingBackupInOne = false
    private let toasts = ToastCenter()
    private var client: AMPClient!

    init() {
        let transport = MockTransport { [unowned self] request in
            requests.append(request)
            let method = request.method
            if method == "Core/Login" {
                return .json(["success": true, "sessionID": "session"])
            }
            if missingBackupInOne, request.path.contains("/Servers/one/"),
                method == "LocalFileBackupPlugin/GetBackups"
            {
                return .json([
                    "Title": "MissingMethodException",
                    "Message": "Missing method",
                    "StackTrace": "",
                ])
            }
            if method == "Core/UpdateApplication" {
                responses["Core/GetStatus"] = ["State": 100]
                responses["Core/GetUpdates"] = ["Status": ["State": 100], "ConsoleEntries": []]
            }
            return .json(responses[method] ?? .null)
        }
        client = AMPClient(
            baseURL: "http://amp.local", username: "", password: "", transport: transport)
    }

    private func model(_ id: String = "one") async throws -> InstanceDetailViewModel {
        let instance = try AMPInstance(
            json: ["InstanceID": .string(id), "InstanceName": .string(id), "Running": true])
        let model = InstanceDetailViewModel(instance: instance, client: client, toasts: toasts)
        await model.loadAll()
        return model
    }

    private func count(_ method: String) -> Int {
        requests.filter { $0.method == method }.count
    }

    // MARK: - Tests

    @Test func playerLoadingErrorsAreVisibleAndCanBeRetried() async throws {
        responses["Core/GetUserList"] = [
            "Status": false, "Reason": "Spielerliste nicht erreichbar",
        ]
        let model = try await model()
        #expect(model.tabErrors[.users] == "Spielerliste nicht erreichbar")
        #expect(model.users == nil)
        #expect(!model.isLoading(.users))

        responses["Core/GetUserList"] = ["uuid": "Alex"]
        await model.reload(.users)
        #expect(model.users == ["Alex"])
        #expect(model.tabErrors[.users] == nil)
    }

    @Test func readOnlySettingsCannotBeOpenedForEditing() async throws {
        responses["Core/GetSettingsSpec"] = [
            "Minecraft": [
                [
                    "Node": "MinecraftModule.Server.MOTD",
                    "Name": "Server message",
                    "CurrentValue": "hello",
                    "ValType": "String",
                    "ReadOnly": true,
                ]
            ]
        ]
        let model = try await model()
        let setting = try #require(model.settings?.first)
        #expect(setting.displayName == "Server message")
        let edit = Task { await model.editSetting(setting) }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!model.dialogs.isRequestingText)
        // Ends the edit should the prompt have been shown after all.
        model.dialogs.answerText("changed")
        await edit.value
        #expect(count("Core/SetConfig") == 0)
    }

    @Test func editingASettingSavesTheNewValue() async throws {
        responses["Core/GetSettingsSpec"] = [
            "Minecraft": [
                ["Node": "MinecraftModule.Server.MOTD", "CurrentValue": "hello", "ValType": "String"]
            ]
        ]
        responses["Core/SetConfig"] = ["Status": true]
        let model = try await model()
        let setting = try #require(model.settings?.first)

        let edit = Task { await model.editSetting(setting) }
        await waitUntil("the value is asked for") { model.dialogs.isRequestingText }
        #expect(model.dialogs.textPrompt?.title == "MOTD")
        #expect(model.dialogs.textPrompt?.placeholder == "Wert (String)")
        #expect(model.dialogs.text == "hello")
        model.dialogs.answerText("  welcome  ")
        await edit.value

        #expect(requests.last { $0.method == "Core/SetConfig" }?.body["value"] == "  welcome  ")
        #expect(toasts.current?.text == "Setting „MOTD“ gespeichert.")
        #expect(!model.isBusy(.settings))
    }

    @Test func unsupportedPluginsInOneInstanceDoNotHideTabsInAnother() async throws {
        missingBackupInOne = true
        let one = try await model("one")
        #expect(!one.tabs.contains(.backups))
        #expect(one.tabs.contains(.files))
        let two = try await model("two")
        #expect(two.tabs.contains(.backups))
        #expect(two.tabs == DetailTab.allCases)
    }

    @Test func aTabThatDisappearsFallsBackToTheOverview() async throws {
        let model = try await model()
        model.selectedTab = .backups
        missingBackupInOne = true
        await model.reload(.backups)
        #expect(!model.tabs.contains(.backups))
        #expect(model.selectedTab == .overview)
    }

    @Test func theGameUpdateTabOffersTheApplicationUpdateAndTracksProgress() async throws {
        let model = try await model()
        #expect(count("Core/Login") == 1)
        #expect(model.tabs.contains(.updates))
        #expect(model.updateStatus?.state == .stopped)

        let update = Task { await model.runUpdate() }
        await waitUntil("the confirmation is shown") { model.dialogs.isConfirming }
        #expect(model.dialogs.confirmation?.title == "Spielserver aktualisieren?")
        #expect(count("Core/UpdateApplication") == 0)
        model.dialogs.answerConfirmation(true)
        await update.value

        #expect(count("Core/UpdateApplication") == 1)
        #expect(model.updateStatus?.state == .updating)
        #expect(model.updateStatus?.state.isStopped == false)
        #expect(!model.isBusy(.update))
    }

    @Test func creatingABackupAsksForATrimmedName() async throws {
        responses["LocalFileBackupPlugin/TakeBackup"] = ["Status": true]
        let model = try await model()

        let create = Task { await model.createBackup() }
        await waitUntil("the name is asked for") { model.dialogs.isRequestingText }
        #expect(model.dialogs.text.hasPrefix("backup-"))
        model.dialogs.answerText("  nightly  ")
        await create.value

        let request = requests.last { $0.method == "LocalFileBackupPlugin/TakeBackup" }
        #expect(request?.body["Title"] == "nightly")
        #expect(toasts.current?.text == "Backup „nightly“ wird erstellt.")
        #expect(count("LocalFileBackupPlugin/GetBackups") == 2)
    }

    @Test func cancellingAPromptSendsNothing() async throws {
        let model = try await model()
        let create = Task { await model.createFolder() }
        await waitUntil("the path is asked for") { model.dialogs.isRequestingText }
        model.dialogs.answerText(nil)
        await create.value
        #expect(count("FileManagerPlugin/CreateDirectory") == 0)
        #expect(toasts.current == nil)
    }

    @Test func serverActionsReportFailuresAndRefreshTheStatus() async throws {
        responses["Core/Start"] = ["Status": false, "Reason": "EULA not accepted"]
        let model = try await model()
        let polls = count("Core/GetUpdates")
        await model.startServer()
        #expect(toasts.current?.text == "EULA not accepted")
        #expect(count("Core/GetUpdates") == polls + 1)
        #expect(!model.isBusy(.server))
    }

    @Test func theConsoleKeepsOnlyTheNewestLines() async throws {
        let model = try await model()
        let lines = (0..<(InstanceDetailViewModel.maxConsoleLines + 20)).map { index -> JSONValue in
            ["Contents": .string("line \(index)"), "Type": "Console"]
        }
        responses["Core/GetUpdates"] = ["Status": ["State": 40], "ConsoleEntries": .array(lines)]
        await model.poll()
        #expect(model.console.count == InstanceDetailViewModel.maxConsoleLines)
        #expect(model.console.first?.entry.contents == "line 20")
        #expect(model.console.last?.entry.contents == "line 519")
        #expect(Set(model.console.map(\.id)).count == model.console.count)
        #expect(model.status?.state == .ready)
    }

    @Test func pollingErrorsAreShownUntilTheNextSuccessfulPoll() async throws {
        let model = try await model()
        responses["Core/GetUpdates"] = ["Status": false, "Reason": "Instanz nicht erreichbar"]
        await model.poll()
        #expect(model.error == "Instanz nicht erreichbar")
        responses["Core/GetUpdates"] = ["Status": ["State": 10], "ConsoleEntries": []]
        await model.poll()
        #expect(model.error == nil)
    }
}
