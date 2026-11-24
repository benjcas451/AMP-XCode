import Foundation

struct AMPError: Error, Equatable, LocalizedError {
    let message: String

    /// Set when AMP reported that the called API method does not exist.
    var unavailableMethod: MethodReference?

    struct MethodReference: Equatable, Sendable {
        let module: String
        let method: String
    }

    init(_ message: String) {
        self.message = message
    }

    static func methodUnavailable(module: String, method: String) -> AMPError {
        var error = AMPError(
            "API-Methode „\(method)“ nicht gefunden (Modul \(module)). "
                + "Diese Funktion wird von dieser AMP-Installation nicht bereitgestellt."
        )
        error.unavailableMethod = MethodReference(module: module, method: method)
        return error
    }

    var isMethodUnavailable: Bool { unavailableMethod != nil }
    var errorDescription: String? { message }
}

/// Low-level client for the AMP JSON API.
///
/// All calls are `POST <baseURL>/API/<Module>/<Method>` with a JSON body that
/// contains the parameters plus `SESSIONID`. Instances managed by the ADS are
/// reached through the ADS proxy: `/API/ADSModule/Servers/<id>/API/...`, each
/// with its own session.
@MainActor
final class AMPClient {
    let baseURL: String
    let username: String
    let password: String
    private let transport: any HTTPTransport

    private var adsSession: String?
    private var instanceSessions: [String: String] = [:]
    private var adsLogin: Task<String, Error>?
    private var instanceLogins: [String: Task<String, Error>] = [:]

    /// API methods this AMP installation lacks, found out when a call fails
    /// with a "missing method" error.
    private var unsupportedMethods: Set<String> = []

    init(
        baseURL: String,
        username: String,
        password: String,
        transport: any HTTPTransport = URLSessionTransport()
    ) {
        self.baseURL = Self.normalizeURL(baseURL)
        self.username = username
        self.password = password
        self.transport = transport
    }

    nonisolated static func normalizeURL(_ url: String) -> String {
        var result = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isEmpty { return result }
        if !result.hasPrefix("http://") && !result.hasPrefix("https://") {
            result = "http://" + result
        }
        while result.hasSuffix("/") {
            result.removeLast()
        }
        return result
    }

    func close() {
        transport.close()
    }

    // MARK: - Capabilities

    private func methodKey(_ module: String, _ method: String, _ instanceID: String?) -> String {
        "\(instanceID ?? "ADS"):\(module)/\(method)"
    }

    /// Methods count as supported until AMP says otherwise.
    func isMethodSupported(_ method: String, module: String = "Core", instanceID: String? = nil)
        -> Bool
    {
        !unsupportedMethods.contains(methodKey(module, method, instanceID))
    }

    func markMethodUnsupported(
        _ method: String, module: String = "Core", instanceID: String? = nil
    ) {
        unsupportedMethods.insert(methodKey(module, method, instanceID))
    }

    func markMethodSupported(_ method: String, module: String = "Core", instanceID: String? = nil) {
        unsupportedMethods.remove(methodKey(module, method, instanceID))
    }

    // MARK: - Transport

    private struct Unauthorized: Error {}

