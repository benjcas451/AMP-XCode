import Foundation
import Testing

@testable import AMPControl

@MainActor
@Suite(.timeLimit(.minutes(1)))
final class AMPClientTests {
    private var calls: [String] = []
    private var bodies: [JSONObject] = []
    private var instanceActionResult: JSONValue = ["Status": true]
    private let sessions = Sessions()

    private func record(_ request: RecordedRequest) {
        calls.append(request.path)
        bodies.append(request.body)
    }

    private func count(_ suffix: String) -> Int {
        calls.filter { $0.hasSuffix(suffix) }.count
    }

    private func makeClient(password: String = "secret", _ handler: @escaping MockTransport.Handler)
        -> AMPClient
    {
        AMPClient(
            baseURL: "amp.local:8080/", username: "admin", password: password,
            transport: MockTransport(handler))
    }

    // MARK: - Fake AMPs

    private func client(password: String = "secret") -> AMPClient {
        makeClient(password: password) { [self] request in
            let path = request.path
            let body = request.body
            record(request)

            if path.hasSuffix("/API/Core/Login") {
                if body["username"] == "admin" && body["password"] == "secret" {
                    return sessions.login()
                }
                return .json(["success": false, "resultReason": "Bad credentials"])
            }
            if path == "/API/Core/GetModuleInfo" {
                return .json(["Author": "CubeCoders Limited", "AppName": "ADS"])
            }
            if !sessions.accepts(request) { return .text("", status: 401) }

            let instance = "/API/ADSModule/Servers/mc/API"
            switch path {
            case "/API/ADSModule/GetInstances":
                return .json([
                    "result": [
                        [
                            "AvailableInstances": [
                                [
                                    "InstanceID": "ads",
                                    "InstanceName": "ADS01",
                                    "Module": "ADS",
                                    "Running": true,
                                ],
                                [
                                    "InstanceID": "mc",
                                    "InstanceName": "Minecraft01",
                                    "FriendlyName": "Survival",
                                    "Module": "Minecraft",
                                    "Running": true,
                                    "AppState": 20,
                                    "Metrics": [
                                        "CPU Usage": [
                                            "RawValue": 12,
                                            "MaxValue": 100,
                                            "Percent": 12,
                                            "Units": "%",
                                        ]
                                    ],
                                ],
                            ]
                        ]
                    ]
                ])
            case "/API/ADSModule/StartInstance", "/API/ADSModule/StopInstance":
                return .json(instanceActionResult)
            case "\(instance)/Core/GetUpdates":
                return .json([
                    "Status": ["State": 0, "Uptime": "00:00:00", "Metrics": [:]],
                    "ConsoleEntries": [
                        [
                            "Timestamp": "/Date(1700000000000)/",
                            "Source": "Console",
                            "Type": "Console",
                            "Contents": "Done (3.2s)!",
                        ]
                    ],
                ])
            case "\(instance)/Core/GetUserList":
                return .json(["result": ["uuid-2": "Steve", "uuid-1": "Alex"]])
            case "\(instance)/LocalFileBackupPlugin/GetBackups":
                return .json([
                    "Backups": [
                        [
                            "Id": "backup-id",
                            "Name": "world-2024-06-01",
                            "Timestamp": "2024-06-01T12:00:00Z",
                            "TotalSizeBytes": 2048,
                        ]
                    ]
                ])
            case "\(instance)/LocalFileBackupPlugin/TakeBackup",
                "\(instance)/LocalFileBackupPlugin/RestoreBackup",
                "\(instance)/LocalFileBackupPlugin/DeleteLocalBackup":
                return .json(["Status": true])
            case "\(instance)/Core/Start":
                return .json(["Status": false, "Reason": "EULA not accepted"])
            default:
                return .text("not found", status: 404)
            }
        }
    }

    /// A fake whose login always succeeds and that serves `routes` by path
    /// relative to the instance `mc`.
    private func instanceClient(_ routes: [String: JSONValue]) -> AMPClient {
        makeClient { [self] request in
            record(request)
            if request.path.hasSuffix("/API/Core/Login") { return sessions.login() }
            if !sessions.accepts(request) { return .text("", status: 401) }
            let prefix = "/API/ADSModule/Servers/mc/API/"
            if request.path.hasPrefix(prefix),
                let response = routes[String(request.path.dropFirst(prefix.count))]
            {
                return .json(response)
            }
            return .text("not found", status: 404)
        }
    }

