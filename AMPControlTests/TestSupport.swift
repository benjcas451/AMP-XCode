import Foundation
import Testing

@testable import AMPControl

struct RecordedRequest: Sendable {
    let path: String
    let body: JSONObject

    /// `Module/Method` of the call, without host and ADS proxy prefix.
    var method: String { path.components(separatedBy: "/API/").last ?? path }
}

/// Stands in for the network: every POST is answered by `handler`, which runs
/// on the main actor like the tests themselves.
@MainActor
final class MockTransport: HTTPTransport {
    typealias Handler = @MainActor (RecordedRequest) async throws -> HTTPResponse

    private let handler: Handler

    init(_ handler: @escaping Handler) {
        self.handler = handler
    }

    func post(_ url: URL, body: Data) async throws -> HTTPResponse {
        let body = try JSONDecoder().decode(JSONObject.self, from: body)
        return try await handler(RecordedRequest(path: url.path, body: body))
    }

    nonisolated func close() {}
}

extension HTTPResponse {
    static func json(_ value: JSONValue, status: Int = 200) -> HTTPResponse {
        // Encoded by hand at the top level: fragments such as `null` or
        // `"text"` are valid responses too.
        HTTPResponse(statusCode: status, body: Data(value.jsonText.utf8))
    }

    static func text(_ text: String, status: Int) -> HTTPResponse {
        HTTPResponse(statusCode: status, body: Data(text.utf8))
    }
}

extension JSONValue {
    var jsonText: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .string:
            let data = (try? JSONEncoder().encode([self])) ?? Data("[\"\"]".utf8)
            return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
        case .array(let values):
            return "[" + values.map(\.jsonText).joined(separator: ",") + "]"
        case .object(let object):
            let members = object.map { key, value in
                "\(JSONValue.string(key).jsonText):\(value.jsonText)"
            }
            return "{" + members.joined(separator: ",") + "}"
        }
    }
}

/// Hands out session IDs like AMP's login and knows which are still valid.
@MainActor
final class Sessions {
    var valid: Set<String> = []
    private var counter = 0

    func login() -> HTTPResponse {
        counter += 1
        let id = "sid\(counter)"
        valid.insert(id)
        return .json(["success": true, "sessionID": .string(id)])
    }

    func accepts(_ request: RecordedRequest) -> Bool {
        request.body["SESSIONID"]?.stringValue.map(valid.contains) ?? false
    }
}

/// Blocks callers of `wait()` until it is opened (or their task is cancelled,
/// so that a test running into its time limit ends instead of hanging).
@MainActor
final class Gate {
    private(set) var waiters = 0
    private var isOpen = false

    func wait() async {
        waiters += 1
        defer { waiters -= 1 }
        while !isOpen, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    func open() {
        isOpen = true
    }
}

struct InMemorySettingsStore: SettingsStore {
    final class Storage: @unchecked Sendable {
        var settings = ServerSettings()
    }

    let storage = Storage()

    init(_ settings: ServerSettings = ServerSettings()) {
        storage.settings = settings
    }

    func load() -> ServerSettings { storage.settings }
    func save(_ settings: ServerSettings) { storage.settings = settings }
    func clear() { storage.settings = ServerSettings() }
}

/// Runs `body` and returns the `AMPError` it throws; anything else is
/// recorded as a test failure.
@MainActor
func ampError(
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: @MainActor () async throws -> Void
) async -> AMPError? {
    do {
        try await body()
        Issue.record("Expected an AMPError, but nothing was thrown", sourceLocation: sourceLocation)
    } catch let error as AMPError {
        return error
    } catch {
        Issue.record("Expected an AMPError, got \(error)", sourceLocation: sourceLocation)
    }
    return nil
}

/// Waits until `condition` holds, failing the test after two seconds.
@MainActor
func waitUntil(
    _ what: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @MainActor () -> Bool
) async {
    for _ in 0..<400 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    Issue.record("Timed out waiting until \(what)", sourceLocation: sourceLocation)
}
