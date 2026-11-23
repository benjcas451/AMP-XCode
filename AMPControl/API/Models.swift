import Foundation

/// Thrown while reading a response whose shape does not match what AMP is
/// expected to send. The client reports it as "Ungültige Antwort".
struct InvalidResponse: Error {}

/// AMP application states (`ApplicationState` enum in AMP).
enum ApplicationState: Int, CaseIterable, Sendable {
    case undefined = 0
    case stopped = 10
    case preStart = 20
    case configuring = 30
    case starting = 35
    case ready = 40
    case restarting = 45
    case stopping = 50
    case preparingForSleep = 60
    case sleeping = 70
    case waiting = 80
    case installing = 90
    case updating = 100
    case awaitingUserInput = 200
    case failed = 999

    /// Unknown or missing codes map to `.undefined`.
    init(code: JSONValue?) {
        self = ApplicationState(rawValue: code?.lenientInt ?? 0) ?? .undefined
    }

    var label: String {
        switch self {
        case .undefined: "Unbekannt"
        case .stopped: "Gestoppt"
        case .preStart, .starting: "Startet"
        case .configuring: "Konfiguriert"
        case .ready: "Läuft"
        case .restarting: "Neustart"
        case .stopping: "Stoppt"
        case .preparingForSleep: "Schlafvorbereitung"
        case .sleeping: "Schläft"
        case .waiting: "Wartet"
        case .installing: "Installiert"
        case .updating: "Aktualisiert"
        case .awaitingUserInput: "Wartet auf Eingabe"
        case .failed: "Fehler"
        }
    }

    var isRunning: Bool { self == .ready }
    var isStopped: Bool { self == .stopped || self == .failed || self == .undefined }
    var isBusy: Bool { !isRunning && !isStopped && self != .sleeping }
}

struct Metric: Hashable, Sendable, Identifiable {
    let name: String
    let raw: Double
    let max: Double
    let percent: Double
    let units: String

    var id: String { name }

    init(name: String, json: JSONObject) throws {
        self.name = name
        raw = try Self.number(json["RawValue"])
        max = try Self.number(json["MaxValue"])
        percent = try Self.number(json["Percent"])
        units = json.text("Units") ?? ""
    }

    private static func number(_ value: JSONValue?) throws -> Double {
        switch value {
        case nil, .null: return 0
        case .int(let number): return Double(number)
        case .double(let number): return number
        default: throw InvalidResponse()
        }
    }

    var label: String {
        switch name {
        case "CPU Usage": "CPU"
        case "Memory Usage": "RAM"
        case "Active Users": "Spieler"
        default: name
        }
    }

    var valueText: String {
        let value = Self.format(raw)
        if units == "%" { return "\(value) %" }
        if max > 0 {
            return "\(value) / \(Self.format(max)) \(units)".trimmingCharacters(in: .whitespaces)
        }
        return "\(value) \(units)".trimmingCharacters(in: .whitespaces)
    }

    var fraction: Double { Swift.min(Swift.max(percent / 100, 0), 1) }

    private static func format(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 { return String(Int(value)) }
        return String(value)
    }

    /// Reads AMP's `Metrics` object. JSON objects carry no order here, so the
    /// well-known metrics come first, in the order AMP shows them.
    static func list(from value: JSONValue?) throws -> [Metric] {
        guard let object = value?.objectValue else { return [] }
        let known = ["CPU Usage", "Memory Usage", "Active Users"]
        return try object
            .compactMap { name, entry in
                try entry.objectValue.map { try Metric(name: name, json: $0) }
            }
            .sorted { a, b in
                let ia = known.firstIndex(of: a.name) ?? known.count
                let ib = known.firstIndex(of: b.name) ?? known.count
                return ia != ib ? ia < ib : a.name < b.name
            }
    }
}

extension Array where Element == Metric {
    subscript(name: String) -> Metric? { first { $0.name == name } }
}

struct AMPInstance: Hashable, Sendable, Identifiable {
    let id: String
    let instanceName: String
    let friendlyName: String
    let module: String
    let moduleDisplayName: String

    /// Whether the AMP instance process runs (required for any instance call).
    let running: Bool
    let appState: ApplicationState
    let metrics: [Metric]

    init(json: JSONObject) throws {
        id = json.text("InstanceID") ?? ""
        instanceName = json.text("InstanceName") ?? ""
        friendlyName = json.text("FriendlyName") ?? ""
        module = json.text("Module") ?? ""
        moduleDisplayName = json.text("ModuleDisplayName") ?? ""
        running = json["Running"] == .bool(true)
        appState = ApplicationState(code: json["AppState"])
        metrics = try Metric.list(from: json["Metrics"])
    }

