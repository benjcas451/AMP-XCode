import Foundation

/// A decoded JSON document.
///
/// AMP's responses are loosely typed (numbers arrive as strings, fields are
/// renamed between versions), so the client works on this tree instead of
/// fixed `Codable` models.
enum JSONValue: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object(JSONObject)
}

typealias JSONObject = [String: JSONValue]

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode(JSONObject.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

extension JSONValue {
    var isNull: Bool { self == .null }

    var objectValue: JSONObject? {
        if case .object(let value) = self { return value }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    /// Member of an object; `nil` when this is not an object or the key is
    /// absent, `.null` when the key is present with a JSON null.
    subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// Text form of any non-null value: strings as they are, everything else
    /// the way it would be printed (`20`, `true`, `[a, b]`).
    var text: String? {
        switch self {
        case .null: return nil
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .string(let value): return value
        case .array(let values):
            return "[" + values.map { $0.text ?? "null" }.joined(separator: ", ") + "]"
        case .object(let object):
            let members = object.keys.sorted().map { "\($0): \(object[$0]?.text ?? "null")" }
            return "{" + members.joined(separator: ", ") + "}"
        }
    }

    /// An integer, given either as a JSON number or as a numeric string.
    var lenientInt: Int? {
        switch self {
        case .int(let value): return value
        case .string(let value): return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }
}

extension Dictionary where Key == String, Value == JSONValue {
    /// The value for `key` unless it is absent or JSON null.
    func value(_ key: String) -> JSONValue? {
        guard let value = self[key], !value.isNull else { return nil }
        return value
    }

    /// Text form of the value for `key`; `nil` when absent or JSON null.
    func text(_ key: String) -> String? { self[key]?.text }
}

extension JSONValue: ExpressibleByNilLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByStringLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    init(nilLiteral: ()) { self = .null }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(floatLiteral value: Double) { self = .double(value) }
    init(stringLiteral value: String) { self = .string(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}
