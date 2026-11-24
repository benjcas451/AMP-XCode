import Foundation
import Network

/// A small HTTP server on the loopback interface that plays the part of an
/// AMP panel, so that UI tests can drive the real app end to end.
///
/// It knows the user `admin` / `secret`, a running Minecraft instance with
/// two files that can be read and written, and a stopped Valheim instance.
final class MockAMPServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "MockAMPServer")

    // Only touched on `queue`.
    private var valheimRunning = false
    private var pendingConsole = [
        #"{"Timestamp":"/Date(1700000000000)/","Source":"Console","Type":"Console","Contents":"Done (3.2s)! For help, type help"}"#
    ]

    /// The contents of the Minecraft instance's files, by path.
    private var files: [String: Data] = [
        "server.properties": Data("motd=Welcome\nmax-players=20\n".utf8),
        "world/level.dat": Data(base64Encoded: MockAMPServer.levelDat) ?? Data(),
    ]

    /// A Java Edition level.dat (gzip): a root compound holding "Data" with
    /// LevelName "Survival", hardcore 0, GameType 0 and more.
    private static let levelDat =
        "H4sIAAAAAAAC/zVQO07DQBB9wd7ENqFDFIjCNReggxARRUERinAayhUewMLetdaOkalyADoqJCQ4AScIUaRchAuk" +
        "oaKK2Y1hpNF83nua0fMAD/YZz7kDd0gFxRc8ITjBRBVRweMGnDuuwmupCBacvgbHZUrQYaEZpPxBXOm+Y8MeR4nZ" +
        "H8xf9neb8LpShaSC6JFOn16PjIDBVTwSmyvHU2ALrYJUFklx/unATmQeYq+vlrPlG/mr99lq/uEvpn5PhOSiHZDS" +
        "7K7iIswc1GouojjmYClPSblgvSTNS3MKLbBumVNm/mysrW3YA5FvJp2NqqrWsJ+/2mBDKW7/9/jDqg2u+0P2DRfW" +
        "SGZNQzn5qTmdUV0XXl09uMaYy0lM+rWde6J0IAoSuVQl2A2PM2PMLzAFEcFrAQAA"

    private(set) var port: UInt16 = 0

    init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    /// Starts listening and returns once the port is known.
    func start() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.receive(on: connection, buffer: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 10) == .success, let port = listener.port else {
            throw NSError(
                domain: "MockAMPServer", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The mock AMP server did not start."])
        }
        self.port = port.rawValue
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - HTTP

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = Self.parseRequest(buffer) {
                let body = Data(self.respond(to: request.path, body: request.body).utf8)
                let head =
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                    + "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                connection.send(
                    content: Data(head.utf8) + body,
                    completion: .contentProcessed { _ in connection.cancel() })
            } else if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    /// Returns the request once headers and the announced body are complete.
    private static func parseRequest(_ data: Data) -> (path: String, body: [String: Any])? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<headerEnd.lowerBound], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.first?.components(separatedBy: " ") ?? []
        guard requestLine.count >= 2 else { return nil }
        var length = 0
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let bodyData = data[headerEnd.upperBound...]
        guard bodyData.count >= length else { return nil }
        let json = try? JSONSerialization.jsonObject(with: Data(bodyData.prefix(length)))
        return (requestLine[1], json as? [String: Any] ?? [:])
    }

    // MARK: - AMP

    /// The JSON text AMP would answer with.
    private func respond(to path: String, body: [String: Any]) -> String {
        let method = path.components(separatedBy: "/API/").last ?? path
        switch method {
        case "Core/GetModuleInfo":
            return #"{"Author":"CubeCoders Limited","AppName":"ADS"}"#
        case "Core/Login":
            if body["username"] as? String == "admin", body["password"] as? String == "secret" {
                return #"{"success":true,"sessionID":"ui-test-session"}"#
            }
            return #"{"success":false,"resultReason":"Bad credentials"}"#
        case "ADSModule/GetInstances":
            return """
                [{"AvailableInstances":[
                  {"InstanceID":"mc","InstanceName":"Minecraft01","FriendlyName":"Survival",
                   "Module":"Minecraft","ModuleDisplayName":"Minecraft Java Edition",
                   "Running":true,"AppState":20,"Metrics":\(metrics)},
                  {"InstanceID":"valheim","InstanceName":"Valheim01","FriendlyName":"Valheim",
                   "Module":"GenericModule","ModuleDisplayName":"Valheim",
                   "Running":\(valheimRunning),"AppState":0}
                ]}]
                """
        case "ADSModule/StartInstance", "ADSModule/StopInstance":
            if body["InstanceName"] as? String == "Valheim01" {
                valheimRunning = method.hasSuffix("StartInstance")
            }
            return #"{"Status":true}"#
        case "Core/GetUpdates":
            let console = pendingConsole.joined(separator: ",")
            pendingConsole = []
            return #"{"Status":\#(status),"ConsoleEntries":[\#(console)]}"#
        case "Core/GetStatus":
            return status
        case "Core/SendConsoleMessage":
            let message = Self.jsonString("[Server] \(body["message"] as? String ?? "")")
            pendingConsole.append(
                #"{"Timestamp":"/Date(1700000060000)/","Source":"Server","Type":"Console","Contents":\#(message)}"#
            )
            return "null"
        case "Core/GetUserList":
            return #"{"result":{"uuid-1":"Alex","uuid-2":"Steve"}}"#
        case "LocalFileBackupPlugin/GetBackups":
            return #"[{"Id":"b1","Name":"world-2024-06-01","Timestamp":"2024-06-01T12:00:00Z","TotalSizeBytes":20971520}]"#
        case "FileManagerPlugin/GetDirectoryListing":
            if body["Dir"] as? String == "world" {
                let size = files["world/level.dat"]?.count ?? 0
                return #"[{"Filename":"level.dat","IsDirectory":false,"SizeBytes":\#(size)}]"#
            }
            let size = files["server.properties"]?.count ?? 0
            return #"[{"Filename":"world","IsDirectory":true},{"Filename":"server.properties","IsDirectory":false,"SizeBytes":\#(size)}]"#
        case "FileManagerPlugin/GetFileChunk":
            guard let contents = files[body["Filename"] as? String ?? ""] else {
                return #"{"Status":false,"Reason":"File not found"}"#
            }
            let start = min(max(body["Position"] as? Int ?? 0, 0), contents.count)
            let end = min(start + max(body["Length"] as? Int ?? 0, 0), contents.count)
            let piece = contents.subdata(in: start..<end)
            return #"{"Result":{"Base64Data":"\#(piece.base64EncodedString())","BytesLength":\#(piece.count)},"Status":true}"#
        case "FileManagerPlugin/WriteFileChunk":
            let name = body["Filename"] as? String ?? ""
            let offset = body["Offset"] as? Int ?? 0
            let contents = files[name] ?? Data()
            guard offset <= contents.count,
                let data = Data(base64Encoded: body["Data"] as? String ?? "")
            else { return #"{"Status":false,"Reason":"Write failed"}"# }
            // Like a file opened for writing at an offset: the old end of a
            // longer file stays, which the app has to deal with.
            var updated = contents.subdata(in: 0..<offset) + data
            if contents.count > updated.count {
                updated += contents.subdata(in: updated.count..<contents.count)
            }
            files[name] = updated
            return #"{"Status":true}"#
        case "FileManagerPlugin/TrashFile":
            files[body["Filename"] as? String ?? ""] = nil
            return #"{"Status":true}"#
        case "Core/GetSettingsSpec":
            return """
                {"Minecraft":[
                  {"Node":"MinecraftModule.Minecraft.MaxPlayers","Name":"Max Players",
                   "CurrentValue":"20","ValType":"Integer","Description":"Maximum number of players"},
                  {"Node":"MinecraftModule.Minecraft.ServerMOTD","Name":"",
                   "CurrentValue":"Welcome","ValType":"String","ReadOnly":true}
                ]}
                """
        case "Core/GetScheduleData":
            return """
                {"PopulatedTriggers":[
                  {"Id":"t1","Description":"Nightly Backup","TriggerType":"TimeInterval","EnabledState":1,
                   "Tasks":[{"TaskMethodName":"LocalFileBackupPlugin.TakeBackup"}]}
                ]}
                """
        case "Core/GetAuditLogEntries":
            return #"[{"Message":"Backup completed","Timestamp":"/Date(1700000000000)/","Category":"Backup"}]"#
        default:
            return #"{"Status":true}"#
        }
    }

    private var status: String {
        #"{"State":20,"Uptime":"0:01:23:45","Metrics":\#(metrics)}"#
    }

    private let metrics = """
        {"CPU Usage":{"RawValue":12,"MaxValue":100,"Percent":12,"Units":"%"},
         "Memory Usage":{"RawValue":1536,"MaxValue":4096,"Percent":37.5,"Units":"MB"},
         "Active Users":{"RawValue":2,"MaxValue":20,"Percent":10,"Units":""}}
        """

    /// `text` as a JSON string literal.
    private static func jsonString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data("[\"\"]".utf8)
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}