    var displayName: String { friendlyName.isEmpty ? instanceName : friendlyName }
    var subtitle: String { moduleDisplayName.isEmpty ? module : moduleDisplayName }
}

struct InstanceStatus: Hashable, Sendable {
    let state: ApplicationState
    let uptime: String
    let metrics: [Metric]

    init(json: JSONObject) throws {
        state = ApplicationState(code: json["State"])
        uptime = json.text("Uptime") ?? ""
        metrics = try Metric.list(from: json["Metrics"])
    }
}

struct SettingEntry: Hashable, Sendable, Identifiable {
    let name: String

    /// AMP identifies settings by their `Node`
    /// (`MinecraftModule.Minecraft.AcceptsTransfers`). Many settings carry no
    /// display `Name`, so the node is the only thing that tells them apart.
    let node: String
    let readOnly: Bool
    let value: String
    let type: String
    let description: String

    var id: String { node }

    /// `key` is used when the response has no `Node`.
    init(json: JSONObject, key: String = "") {
        let name = (json.text("Name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let node = (json.text("Node") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = name
        self.node = !node.isEmpty ? node : (!key.isEmpty ? key : name)
        readOnly = json["ReadOnly"] == .bool(true)
        value = (json["CurrentValue"] != nil ? json.text("CurrentValue") : json.text("Value")) ?? ""
        type = json.text("ValType") ?? json.text("Type") ?? ""
        description = json.text("Description") ?? ""
    }

    /// Identifier sent to `SetConfig`; same as `node`.
    var key: String { node }

    /// Human readable title: the AMP display name, or one derived from `key`
    /// (`MinecraftModule.Minecraft.AcceptsTransfers` → `Accepts Transfers`).
    var displayName: String {
        if !name.isEmpty { return name }
        let last = key.split(whereSeparator: { ".:/".contains($0) }).last.map(String.init) ?? key
        let characters = Array(last.replacingOccurrences(of: "_", with: " "))
        var words = ""
        for (index, character) in characters.enumerated() {
            if index > 0, character.isASCIIUppercase {
                let previous = characters[index - 1]
                let next = index + 1 < characters.count ? characters[index + 1] : nil
                let endsLowerRun = previous.isASCIILowercase || previous.isASCIIDigit
                let startsNewWord = previous.isASCIIUppercase && next?.isASCIILowercase == true
                if endsLowerRun || startsNewWord { words.append(" ") }
            }
            words.append(character)
        }
        words = words.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? "Unbenannte Einstellung" : words
    }
}

private extension Character {
    var isASCIIUppercase: Bool { ("A"..."Z").contains(self) }
    var isASCIILowercase: Bool { ("a"..."z").contains(self) }
    var isASCIIDigit: Bool { ("0"..."9").contains(self) }
}

struct SchedulerTask: Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let description: String
    let trigger: String
    let enabled: Bool

    init(json: JSONObject) throws {
        id = json.text("Id") ?? json.text("TaskID") ?? ""
        name = json.text("Name") ?? json.text("Description") ?? ""
        if let tasks = json["Tasks"]?.arrayValue {
            description = try tasks
                .map { entry -> String in
                    guard let task = entry.objectValue else { throw InvalidResponse() }
                    return task.text("TaskMethodName") ?? ""
                }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        } else {
            description = json.text("Description") ?? ""
        }
        trigger = json.text("TriggerType") ?? json.text("Trigger")
            ?? json.text("TriggerDescription") ?? ""
        if let state = json["EnabledState"] {
            enabled = (state.lenientInt ?? 0) != 0
        } else {
            enabled = json["Enabled"] == .bool(true)
        }
    }
}

struct AMPEvent: Hashable, Sendable {
    let message: String
    let timestamp: Date?
    let severity: String

    init(json: JSONObject) {
        message = json.text("Message") ?? ""
        timestamp = AMPDate.parse(
            json.value("Timestamp") ?? json.value("Time") ?? json.value("DateTime")
        )
        severity = json.text("Severity") ?? json.text("Level") ?? json.text("Category") ?? "Info"
    }
}

struct ConsoleEntry: Hashable, Sendable {
    let timestamp: Date?
    let source: String
    let type: String
    let contents: String

    init(json: JSONObject) {
        timestamp = AMPDate.parse(json["Timestamp"])
        source = json.text("Source") ?? ""
        type = json.text("Type") ?? ""
        contents = json.text("Contents") ?? ""
    }
}

struct BackupEntry: Hashable, Sendable, Identifiable {
    let id: String
    let name: String
    let createdAt: String?
    let sizeBytes: Int