    private func filesClient() -> AMPClient {
        instanceClient([
            "FileManagerPlugin/GetDirectoryListing": [
                "result": [
                    ["Filename": "config", "IsDirectory": true],
                    ["Filename": "server.properties", "IsDirectory": false, "SizeBytes": 512],
                ]
            ],
            "FileManagerPlugin/CreateDirectory": ["Status": true],
            "FileManagerPlugin/TrashFile": ["Status": true],
            "FileManagerPlugin/RenameFile": ["Status": true],
        ])
    }

    private func settingsClient() -> AMPClient {
        instanceClient([
            "Core/GetSettingsSpec": [
                "Minecraft": [
                    [
                        "Name": "ServerName",
                        "Node": "MinecraftModule.Minecraft.ServerName",
                        "CurrentValue": "My Server",
                        "ValType": "String",
                        "Description": "Name of the server shown in the list",
                    ],
                    [
                        "Name": "MaxPlayers",
                        "Node": "MinecraftModule.Minecraft.MaxPlayers",
                        "CurrentValue": "20",
                        "ValType": "Integer",
                        "Description": "Maximum number of players",
                    ],
                    [
                        "Name": "",
                        "Node": "MinecraftModule.Minecraft.EnableQuery",
                        "Value": "false",
                        "Type": "Boolean",
                        "Description": "",
                    ],
                ]
            ],
            "Core/SetConfig": ["Status": true],
        ])
    }

    private func schedulerClient() -> AMPClient {
        instanceClient([
            "Core/GetScheduleData": [
                "AvailableMethods": [],
                "AvailableTriggers": [],
                "PopulatedTriggers": [
                    [
                        "Id": "trigger-1",
                        "Description": "Nightly Backup",
                        "TriggerType": "TimeInterval",
                        "EnabledState": 1,
                        "Tasks": [["TaskMethodName": "LocalFileBackupPlugin.TakeBackup"]],
                    ],
                    [
                        "Id": "trigger-2",
                        "Description": "Restart server",
                        "TriggerType": "TimeInterval",
                        "EnabledState": 0,
                        "Tasks": [],
                    ],
                ],
            ],
            "Core/SetTriggerEnabled": ["Status": true],
            "Core/GetAuditLogEntries": [
                [
                    "Message": "Backup completed",
                    "Timestamp": "/Date(1700000000000)/",
                    "Category": "Backup",
                ],
                [
                    "Message": "Task failed",
                    "Timestamp": "/Date(1700000100000)/",
                    "Category": "Scheduler",
                ],
            ],
            "Core/GetStatus": ["State": 75, "Uptime": "", "Metrics": [:]],
            "Core/UpdateApplication": ["Status": true],
        ])
    }

    // MARK: - Connection and sessions

    @Test func normalizesURLs() {
        #expect(AMPClient.normalizeURL(" amp.local:8080/ ") == "http://amp.local:8080")
        #expect(AMPClient.normalizeURL("https://x.de//") == "https://x.de")
    }

    @Test func testConnectionLogsIn() async throws {
        #expect(try await client().testConnection() == "ADS")
    }

    @Test func wrongPasswordYieldsReadableError() async {
        let error = await ampError { _ = try await client(password: "nope").testConnection() }
        #expect(error?.message.contains("Bad credentials") == true)
    }

    @Test func listsInstancesWithoutTheADSItself() async throws {
        let list = try await client().getInstances()
        #expect(list.map(\.displayName) == ["Survival"])
        #expect(list.first?.appState == .ready)
        #expect(list.first?.metrics["CPU Usage"]?.valueText == "12 %")
    }