    /// Runs off the main actor: only touches the immutable connection data.
    private nonisolated func post(
        _ module: String,
        _ method: String,
        _ params: JSONObject,
        instanceID: String? = nil,
        session: String? = nil
    ) async throws -> JSONValue {
        let prefix = instanceID.map { "/API/ADSModule/Servers/\($0)" } ?? ""
        guard let url = URL(string: "\(baseURL)\(prefix)/API/\(module)/\(method)") else {
            throw AMPError("Verbindung fehlgeschlagen: ungültige Server-URL.")
        }
        var body = params
        if let session { body["SESSIONID"] = .string(session) }

        let response: HTTPResponse
        do {
            response = try await transport.post(url, body: JSONEncoder().encode(body))
        } catch TransportError.timedOut {
            throw AMPError("Zeitüberschreitung – Server nicht erreichbar.")
        } catch TransportError.failed(let reason) {
            throw AMPError("Verbindung fehlgeschlagen: \(reason)")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AMPError("Verbindung fehlgeschlagen: \(error.localizedDescription)")
        }

        let status = response.statusCode
        let httpError = AMPError("HTTP \(status) bei \(module)/\(method)")
        if status == 401 || status == 403 { throw Unauthorized() }
        if response.body.isEmpty && status == 200 { return .null }

        let decoded: JSONValue
        do {
            decoded = try JSONDecoder().decode(JSONValue.self, from: response.body)
        } catch {
            if status != 200 { throw httpError }
            throw AMPError("Ungültige Antwort vom Server (kein JSON).")
        }

        if let object = decoded.objectValue {
            let title = object.text("Title") ?? ""
            let message = object.text("Message") ?? ""
            let lowerTitle = title.lowercased()
            if lowerTitle.contains("unauthori") { throw Unauthorized() }
            if lowerTitle.contains("missingmethod") || lowerTitle.contains("methodnotfound")
                || "\(title) \(message)".range(
                    of: #"missing\s+method|method\b.*\bnot found"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
            {
                throw AMPError.methodUnavailable(module: module, method: method)
            }
            if object["Title"] != nil && (object["StackTrace"] != nil || object["Message"] != nil) {
                throw AMPError("\(title): \(message)".trimmingCharacters(in: .whitespacesAndNewlines))
            }
            // Non-object return values are wrapped as {"result": ...}.
            if object.count == 1, let result = object["result"] {
                if status != 200 { throw httpError }
                return result
            }
        }
        if status != 200 { throw httpError }
        return decoded
    }

    // MARK: - Authentication

    private func login(instanceID: String? = nil) async throws -> String {
        func attempt(password: String, token: String) async throws -> JSONObject? {
            try await post(
                "Core", "Login",
                [
                    "username": .string(username),
                    "password": .string(password),
                    "token": .string(token),
                    "rememberMe": false,
                ],
                instanceID: instanceID
            ).objectValue
        }

        var result = try await attempt(password: password, token: "")
        // Instances behind the ADS also accept the ADS session as SSO token.
        if result?["success"] != .bool(true), instanceID != nil {
            let ads = try await adsSessionID()
            result = try await attempt(password: "", token: ads)
        }

        guard let result, result["success"] == .bool(true) else {
            let reason = result?.text("resultReason") ?? ""
            throw AMPError(
                reason.isEmpty
                    ? "Anmeldung fehlgeschlagen. Benutzer oder Passwort falsch?"
                    : "Anmeldung fehlgeschlagen: \(reason)"
            )
        }
        guard let sessionID = result.text("sessionID"), !sessionID.isEmpty else {
            throw AMPError("Anmeldung fehlgeschlagen: keine Session erhalten.")
        }
        return sessionID
    }

    /// Concurrent callers share one login instead of each starting their own.
    private func adsSessionID() async throws -> String {
        if let adsSession { return adsSession }
        let login = adsLogin ?? Task { try await self.login() }
        adsLogin = login
        defer { if adsLogin == login { adsLogin = nil } }
        let sessionID = try await login.value
        if adsLogin == login { adsSession = sessionID }
        return sessionID
    }

    private func instanceSessionID(_ id: String) async throws -> String {
        if let session = instanceSessions[id] { return session }
        let login = instanceLogins[id] ?? Task { try await self.login(instanceID: id) }
        instanceLogins[id] = login
        defer { if instanceLogins[id] == login { instanceLogins[id] = nil } }
        let sessionID = try await login.value
        if instanceLogins[id] == login { instanceSessions[id] = sessionID }
        return sessionID
    }

    private func forgetInstanceSession(_ id: String) {
        instanceSessions[id] = nil
        instanceLogins[id] = nil
    }

    private func forgetAllSessions() {
        adsSession = nil
        adsLogin = nil
        instanceSessions.removeAll()
        instanceLogins.removeAll()
    }

    /// Performs an authenticated call, logging in again once if the session
    /// has expired.
    @discardableResult
    func call(
        _ module: String,
        _ method: String,
        _ params: JSONObject = [:],
        instanceID: String? = nil
    ) async throws -> JSONValue {
        func send() async throws -> JSONValue {
            let session: String
            if let instanceID {
                session = try await instanceSessionID(instanceID)
            } else {
                session = try await adsSessionID()
            }
            return try await post(module, method, params, instanceID: instanceID, session: session)
        }

        do {
            let result: JSONValue
            do {
                result = try await send()
            } catch is Unauthorized {
                if let instanceID {
                    forgetInstanceSession(instanceID)
                } else {
                    forgetAllSessions()
                }
                do {
                    result = try await send()
                } catch is Unauthorized {
                    throw AMPError("Keine Berechtigung für \(module)/\(method).")
                }
            }
            markMethodSupported(method, module: module, instanceID: instanceID)
            return result
        } catch let error as AMPError {
            if error.unavailableMethod == AMPError.MethodReference(module: module, method: method) {
                markMethodUnsupported(method, module: module, instanceID: instanceID)
            }
            throw error
        }
    }

    /// Verifies URL and credentials. Returns the application name on success.
    func testConnection() async throws -> String {
        let info: JSONValue
        do {
            info = try await post("Core", "GetModuleInfo", [:])
        } catch is Unauthorized {
            throw AMPError("Keine Berechtigung für Core/GetModuleInfo.")
        }
        guard let module = info.objectValue, module["Author"] == "CubeCoders Limited" else {
            throw AMPError("Unter dieser URL läuft kein AMP-Panel.")
        }
        adsSession = nil
        adsLogin = nil
        do {
            _ = try await adsSessionID()
        } catch is Unauthorized {
            throw AMPError("Keine Berechtigung für Core/Login.")
        }
        return module.text("AppName") ?? "AMP"
    }

    func logout() async {
        let session = adsSession
        forgetAllSessions()
        unsupportedMethods.removeAll()
        if let session {
            _ = try? await post("Core", "Logout", [:], session: session)
        }
    }

    // MARK: - ADS (controller)

    func getInstances() async throws -> [AMPInstance] {
        let response = try await call("ADSModule", "GetInstances")
        return try read("ADSModule/GetInstances", response) { value in
            var instances: [AMPInstance] = []
            for target in try list(value) {
                guard let available = try object(target)["AvailableInstances"] else {
                    throw InvalidResponse()
                }
                if available.isNull { continue }  // An offline ADS target has no instances.
                for entry in try list(available) {
                    let data = try object(entry)
                    try requireString(data, "InstanceID")
                    let instance = try AMPInstance(json: data)
                    if instance.module == "ADS" { continue }  // Skip the ADS itself.
                    instances.append(instance)
                }
            }
            return instances.sorted {
                ($0.displayName.lowercased(), $0.id) < ($1.displayName.lowercased(), $1.id)
            }
        }
    }

    /// Starts the AMP instance process itself (not the game server).
    func startInstanceProcess(_ instance: AMPInstance) async throws {
        try await action("ADSModule", "StartInstance", ["InstanceName": .string(instance.instanceName)])
        forgetInstanceSession(instance.id)
    }

    /// Stops the AMP instance process itself via the ADS controller.
    func stopInstanceProcess(_ instance: AMPInstance) async throws {
        try await action("ADSModule", "StopInstance", ["InstanceName": .string(instance.instanceName)])
        forgetInstanceSession(instance.id)
    }

    // MARK: - Instance (game server)

    func getStatus(_ id: String) async throws -> InstanceStatus {
        let response = try await call("Core", "GetStatus", instanceID: id)
        return try read("Core/GetStatus", response) { try status($0) }
    }

    func startServer(_ id: String) async throws {
        try await action("Core", "Start", instanceID: id)
    }

    func stopServer(_ id: String) async throws {
        try await action("Core", "Stop", instanceID: id)
    }

    func restartServer(_ id: String) async throws {
        try await action("Core", "Restart", instanceID: id)
    }

    func killServer(_ id: String) async throws {
        try await action("Core", "Kill", instanceID: id)
    }

    func sendConsole(_ id: String, _ message: String) async throws {
        try await call("Core", "SendConsoleMessage", ["message": .string(message)], instanceID: id)
    }

    /// Status plus console lines since the last call (per session).
    func getUpdates(_ id: String) async throws -> InstanceUpdates {
        let response = try await call("Core", "GetUpdates", instanceID: id)
        return try read("Core/GetUpdates", response) { value in
            let data = try object(value)
            if data["Status"] == nil && data["ConsoleEntries"] == nil { throw InvalidResponse() }
            if let current = data.value("Status") { _ = try status(current) }
            if let entries = data.value("ConsoleEntries") { _ = try list(entries) }
            return try InstanceUpdates(json: data)
        }
    }

    func getUsers(_ id: String) async throws -> [String] {
        let response = try await call("Core", "GetUserList", instanceID: id)
        return try read("Core/GetUserList", response) { value in
            let users = try value.objectValue.map { Array($0.values) } ?? list(value)
            return try users.map { user -> String in
                guard let name = user.stringValue else { throw InvalidResponse() }
                return name
            }.sorted()
        }
    }

    // MARK: Backups

    func getBackups(_ id: String) async throws -> [BackupEntry] {
        let response = try await call("LocalFileBackupPlugin", "GetBackups", instanceID: id)
        return try read("LocalFileBackupPlugin/GetBackups", response) { value in
            try list(value["Backups"] ?? value).map { entry in
                let data = try object(entry)
                try requireString(data, "Id")
                return BackupEntry(json: data)
            }
        }
    }

    func createBackup(_ id: String, name: String) async throws {
        let title = try nonEmpty(name, or: "Backup-Name darf nicht leer sein.")
        try await action(
            "LocalFileBackupPlugin", "TakeBackup",
            ["Title": .string(title), "Description": "", "Sticky": false],
            instanceID: id)
    }

    func restoreBackup(_ id: String, backupID: String) async throws {
        let backupID = try nonEmpty(backupID, or: "Backup-ID darf nicht leer sein.")
        try await action(
            "LocalFileBackupPlugin", "RestoreBackup", ["BackupId": .string(backupID)],
            instanceID: id)
    }

    func deleteBackup(_ id: String, backupID: String) async throws {
        let backupID = try nonEmpty(backupID, or: "Backup-ID darf nicht leer sein.")
        try await action(
            "LocalFileBackupPlugin", "DeleteLocalBackup", ["BackupId": .string(backupID)],
            instanceID: id)
    }

    // MARK: Files

    func getFiles(_ id: String, directory: String = "") async throws -> [FileEntry] {
        let response = try await call(
            "FileManagerPlugin", "GetDirectoryListing", ["Dir": .string(directory)], instanceID: id)
        return try read("FileManagerPlugin/GetDirectoryListing", response) { value in
            var parent = directory
            while parent.hasSuffix("/") {
                parent.removeLast()
            }
            return try list(value).map { entry in
                var data = try object(entry)
                let filename = try requireString(data, "Filename")
                data["Path"] = .string(directory.isEmpty ? filename : "\(parent)/\(filename)")
                return FileEntry(json: data)
            }
        }
    }

    func createDirectory(_ id: String, path: String) async throws {
        let path = try nonEmpty(path, or: "Pfad darf nicht leer sein.")
        try await action(
            "FileManagerPlugin", "CreateDirectory", ["NewPath": .string(path)], instanceID: id)
    }

    /// Moves a file or directory to AMP's trash.
    func deleteFile(_ id: String, path: String, isDirectory: Bool = false) async throws {
        let path = try nonEmpty(path, or: "Pfad darf nicht leer sein.")
        try await action(
            "FileManagerPlugin",
            isDirectory ? "TrashDirectory" : "TrashFile",
            [(isDirectory ? "DirectoryName" : "Filename"): .string(path)],
            instanceID: id)
    }

    func renameFile(_ id: String, path: String, newName: String, isDirectory: Bool = false)
        async throws
    {
        let oldPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let newName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if oldPath.isEmpty || newName.isEmpty {
            throw AMPError("Umbenennen benötigt gültige Dateinamen.")
        }
        try await action(
            "FileManagerPlugin",
            isDirectory ? "RenameDirectory" : "RenameFile",
            [
                (isDirectory ? "oldDirectory" : "Filename"): .string(oldPath),
                (isDirectory ? "NewDirectoryName" : "NewFilename"): .string(newName),
            ],
            instanceID: id)
    }

    // MARK: File contents

    /// File contents travel Base64-encoded in pieces of this many bytes.
    static let fileChunkSize = 256 * 1024
    /// Larger files are not loaded for editing.
    static let maxEditableFileSize = 8 * 1024 * 1024
    static let fileTooLarge = AMPError(
        "Die Datei ist zu groß, um sie in der App zu bearbeiten (maximal 8 MB).")

    /// Downloads a file.
    func readFile(_ id: String, path: String) async throws -> Data {
        let path = try nonEmpty(path, or: "Pfad darf nicht leer sein.")
        var data = Data()
        while true {
            let chunk = try await readFileChunk(
                id, path: path, position: data.count, length: Self.fileChunkSize)
            // Read up to an empty piece rather than a short one: a server
            // that hands out smaller pieces than asked for is not at the end.
            if chunk.isEmpty { break }
            data.append(chunk)
            if data.count > Self.maxEditableFileSize { throw Self.fileTooLarge }
        }
        return data
    }

    private func readFileChunk(_ id: String, path: String, position: Int, length: Int)
        async throws -> Data
    {
        let plugin = "FileManagerPlugin"
        var method = "GetFileChunk"
        var response: JSONValue?
        if isMethodSupported(method, module: plugin, instanceID: id) {
            do {
                response = try await call(
                    plugin, method,
                    ["Filename": .string(path), "Position": .int(position), "Length": .int(length)],
                    instanceID: id)
            } catch let error as AMPError where error.isMethodUnavailable {
                // Fall through to the method newer AMP versions offer instead.
            }
        }
        if response == nil {
            method = "ReadFileChunk"
            response = try await call(
                plugin, method,
                ["Filename": .string(path), "Offset": .int(position), "ChunkSize": .int(length)],
                instanceID: id)
        }
        return try read("\(plugin)/\(method)", response ?? .null) { value in
            // Either the piece itself or wrapped in an action result.
            let result = value["Result"] ?? value["result"] ?? value
            if result.isNull { return Data() }
            guard let encoded = result["Base64Data"]?.stringValue ?? result.stringValue,
                let data = Data(base64Encoded: encoded)
            else { throw InvalidResponse() }
            return data
        }
    }

    private func writeFileChunk(
        _ id: String, path: String, chunk: Data, offset: Int, isFinal: Bool
    ) async throws {
        try await action(
            "FileManagerPlugin", "WriteFileChunk",
            [
                "Filename": .string(path),
                "Data": .string(chunk.base64EncodedString()),
                "Offset": .int(offset),
                "FinalChunk": .bool(isFinal),
            ],
            instanceID: id)
    }

    private func writeFileChunks(_ id: String, path: String, data: Data) async throws {
        var offset = 0
        repeat {
            let end = min(offset + Self.fileChunkSize, data.count)
            let chunk = data.subdata(in: (data.startIndex + offset)..<(data.startIndex + end))
            try await writeFileChunk(
                id, path: path, chunk: chunk, offset: offset, isFinal: end == data.count)
            offset = end
        } while offset < data.count
    }

    /// Uploads the local file at `source` to `path` and returns its size.
    ///
    /// The file is read and sent piece by piece, so its size is not limited
    /// by memory. Writing starts at the beginning of `path` and does not cut
    /// off a longer file already there: upload to a free path.
    @discardableResult
    func uploadFile(
        _ id: String,
        path: String,
        from source: URL,
        progress: @MainActor (_ sent: Int, _ total: Int) -> Void = { _, _ in }
    ) async throws -> Int {
        let path = try nonEmpty(path, or: "Pfad darf nicht leer sein.")
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let total = Int(try handle.seekToEnd())
        try handle.seek(toOffset: 0)

        var offset = 0
        var isFinal = false
        progress(0, total)
        repeat {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: Self.fileChunkSize) ?? Data()
            // An empty piece ends the upload even if the file has shrunk
            // since its size was read.
            isFinal = chunk.isEmpty || offset + chunk.count >= total
            try await writeFileChunk(
                id, path: path, chunk: chunk, offset: offset, isFinal: isFinal)
            offset += chunk.count
            progress(offset, total)
        } while !isFinal
        return offset
    }

