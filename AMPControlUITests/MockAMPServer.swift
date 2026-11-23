import Foundation
import Network

/// A small HTTP server on the loopback interface that plays the part of an
/// AMP panel, so that UI tests can drive the real app end to end.
///
/// It knows the user `admin` / `secret`, a running Minecraft instance and a
/// stopped Valheim instance.
final class MockAMPServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "MockAMPServer")

    // Only touched on `queue`.
    private var valheimRunning = false
    private var pendingConsole = [
        #"{"Timestamp":"/Date(1700000000000)/","Source":"Console","Type":"Console","Contents":"Done (3.2s)! For help, type help"}"#
    ]

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
                   "Running":true,"AppState":40,"Metrics":\(metrics)},
                  {"InstanceID":"valheim","InstanceName":"Valheim01","FriendlyName":"Valheim",
                   "Module":"GenericModule","ModuleDisplayName":"Valheim",
                   "Running":\(valheimRunning),"AppState":10}
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
                return #"[{"Filename":"level.dat","IsDirectory":false,"SizeBytes":2048}]"#
            }
            return #"[{"Filename":"world","IsDirectory":true},{"Filename":"server.properties","IsDirectory":false,"SizeBytes":1280}]"#
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
        #"{"State":40,"Uptime":"0:01:23:45","Metrics":\#(metrics)}"#
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