    @Test func instanceCallsUseTheADSProxyWithTheirOwnSession() async throws {
        let client = client()
        let updates = try await client.getUpdates("mc")
        #expect(updates.status?.state == .stopped)
        #expect(updates.console.map(\.contents) == ["Done (3.2s)!"])
        #expect(updates.console.first?.timestamp == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(
            calls == [
                "/API/ADSModule/Servers/mc/API/Core/Login",
                "/API/ADSModule/Servers/mc/API/Core/GetUpdates",
            ])
        #expect(try await client.getUsers("mc") == ["Alex", "Steve"])
    }

    @Test func logsInAgainOnceWhenTheSessionExpired() async throws {
        let client = client()
        _ = try await client.getInstances()
        sessions.valid.removeAll()
        _ = try await client.getInstances()
        #expect(count("Login") == 2)
    }

    @Test func failedActionsSurfaceTheReason() async {
        let error = await ampError { try await client().startServer("mc") }
        #expect(error?.message == "EULA not accepted")
    }

    // MARK: - Instance process

    @Test(arguments: [true, false])
    func instanceProcessUsesTheADSSessionAndInternalName(start: Bool) async throws {
        let method = start ? "StartInstance" : "StopInstance"
        let client = client()
        let instance = try #require(try await client.getInstances().first)
        calls.removeAll()
        bodies.removeAll()
        if start {
            try await client.startInstanceProcess(instance)
        } else {
            try await client.stopInstanceProcess(instance)
        }
        #expect(calls == ["/API/ADSModule/\(method)"])
        #expect(bodies == [["InstanceName": "Minecraft01", "SESSIONID": "sid1"]])
    }

    @Test(arguments: [true, false])
    func instanceProcessChangeClearsCachedInstanceSessions(start: Bool) async throws {
        let client = client()
        let instance = try #require(try await client.getInstances().first)
        _ = try await client.getUpdates(instance.id)
        if start {
            try await client.startInstanceProcess(instance)
        } else {
            try await client.stopInstanceProcess(instance)
        }
        _ = try await client.getUpdates(instance.id)
        #expect(calls.filter { $0 == "/API/ADSModule/Servers/mc/API/Core/Login" }.count == 2)
        #expect(calls.filter { $0 == "/API/Core/Login" }.count == 1)
    }

    @Test func failedInstanceStopSurfacesTheADSReason() async throws {
        let client = client()
        let instance = try #require(try await client.getInstances().first)
        instanceActionResult = ["Status": false, "Reason": "Instance stop denied"]
        let error = await ampError { try await client.stopInstanceProcess(instance) }
        #expect(error?.message == "Instance stop denied")
    }

    @Test func booleanFalseIsReportedAsAnActionFailure() async throws {
        let client = client()
        let instance = try #require(try await client.getInstances().first)
        instanceActionResult = ["result": false]
        let error = await ampError { try await client.startInstanceProcess(instance) }
        #expect(error?.message == "StartInstance fehlgeschlagen.")
    }

    // MARK: - Backups

    @Test func backupListAndActionsGoThroughTheInstanceAPI() async throws {
        let client = client()
        let backups = try await client.getBackups("mc")
        #expect(backups.map(\.name) == ["world-2024-06-01"])
        #expect(backups.first?.sizeBytes == 2048)

        try await client.createBackup("mc", name: "manual-backup")
        try await client.restoreBackup("mc", backupID: "backup-id")
        try await client.deleteBackup("mc", backupID: "backup-id")

        #expect(count("/API/LocalFileBackupPlugin/GetBackups") == 1)
        #expect(count("/API/LocalFileBackupPlugin/TakeBackup") == 1)
        #expect(count("/API/LocalFileBackupPlugin/RestoreBackup") == 1)
        #expect(count("/API/LocalFileBackupPlugin/DeleteLocalBackup") == 1)
    }

    @Test func backupNamesAreTrimmedBeforeTheRequestIsSent() async throws {
        try await client().createBackup("mc", name: "  manual-backup  ")
        #expect(bodies.last?["Title"] == "manual-backup")
    }

    @Test func emptyBackupNamesAreRejectedBeforeTheRequestIsSent() async {
        let client = client()
        let create = await ampError { try await client.createBackup("mc", name: "   ") }
        #expect(create?.message == "Backup-Name darf nicht leer sein.")
        let restore = await ampError { try await client.restoreBackup("mc", backupID: "") }
        #expect(restore?.message == "Backup-ID darf nicht leer sein.")
        let delete = await ampError { try await client.deleteBackup("mc", backupID: "  ") }
        #expect(delete?.message == "Backup-ID darf nicht leer sein.")
        #expect(calls.isEmpty)
    }

    // MARK: - Files

    @Test func listsFilesFromTheInstanceFileAPI() async throws {
        let files = try await filesClient().getFiles("mc")
        #expect(files.map(\.isDirectory) == [true, false])
        #expect(files.last?.sizeBytes == 512)
    }

    @Test func fileActionsUseTheInstanceAPI() async throws {
        let client = filesClient()
        try await client.createDirectory("mc", path: "plugins/new")
        try await client.deleteFile("mc", path: "server.properties")
        try await client.renameFile(
            "mc", path: "server.properties", newName: "server-old.properties")
        #expect(count("/API/FileManagerPlugin/CreateDirectory") == 1)
        #expect(count("/API/FileManagerPlugin/TrashFile") == 1)
        #expect(count("/API/FileManagerPlugin/RenameFile") == 1)
    }

    @Test func filePathsAreValidatedBeforeRequestsAreSent() async {
        let client = filesClient()
        let create = await ampError { try await client.createDirectory("mc", path: "   ") }
        #expect(create?.message == "Pfad darf nicht leer sein.")
        let rename = await ampError {
            try await client.renameFile("mc", path: "plugins/a.cfg", newName: "")
        }
        #expect(rename?.message == "Umbenennen benötigt gültige Dateinamen.")
        #expect(calls.isEmpty)
    }

    // MARK: - Settings

    @Test func listsSettingsFromTheInstanceSettingsAPI() async throws {
        let settings = try await settingsClient().getSettings("mc")
        #expect(settings.count == 3)
        #expect(settings.map(\.displayName) == ["Enable Query", "MaxPlayers", "ServerName"])
        #expect(settings.map(\.name) == ["", "MaxPlayers", "ServerName"])
    }

    @Test func settingsWithoutANameKeepTheirKeyAndGetAReadableTitle() async throws {
        let client = settingsClient()
        let settings = try await client.getSettings("mc")
        let query = try #require(settings.first { $0.name.isEmpty })
        #expect(query.key == "MinecraftModule.Minecraft.EnableQuery")
        #expect(query.displayName == "Enable Query")
        #expect(query.type == "Boolean")
        #expect(query.value == "false")

        try await client.setSetting("mc", node: query.key, value: "true")
        #expect(bodies.last?["node"] == "MinecraftModule.Minecraft.EnableQuery")
    }

    @Test func displayNamesAreDerivedFromSettingKeys() {
        func title(_ key: String) -> String { SettingEntry(json: [:], key: key).displayName }

        #expect(title("Meta.GenericModule.AutoRestartOnCrash") == "Auto Restart On Crash")
        #expect(title("MinecraftModule.Minecraft.ServerIP") == "Server IP")
        #expect(title("Core.Webserver.UseHTTPSRedirect") == "Use HTTPS Redirect")
        #expect(title("max_players") == "max players")
        #expect(title("") == "Unbenannte Einstellung")
        #expect(
            SettingEntry(json: ["Name": "Accepts Transfers"], key: "X.Y").displayName
                == "Accepts Transfers")
    }

    @Test func setSettingSendsTheValueThroughTheInstanceAPI() async throws {
        try await settingsClient().setSetting(
            "mc", node: "MinecraftModule.Minecraft.ServerName", value: "New Server Name")
        #expect(count("/API/Core/SetConfig") == 1)
        #expect(bodies.last?["node"] == "MinecraftModule.Minecraft.ServerName")
        #expect(bodies.last?["value"] == "New Server Name")
    }

    @Test func settingNameIsValidatedBeforeRequestsAreSent() async {
        let client = settingsClient()
        let error = await ampError { try await client.setSetting("mc", node: "", value: "value") }
        #expect(error?.message == "Setting-Name darf nicht leer sein.")
        #expect(calls.isEmpty)
    }

    // MARK: - Schedule, events, updates

    @Test func listsSchedulerTasks() async throws {
        let tasks = try await schedulerClient().getTasks("mc")
        #expect(tasks.map(\.name) == ["Nightly Backup", "Restart server"])
    }

    @Test func taskEnabledCanBeToggled() async throws {
        try await schedulerClient().setTaskEnabled("mc", taskID: "trigger-1", enabled: false)
        #expect(count("/API/Core/SetTriggerEnabled") == 1)
        #expect(bodies.last?["Id"] == "trigger-1")
        #expect(bodies.last?["Enabled"] == false)
    }

    @Test func taskIDIsValidatedBeforeRequestsAreSent() async {
        let client = schedulerClient()
        let error = await ampError {
            try await client.setTaskEnabled("mc", taskID: "", enabled: false)
        }
        #expect(error?.message == "Task-ID darf nicht leer sein.")
        #expect(calls.isEmpty)
    }

    @Test func listsEventsSortedByTimestampDescending() async throws {
        let events = try await schedulerClient().getEvents("mc")
        #expect(events.map(\.message) == ["Task failed", "Backup completed"])
    }

    @Test func returnsUpdateStatus() async throws {
        #expect(try await schedulerClient().getUpdateStatus("mc").state == .updating)
    }

    @Test func runUpdateUsesTheInstanceAPI() async throws {
        try await schedulerClient().runUpdate("mc")
        #expect(count("/API/Core/UpdateApplication") == 1)
    }
}