    /// Replaces the contents of a file and reads them back to make sure
    /// that the file now holds exactly `data`.
    func writeFile(_ id: String, path: String, data: Data) async throws {
        let path = try nonEmpty(path, or: "Pfad darf nicht leer sein.")
        if data.count > Self.maxEditableFileSize { throw Self.fileTooLarge }
        try await writeFileChunks(id, path: path, data: data)
        var stored = try await readFile(id, path: path)
        if stored.count > data.count, stored.prefix(data.count) == data {
            // Writing over a longer file left its old end in place. Start
            // from an empty file; the previous one stays in AMP's trash.
            try await deleteFile(id, path: path)
            try await writeFileChunks(id, path: path, data: data)
            stored = try await readFile(id, path: path)
        }
        guard stored == data else {
            throw AMPError(
                "Die Datei wurde nicht vollständig gespeichert. Bitte den Inhalt auf dem "
                    + "Server prüfen.")
        }
    }

    // MARK: Settings

    func getSettings(_ id: String) async throws -> [SettingEntry] {
        let response = try await call("Core", "GetSettingsSpec", instanceID: id)
        return try read("Core/GetSettingsSpec", response) { value in
            var settings: [SettingEntry] = []
            for category in try object(value).values {
                for entry in try list(category) {
                    let data = try object(entry)
                    try requireString(data, "Node")
                    settings.append(SettingEntry(json: data))
                }
            }
            return settings.sorted {
                ($0.displayName.lowercased(), $0.node) < ($1.displayName.lowercased(), $1.node)
            }
        }
    }

