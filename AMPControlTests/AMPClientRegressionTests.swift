import Foundation
import Testing

@testable import AMPControl

/// Every read the client offers, to check them all against the same faults.
enum Getter: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case instances, status, updates, users, backups, files, settings, schedule, events
    case applicationUpdateStatus

    var testDescription: String { rawValue }

    @MainActor
    func read(_ client: AMPClient) async throws {
        switch self {
        case .instances: _ = try await client.getInstances()
        case .status: _ = try await client.getStatus("mc")
        case .updates: _ = try await client.getUpdates("mc")
        case .users: _ = try await client.getUsers("mc")
        case .backups: _ = try await client.getBackups("mc")
        case .files: _ = try await client.getFiles("mc")
        case .settings: _ = try await client.getSettings("mc")
        case .schedule: _ = try await client.getTasks("mc")
        case .events: _ = try await client.getEvents("mc")
        case .applicationUpdateStatus: _ = try await client.getUpdateStatus("mc")
        }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
final class AMPClientRegressionTests {
    private var requests: [RecordedRequest] = []
    /// Answers every call except the login.
    private var respond: MockTransport.Handler = { _ in .json([]) }
    private var client: AMPClient!

    init() {
        client = makeClient { [unowned self] request in
            requests.append(request)
            if request.path.hasSuffix("/Core/Login") {
                return .json(["success": true, "sessionID": "session"])
            }
            return try await respond(request)
        }
    }

    private func makeClient(_ handler: @escaping MockTransport.Handler) -> AMPClient {
        AMPClient(
            baseURL: "http://amp.local", username: "admin", password: "secret",
            transport: MockTransport(handler))
    }

    private func respond(with value: JSONValue, status: Int = 200) {
        respond = { _ in .json(value, status: status) }
    }

    private func supportsBackups(module: String = "LocalFileBackupPlugin", instance: String)
        -> Bool
    {
        client.isMethodSupported("GetBackups", module: module, instanceID: instance)
    }

    // MARK: - Malformed and failed reads

    @Test(arguments: Getter.allCases)
    func rejectsUnexpectedScalarsAndNull(getter: Getter) async {
        for value: JSONValue in ["unexpected", .null] {
            respond(with: value)
            let error = await ampError { try await getter.read(client) }
            #expect(error?.message.contains("Ungültige Antwort") == true, "\(value)")
        }
    }

    @Test(arguments: Getter.allCases)
    func preservesTheReasonOfAFailedRead(getter: Getter) async {
        respond(with: ["Status": false, "Reason": "Access denied"])
        let error = await ampError { try await getter.read(client) }
        #expect(error?.message == "Access denied")
    }

    @Test func badListEntriesSurfaceAnAMPError() async {
        respond(with: [.null])
        for getter in [Getter.instances, .files, .backups, .events] {
            let error = await ampError { try await getter.read(client) }
            #expect(error != nil, "\(getter)")
        }
    }

    @Test func invalidMetricsAndConsoleEntriesAreReportedAsReadErrors() async {
        respond(with: ["State": 40, "Metrics": ["CPU Usage": ["RawValue": "invalid"]]])
        #expect(await ampError { _ = try await client.getStatus("mc") } != nil)
        respond(with: ["Status": ["State": 40], "ConsoleEntries": [.null]])
        #expect(await ampError { _ = try await client.getUpdates("mc") } != nil)
        respond(with: ["State": "invalid"])
        #expect(await ampError { _ = try await client.getStatus("mc") } != nil)
    }

    @Test func validEmptyCollectionsStayEmpty() async throws {
        respond(with: [])
        #expect(try await client.getInstances().isEmpty)
        #expect(try await client.getFiles("mc").isEmpty)
        #expect(try await client.getBackups("mc").isEmpty)
        #expect(try await client.getEvents("mc").isEmpty)
        respond(with: [:])
        #expect(try await client.getUsers("mc").isEmpty)
        #expect(try await client.getSettings("mc").isEmpty)
        respond(with: ["PopulatedTriggers": []])
        #expect(try await client.getTasks("mc").isEmpty)
    }

    // MARK: - Request and response details

    @Test func backupManifestsPreserveIDsDatesAndSizes() async throws {
        respond(with: [
            [
                "Id": "backup-id",
                "Name": "Daily backup",
                "Timestamp": "2026-10-03T09:00:00Z",
                "TotalSizeBytes": 4096,
            ]
        ])
        let backup = try #require(try await client.getBackups("mc").first)
        #expect(backup.id == "backup-id")
        #expect(backup.name == "Daily backup")
        #expect(backup.createdAt == "2026-10-03T09:00:00Z")
        #expect(backup.sizeBytes == 4096)

        respond(with: ["Status": true])
        try await client.restoreBackup("mc", backupID: backup.id)
        #expect(requests.last?.body["BackupId"] == "backup-id")
        try await client.deleteBackup("mc", backupID: backup.id)
        #expect(requests.last?.method == "LocalFileBackupPlugin/DeleteLocalBackup")
        #expect(requests.last?.body["BackupId"] == "backup-id")
    }

    @Test func directoryListingsDerivePathsAndDistinguishFileAndFolderActions() async throws {
        respond(with: [["Filename": "config.yml", "SizeBytes": 123]])
        let file = try #require(try await client.getFiles("mc", directory: "plugins/").first)
        #expect(file.name == "config.yml")
        #expect(file.path == "plugins/config.yml")
        #expect(requests.last?.body["Dir"] == "plugins/")

        respond(with: ["Status": true])
        try await client.deleteFile("mc", path: "plugins", isDirectory: true)
        #expect(requests.last?.method == "FileManagerPlugin/TrashDirectory")
        #expect(requests.last?.body["DirectoryName"] == "plugins")
        try await client.renameFile(
            "mc", path: "plugins", newName: "plugins-old", isDirectory: true)
        #expect(requests.last?.method == "FileManagerPlugin/RenameDirectory")
        #expect(requests.last?.body["oldDirectory"] == "plugins")
        #expect(requests.last?.body["NewDirectoryName"] == "plugins-old")
    }

    @Test func groupedSettingsRetainNodeIDsCurrentValuesAndReadOnlyFlags() async throws {
        respond(with: [
            "Minecraft": [
                [
                    "Node": "MinecraftModule.Server.MOTD",
                    "Name": "Server message",
                    "CurrentValue": "  hello  ",
                    "ValType": "String",
                    "ReadOnly": true,
                ]
            ]
        ])
        let setting = try #require(try await client.getSettings("mc").first)
        #expect(setting.node == "MinecraftModule.Server.MOTD")
        #expect(setting.value == "  hello  ")
        #expect(setting.readOnly)

        respond(with: ["Status": true])
        try await client.setSetting("mc", node: setting.node, value: "  new message  ")
        #expect(requests.last?.body["node"] == .string(setting.node))
        #expect(requests.last?.body["value"] == "  new message  ")
    }

    @Test func schedulerListsPopulatedTriggersRatherThanRunningTasks() async throws {
        respond(with: [
            "PopulatedTriggers": [
                [
                    "Id": "trigger",
                    "Description": "Daily backup",
                    "TriggerType": "TimeInterval",
                    "EnabledState": 2,
                    "Tasks": [["TaskMethodName": "LocalFileBackupPlugin.TakeBackup"]],
                ]
            ]
        ])
        let task = try #require(try await client.getTasks("mc").first)
        #expect(requests.last?.method == "Core/GetScheduleData")
        #expect(task.id == "trigger")
        #expect(task.name == "Daily backup")
        #expect(task.enabled)
        #expect(task.description == "LocalFileBackupPlugin.TakeBackup")

        respond(with: ["Status": true])
        try await client.setTaskEnabled("mc", taskID: task.id, enabled: false)
        #expect(requests.last?.method == "Core/SetTriggerEnabled")
        #expect(requests.last?.body["Id"] == "trigger")
    }

    @Test func auditLogRequestsAreBoundedAndUndatedEntriesSortLast() async throws {
        respond(with: [
            ["Message": "Unknown date"],
            ["Message": "Old", "Timestamp": "/Date(1700000000000)/"],
            ["Message": "New", "Timestamp": "/Date(1700000100000)/"],
        ])
        let entries = try await client.getEvents("mc")
        #expect(entries.map(\.message) == ["New", "Old", "Unknown date"])
        #expect(requests.last?.body["Before"] == .null)
        #expect(requests.last?.body["Count"] == 100)
    }

    // MARK: - Capability tracking

    @Test(arguments: [false, true])
    func missingMethodsAreScopedToTheirModuleAndInstance(withStackTrace: Bool) async throws {
        var fault: JSONObject = ["Title": "MissingMethodException", "Message": "Missing method"]
        if withStackTrace { fault["StackTrace"] = "trace" }
        respond(with: .object(fault), status: 500)
        let error = await ampError { _ = try await client.getBackups("one") }
        #expect(error?.isMethodUnavailable == true)
        #expect(!supportsBackups(instance: "one"))
        #expect(supportsBackups(instance: "two"))
        #expect(supportsBackups(module: "Core", instance: "one"))

        respond(with: [])
        _ = try await client.getBackups("one")
        #expect(supportsBackups(instance: "one"))
    }

    @Test func missingFilesAndConfigurationDoNotMarkAPIMethodsUnsupported() async {
        respond(with: ["Title": "Missing configuration", "Message": "File not found"])
        let error = await ampError { _ = try await client.getFiles("mc") }
        #expect(error != nil)
        #expect(error?.isMethodUnavailable == false)
        #expect(
            client.isMethodSupported(
                "GetDirectoryListing", module: "FileManagerPlugin", instanceID: "mc"))
    }

    @Test func capabilityTrackingAlsoAppliesAfterASessionRetry() async {
        var count = 0
        respond = { _ in
            count += 1
            return count == 1
                ? .text("", status: 401)
                : .json(["Title": "Missing Method", "Message": "Missing method"])
        }
        let error = await ampError { _ = try await client.getTasks("mc") }
        #expect(error?.isMethodUnavailable == true)
        #expect(!client.isMethodSupported("GetScheduleData", instanceID: "mc"))
        #expect(requests.filter { $0.path.hasSuffix("/Core/Login") }.count == 2)
    }

    /// Six reads at once, against the ADS itself or one of its instances.
    @Test(arguments: [false, true])
    func parallelReadsShareOneLoginAndSession(throughInstance: Bool) async throws {
        let gate = Gate()
        var requests: [RecordedRequest] = []
        let client = makeClient { request in
            requests.append(request)
            if request.path.hasSuffix("/Core/Login") {
                await gate.wait()
                return .json(["success": true, "sessionID": "shared"])
            }
            return .json(throughInstance ? [:] : [])
        }
        let pending = (0..<6).map { _ in
            Task {
                if throughInstance {
                    _ = try await client.getUsers("mc")
                } else {
                    _ = try await client.getInstances()
                }
            }
        }
        await waitUntil("the login is in flight") { gate.waiters == 1 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(requests.count == 1)

        gate.open()
        for read in pending { try await read.value }
        #expect(requests.count == 7)
        #expect(requests.dropFirst().allSatisfy { $0.body["SESSIONID"] == "shared" })
    }

    @Test func gameUpdatesUseApplicationStateAndNeverCallAMPUpdateEndpoints() async throws {
        respond(with: ["State": 100])
        #expect(try await client.getUpdateStatus("mc").state == .updating)
        respond(with: ["Status": true])
        try await client.runUpdate("mc")
        #expect(requests.last?.method == "Core/UpdateApplication")
        #expect(
            !requests.contains {
                $0.path.hasSuffix("/GetUpdateInfo") || $0.path.hasSuffix("/UpdateAMPInstance")
            })
    }
}