    init(json: JSONObject) {
        id = json.text("Id") ?? ""
        name = json.text("BackupName") ?? json.text("Name") ?? ""
        createdAt = json.text("Timestamp") ?? json.text("Created") ?? json.text("CreatedAt")
        sizeBytes = ByteSize.parse(json.value("TotalSizeBytes") ?? json.value("Size"))
    }

    var sizeLabel: String { ByteSize.label(sizeBytes) }
}

struct FileEntry: Hashable, Sendable, Identifiable {
    let name: String
    let path: String
    let isDirectory: Bool
    let sizeBytes: Int
    let modifiedAt: Date?

    var id: String { path }

    init(json: JSONObject) {
        name = json.text("Filename") ?? json.text("Name") ?? ""
        path = json.text("Path") ?? json.text("Filename") ?? ""
        let flags = [json["IsDirectory"], json["IsFolder"]]
        isDirectory = flags.contains { $0 == .bool(true) || $0 == .string("true") }
            || json.text("Type")?.lowercased() == "directory"
        sizeBytes = ByteSize.parse(json.value("SizeBytes") ?? json.value("Size"))
        modifiedAt = AMPDate.parse(
            json.value("Modified") ?? json.value("ModifiedAt")
                ?? json.value("LastModified") ?? json.value("LastWriteTime")
        )
    }

    var sizeLabel: String { ByteSize.label(sizeBytes) }
}

struct InstanceUpdates: Hashable, Sendable {
    let status: InstanceStatus?
    let console: [ConsoleEntry]

    init(json: JSONObject) throws {
        status = try json["Status"]?.objectValue.map { try InstanceStatus(json: $0) }
        console = try (json["ConsoleEntries"]?.arrayValue ?? []).map { entry in
            guard let object = entry.objectValue else { throw InvalidResponse() }
            return ConsoleEntry(json: object)
        }
    }
}

enum ByteSize {
    /// Sizes arrive as numbers or numeric strings; anything else counts as 0.
    static func parse(_ value: JSONValue?) -> Int {
        switch value {
        case .int(let number): return number
        case .double(let number): return truncate(number)
        case .string(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let number = Int(trimmed) { return number }
            if let number = Double(trimmed) { return truncate(number) }
            return 0
        default: return 0
        }
    }

    private static func truncate(_ value: Double) -> Int {
        Int(exactly: value.rounded(.towardZero)) ?? 0
    }

    static func label(_ bytes: Int) -> String {
        if bytes <= 0 { return "" }
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        return String(format: "%.1f MB", kb / 1024)
    }
}

enum AMPDate {
    /// AMP sends dates either as ISO strings or as "/Date(1700000000000)/".
    static func parse(_ value: JSONValue?) -> Date? {
        guard let text = value?.text else { return nil }
        if let marker = text.range(of: "/Date(") {
            let digits = text[marker.upperBound...].prefix { $0 == "-" || $0.isNumber }
            if let milliseconds = Int(digits) {
                return Date(timeIntervalSince1970: Double(milliseconds) / 1000)
            }
        }
        return parseISO(text)
    }

    /// ISO 8601 with a `T` or space separator, optional time, fraction and
    /// zone. Without a zone the time is local, as AMP means it.
    private static func parseISO(_ text: String) -> Date? {
        let pattern = #"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d+))?)?)?\s*(Z|z|[+-]\d{2}(?::?\d{2})?)?$"#
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(
                in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
        else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: trimmed).map { String(trimmed[$0]) }
        }

        var calendar = Calendar(identifier: .gregorian)
        if let zone = group(8) {
            guard let timeZone = timeZone(zone) else { return nil }
            calendar.timeZone = timeZone
        } else {
            calendar.timeZone = .current
        }
        var components = DateComponents()
        components.year = group(1).flatMap(Int.init)
        components.month = group(2).flatMap(Int.init)
        components.day = group(3).flatMap(Int.init)
        components.hour = group(4).flatMap(Int.init) ?? 0
        components.minute = group(5).flatMap(Int.init) ?? 0
        components.second = group(6).flatMap(Int.init) ?? 0
        guard let date = calendar.date(from: components) else { return nil }
        let fraction = group(7).flatMap { Double("0." + $0) } ?? 0
        return date.addingTimeInterval(fraction)
    }

    private static func timeZone(_ text: String) -> TimeZone? {
        if text == "Z" || text == "z" { return TimeZone(secondsFromGMT: 0) }
        let digits = text.dropFirst().filter(\.isNumber)
        guard let hours = Int(digits.prefix(2)) else { return nil }
        let minutes = Int(digits.dropFirst(2)) ?? 0
        let seconds = hours * 3600 + minutes * 60
        return TimeZone(secondsFromGMT: text.hasPrefix("-") ? -seconds : seconds)
    }

    /// Local wall-clock time as `HH:mm:ss`.
    static func clockTime(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(
            format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }
}