    func setSetting(_ id: String, node: String, value: String) async throws {
        let node = try nonEmpty(node, or: "Setting-Name darf nicht leer sein.")
        try await action(
            "Core", "SetConfig", ["node": .string(node), "value": .string(value)], instanceID: id)
    }

    // MARK: Schedule

    func getTasks(_ id: String) async throws -> [SchedulerTask] {
        let response = try await call("Core", "GetScheduleData", instanceID: id)
        return try read("Core/GetScheduleData", response) { value in
            guard let triggers = try object(value)["PopulatedTriggers"] else {
                throw InvalidResponse()
            }
            return try list(triggers).map { entry in
                let data = try object(entry)
                try requireString(data, "Id")
                return try SchedulerTask(json: data)
            }.sorted { ($0.name.lowercased(), $0.id) < ($1.name.lowercased(), $1.id) }
        }
    }

    func setTaskEnabled(_ id: String, taskID: String, enabled: Bool) async throws {
        let taskID = try nonEmpty(taskID, or: "Task-ID darf nicht leer sein.")
        try await action(
            "Core", "SetTriggerEnabled", ["Id": .string(taskID), "Enabled": .bool(enabled)],
            instanceID: id)
    }

    // MARK: Events

    /// The newest audit log entries, newest first; undated entries last.
    func getEvents(_ id: String) async throws -> [AMPEvent] {
        let response = try await call(
            "Core", "GetAuditLogEntries", ["Before": .null, "Count": 100], instanceID: id)
        return try read("Core/GetAuditLogEntries", response) { value in
            try list(value)
                .map { try AMPEvent(json: object($0)) }
                .enumerated()
                .sorted { a, b in
                    let ta = a.element.timestamp ?? .distantPast
                    let tb = b.element.timestamp ?? .distantPast
                    return ta != tb ? ta > tb : a.offset < b.offset
                }
                .map(\.element)
        }
    }

    // MARK: Game server update

    /// Application update progress is reflected in Core/GetStatus's State.
    /// Core/GetUpdateInfo describes AMP updates, not game server updates.
    func getUpdateStatus(_ id: String) async throws -> InstanceStatus {
        try await getStatus(id)
    }

    func runUpdate(_ id: String) async throws {
        try await action("Core", "UpdateApplication", instanceID: id)
    }

    // MARK: - Response helpers

    private nonisolated func isFailure(_ value: JSONValue) -> Bool {
        value == .bool(false) || value["Status"] == .bool(false)
    }

    private nonisolated func read<T>(_ method: String, _ value: JSONValue, _ parse: (JSONValue) throws -> T)
        throws -> T
    {
        if isFailure(value) {
            throw AMPError(value.objectValue?.text("Reason") ?? "Abruf von \(method) fehlgeschlagen.")
        }
        do {
            return try parse(value)
        } catch is InvalidResponse {
            throw AMPError("Ungültige Antwort bei \(method).")
        }
    }

    private nonisolated func object(_ value: JSONValue) throws -> JSONObject {
        guard let object = value.objectValue else { throw InvalidResponse() }
        return object
    }

    private nonisolated func list(_ value: JSONValue) throws -> [JSONValue] {
        guard let list = value.arrayValue else { throw InvalidResponse() }
        return list
    }

    private nonisolated func status(_ value: JSONValue) throws -> InstanceStatus {
        let data = try object(value)
        guard data["State"]?.lenientInt != nil else { throw InvalidResponse() }
        return try InstanceStatus(json: data)
    }

    @discardableResult
    private nonisolated func requireString(_ object: JSONObject, _ key: String) throws -> String {
        guard let value = object[key]?.stringValue, !value.isEmpty else { throw InvalidResponse() }
        return value
    }

    private nonisolated func nonEmpty(_ value: String, or message: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { throw AMPError(message) }
        return trimmed
    }

    private func action(
        _ module: String,
        _ method: String,
        _ params: JSONObject = [:],
        instanceID: String? = nil
    ) async throws {
        let result = try await call(module, method, params, instanceID: instanceID)
        if isFailure(result) {
            let reason = result.objectValue?.text("Reason") ?? ""
            throw AMPError(reason.isEmpty ? "\(method) fehlgeschlagen." : reason)
        }
    }
}
