import Foundation

/// A problem with the contents of a file, with a message for the user.
struct FileFormatError: Error, Equatable {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// The tag types of Minecraft's NBT format, by their ID in the file.
enum NBTType: UInt8, CaseIterable, Sendable {
    case end = 0
    case byte, short, int, long, float, double
    case byteArray, string, list, compound, intArray, longArray

    var label: String {
        switch self {
        case .end: "End"
        case .byte: "Byte"
        case .short: "Short"
        case .int: "Int"
        case .long: "Long"
        case .float: "Float"
        case .double: "Double"
        case .byteArray: "Byte-Array"
        case .string: "String"
        case .list: "Liste"
        case .compound: "Compound"
        case .intArray: "Int-Array"
        case .longArray: "Long-Array"
        }
    }

    /// The types a user can add as a new entry.
    static let creatable = allCases.filter { $0 != .end }
}

struct NBTNamedTag: Equatable, Sendable {
    var name: String
    var value: NBTValue
}

/// One NBT tag without its name. Compounds keep the order of the file.
enum NBTValue: Equatable, Sendable {
    case byte(Int8)
    case short(Int16)
    case int(Int32)
    case long(Int64)
    case float(Float)
    case double(Double)
    case byteArray([Int8])
    case string(String)
    /// The element type is stored even for an empty list, as in the file.
    case list(NBTType, [NBTValue])
    case compound([NBTNamedTag])
    case intArray([Int32])
    case longArray([Int64])

    var type: NBTType {
        switch self {
        case .byte: .byte
        case .short: .short
        case .int: .int
        case .long: .long
        case .float: .float
        case .double: .double
        case .byteArray: .byteArray
        case .string: .string
        case .list: .list
        case .compound: .compound
        case .intArray: .intArray
        case .longArray: .longArray
        }
    }

    /// The value a newly added tag of `type` starts with.
    static func empty(_ type: NBTType) -> NBTValue? {
        switch type {
        case .end: nil
        case .byte: .byte(0)
        case .short: .short(0)
        case .int: .int(0)
        case .long: .long(0)
        case .float: .float(0)
        case .double: .double(0)
        case .byteArray: .byteArray([])
        case .string: .string("")
        case .list: .list(.end, [])
        case .compound: .compound([])
        case .intArray: .intArray([])
        case .longArray: .longArray([])
        }
    }
}

// MARK: - Strings

/// Java writes strings in "modified UTF-8": NUL takes two bytes and
/// characters outside the BMP are written as two surrogates of three bytes.
enum ModifiedUTF8 {
    static func encode(_ text: String) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf16.count)
        for unit in text.utf16 {
            if unit >= 0x0001 && unit <= 0x007F {
                bytes.append(UInt8(unit))
            } else if unit <= 0x07FF {
                bytes.append(0xC0 | UInt8(unit >> 6))
                bytes.append(0x80 | UInt8(unit & 0x3F))
            } else {
                bytes.append(0xE0 | UInt8(unit >> 12))
                bytes.append(0x80 | UInt8((unit >> 6) & 0x3F))
                bytes.append(0x80 | UInt8(unit & 0x3F))
            }
        }
        return bytes
    }

    static func decode(_ bytes: ArraySlice<UInt8>) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count)
        var iterator = bytes.makeIterator()
        while let first = iterator.next() {
            if first < 0x80 {
                units.append(UInt16(first))
            } else if first & 0xE0 == 0xC0, let second = iterator.next() {
                units.append(UInt16(first & 0x1F) << 6 | UInt16(second & 0x3F))
            } else if first & 0xF0 == 0xE0, let second = iterator.next(),
                let third = iterator.next()
            {
                units.append(
                    UInt16(first & 0x0F) << 12 | UInt16(second & 0x3F) << 6 | UInt16(third & 0x3F))
            } else {
                units.append(0xFFFD)
            }
        }
        return String(decoding: units, as: UTF16.self)
    }
}

// MARK: - Reading

/// Reads the binary form of a tag tree. Java Edition stores numbers
/// big-endian, Bedrock Edition little-endian.
struct NBTReader {
    static let maxDepth = 512

    private let bytes: [UInt8]
    private let littleEndian: Bool
    private var offset = 0

    private static let invalid = FileFormatError("Die Datei enthält keine gültigen NBT-Daten.")

    init(_ bytes: [UInt8], littleEndian: Bool) {
        self.bytes = bytes
        self.littleEndian = littleEndian
    }

    /// Reads a file's root tag, which has to be a compound that fills the
    /// data completely.
    static func readRoot(_ bytes: [UInt8], littleEndian: Bool) throws -> NBTNamedTag {
        var reader = NBTReader(bytes, littleEndian: littleEndian)
        guard try reader.unsigned(1) == UInt64(NBTType.compound.rawValue) else { throw invalid }
        let name = try reader.string()
        let value = try reader.payload(.compound, depth: 0)
        guard reader.offset == bytes.count else { throw invalid }
        return NBTNamedTag(name: name, value: value)
    }

    private var remaining: Int { bytes.count - offset }

    private mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= remaining else { throw Self.invalid }
        let slice = bytes[offset..<(offset + count)]
        offset += count
        return slice
    }

    private mutating func unsigned(_ size: Int) throws -> UInt64 {
        let slice = try take(size)
        var value: UInt64 = 0
        if littleEndian {
            for byte in slice.reversed() { value = value << 8 | UInt64(byte) }
        } else {
            for byte in slice { value = value << 8 | UInt64(byte) }
        }
        return value
    }

    private mutating func int8() throws -> Int8 {
        Int8(bitPattern: UInt8(truncatingIfNeeded: try unsigned(1)))
    }

    private mutating func int16() throws -> Int16 {
        Int16(bitPattern: UInt16(truncatingIfNeeded: try unsigned(2)))
    }

    private mutating func int32() throws -> Int32 {
        Int32(bitPattern: UInt32(truncatingIfNeeded: try unsigned(4)))
    }

    private mutating func int64() throws -> Int64 {
        Int64(bitPattern: try unsigned(8))
    }

    private mutating func string() throws -> String {
        let length = Int(try unsigned(2))
        let slice = try take(length)
        return littleEndian ? String(decoding: slice, as: UTF8.self) : ModifiedUTF8.decode(slice)
    }

    /// An element count, checked against the bytes that are left so that
    /// data in another format cannot ask for absurd amounts of memory.
    private mutating func length(elementSize: Int) throws -> Int {
        let count = Int(try int32())
        if count <= 0 { return 0 }
        guard count <= remaining / elementSize else { throw Self.invalid }
        return count
    }

    private mutating func type() throws -> NBTType {
        guard let type = NBTType(rawValue: UInt8(truncatingIfNeeded: try unsigned(1))) else {
            throw Self.invalid
        }
        return type
    }

    private mutating func payload(_ type: NBTType, depth: Int) throws -> NBTValue {
        guard depth <= Self.maxDepth else { throw Self.invalid }
        switch type {
        case .end:
            throw Self.invalid
        case .byte:
            return .byte(try int8())
        case .short:
            return .short(try int16())
        case .int:
            return .int(try int32())
        case .long:
            return .long(try int64())
        case .float:
            return .float(Float(bitPattern: UInt32(truncatingIfNeeded: try unsigned(4))))
        case .double:
            return .double(Double(bitPattern: try unsigned(8)))
        case .byteArray:
            let count = try length(elementSize: 1)
            return .byteArray(try take(count).map { Int8(bitPattern: $0) })
        case .string:
            return .string(try string())
        case .list:
            let elementType = try self.type()
            let count = try length(elementSize: 1)
            if count > 0 && elementType == .end { throw Self.invalid }
            var items: [NBTValue] = []
            items.reserveCapacity(count)
            for _ in 0..<count {
                items.append(try payload(elementType, depth: depth + 1))
            }
            return .list(elementType, items)
        case .compound:
            var entries: [NBTNamedTag] = []
            while true {
                let type = try self.type()
                if type == .end { break }
                let name = try string()
                entries.append(NBTNamedTag(name: name, value: try payload(type, depth: depth + 1)))
            }
            return .compound(entries)
        case .intArray:
            let count = try length(elementSize: 4)
            var values: [Int32] = []
            values.reserveCapacity(count)
            for _ in 0..<count { values.append(try int32()) }
            return .intArray(values)
        case .longArray:
            let count = try length(elementSize: 8)
            var values: [Int64] = []
            values.reserveCapacity(count)
            for _ in 0..<count { values.append(try int64()) }
            return .longArray(values)
        }
    }
}

// MARK: - Writing

struct NBTWriter {
    private(set) var bytes: [UInt8] = []
    private let littleEndian: Bool

    init(littleEndian: Bool) {
        self.littleEndian = littleEndian
    }

    static func writeRoot(_ root: NBTNamedTag, littleEndian: Bool) throws -> [UInt8] {
        var writer = NBTWriter(littleEndian: littleEndian)
        writer.bytes.append(root.value.type.rawValue)
        try writer.string(root.name)
        try writer.payload(root.value)
        return writer.bytes
    }

    private mutating func unsigned(_ value: UInt64, size: Int) {
        for index in 0..<size {
            let position = littleEndian ? index : size - 1 - index
            bytes.append(UInt8(truncatingIfNeeded: value >> UInt64(8 * position)))
        }
    }

    private mutating func signed(_ value: Int64, size: Int) {
        unsigned(UInt64(bitPattern: value), size: size)
    }

    private mutating func string(_ text: String) throws {
        let encoded = littleEndian ? Array(text.utf8) : ModifiedUTF8.encode(text)
        guard encoded.count <= Int(UInt16.max) else {
            throw FileFormatError("Ein Text ist länger, als NBT speichern kann (65535 Bytes).")
        }
        unsigned(UInt64(encoded.count), size: 2)
        bytes.append(contentsOf: encoded)
    }

    private mutating func count(_ count: Int) throws {
        guard count <= Int(Int32.max) else {
            throw FileFormatError("Eine Liste ist länger, als NBT speichern kann.")
        }
        signed(Int64(count), size: 4)
    }

    private mutating func payload(_ value: NBTValue) throws {
        switch value {
        case .byte(let value):
            signed(Int64(value), size: 1)
        case .short(let value):
            signed(Int64(value), size: 2)
        case .int(let value):
            signed(Int64(value), size: 4)
        case .long(let value):
            signed(value, size: 8)
        case .float(let value):
            unsigned(UInt64(value.bitPattern), size: 4)
        case .double(let value):
            unsigned(value.bitPattern, size: 8)
        case .byteArray(let values):
            try count(values.count)
            bytes.append(contentsOf: values.map { UInt8(bitPattern: $0) })
        case .string(let text):
            try string(text)
        case .list(let elementType, let items):
            guard items.allSatisfy({ $0.type == elementType }) else {
                throw FileFormatError("Eine Liste enthält Einträge unterschiedlichen Typs.")
            }
            bytes.append(elementType.rawValue)
            try count(items.count)
            for item in items { try payload(item) }
        case .compound(let entries):
            for entry in entries {
                bytes.append(entry.value.type.rawValue)
                try string(entry.name)
                try payload(entry.value)
            }
            bytes.append(NBTType.end.rawValue)
        case .intArray(let values):
            try count(values.count)
            for value in values { signed(Int64(value), size: 4) }
        case .longArray(let values):
            try count(values.count)
            for value in values { signed(value, size: 8) }
        }
    }
}

// MARK: - Files

/// How an NBT file is packed. Minecraft uses several variants; a file is
/// written back in the one it was read in.
struct NBTFormat: Equatable, Sendable {
    enum Compression: Equatable, Sendable {
        case none, gzip, zlib
    }

    var compression: Compression
    /// Bedrock Edition stores numbers little-endian, Java Edition big-endian.
    var littleEndian: Bool
    /// Bedrock's `level.dat` starts with a storage version and the length of
    /// the NBT data, eight bytes that are not part of the tag tree.
    var bedrockHeaderVersion: UInt32?

    static let java = NBTFormat(compression: .gzip, littleEndian: false)
    static let bedrockLevel = NBTFormat(
        compression: .none, littleEndian: true, bedrockHeaderVersion: 10)

    var label: String {
        var parts = [littleEndian ? "Bedrock Edition (Little-Endian)" : "Java Edition (Big-Endian)"]
        switch compression {
        case .none: parts.append("unkomprimiert")
        case .gzip: parts.append("gzip")
        case .zlib: parts.append("zlib")
        }
        if let bedrockHeaderVersion { parts.append("Header v\(bedrockHeaderVersion)") }
        return parts.joined(separator: " · ")
    }
}

/// A Minecraft `.dat` file: its tag tree and the way it is packed.
struct NBTFile: Equatable, Sendable {
    var format: NBTFormat
    var root: NBTNamedTag

    static let unknownFormat = FileFormatError(
        "Die Datei ist in keinem bekannten NBT-Format (Minecraft Java oder Bedrock).")

    init(format: NBTFormat, root: NBTNamedTag) {
        self.format = format
        self.root = root
    }

    /// Detects the variant from the contents: gzip or zlib compression by
    /// the stream header, the byte order by which one yields a tag tree
    /// that uses up the data exactly.
    init(data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 4 else { throw Self.unknownFormat }

        let compression: NBTFormat.Compression
        if bytes[0] == 0x1F && bytes[1] == 0x8B {
            compression = .gzip
        } else if bytes[0] == 0x78 && (UInt16(bytes[0]) << 8 | UInt16(bytes[1])) % 31 == 0 {
            compression = .zlib
        } else {
            compression = .none
        }

        let payload: [UInt8]
        if compression == .none {
            payload = bytes
        } else {
            guard let unpacked = try? Zlib.decompress(data) else { throw Self.unknownFormat }
            payload = [UInt8](unpacked)
        }

        // Bedrock's level.dat: version, length, then little-endian NBT.
        if payload.count > 8 {
            let length = payload[4..<8].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            if Int(length) == payload.count - 8,
                let root = try? NBTReader.readRoot(Array(payload[8...]), littleEndian: true)
            {
                let version = payload[0..<4].reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
                self.init(
                    format: NBTFormat(
                        compression: compression, littleEndian: true,
                        bedrockHeaderVersion: version),
                    root: root)
                return
            }
        }
        for littleEndian in [false, true] {
            if let root = try? NBTReader.readRoot(payload, littleEndian: littleEndian) {
                self.init(
                    format: NBTFormat(compression: compression, littleEndian: littleEndian),
                    root: root)
                return
            }
        }
        throw Self.unknownFormat
    }

    /// The tag tree without compression and Bedrock header.
    func payload() throws -> [UInt8] {
        try NBTWriter.writeRoot(root, littleEndian: format.littleEndian)
    }

    func encoded() throws -> Data {
        var bytes = try payload()
        if let version = format.bedrockHeaderVersion {
            var header: [UInt8] = []
            for value in [version, UInt32(bytes.count)] {
                for shift in [0, 8, 16, 24] {
                    header.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
                }
            }
            bytes = header + bytes
        }
        switch format.compression {
        case .none:
            return Data(bytes)
        case .gzip, .zlib:
            do {
                return try Zlib.compress(
                    Data(bytes), as: format.compression == .gzip ? .gzip : .zlib)
            } catch {
                throw FileFormatError("Die NBT-Daten konnten nicht komprimiert werden.")
            }
        }
    }
}

// MARK: - Editing

/// A child of a compound or list, for showing it in a list on screen.
struct NBTChild: Identifiable, Equatable, Sendable {
    let index: Int
    /// The tag name in a compound, the position in a list.
    let name: String
    let value: NBTValue

    var id: Int { index }
}

extension NBTValue {
    /// Arrays up to this length can be edited as text.
    static let maxEditableArrayCount = 4096

    var isContainer: Bool {
        switch self {
        case .list, .compound: true
        default: false
        }
    }

    /// The entries of a compound or list; `nil` for every other tag.
    var children: [NBTChild]? {
        switch self {
        case .compound(let entries):
            entries.enumerated().map { NBTChild(index: $0.offset, name: $0.element.name, value: $0.element.value) }
        case .list(_, let items):
            items.enumerated().map { NBTChild(index: $0.offset, name: "[\($0.offset)]", value: $0.element) }
        default:
            nil
        }
    }

    /// The tag reached by following `path`, a child index per level.
    func value(at path: some Collection<Int>) -> NBTValue? {
        guard let index = path.first else { return self }
        guard let children, children.indices.contains(index) else { return nil }
        return children[index].value.value(at: path.dropFirst())
    }

    private static let missing = FileFormatError("Der Eintrag ist nicht mehr vorhanden.")

    /// Applies `change` to the tag reached by following `path`.
    mutating func modify(
        at path: some Collection<Int>, _ change: (inout NBTValue) throws -> Void
    ) throws {
        guard let index = path.first else {
            try change(&self)
            return
        }
        switch self {
        case .compound(var entries):
            guard entries.indices.contains(index) else { throw Self.missing }
            try entries[index].value.modify(at: path.dropFirst(), change)
            self = .compound(entries)
        case .list(let elementType, var items):
            guard items.indices.contains(index) else { throw Self.missing }
            try items[index].modify(at: path.dropFirst(), change)
            self = .list(elementType, items)
        default:
            throw Self.missing
        }
    }

    /// Removes the child at `index` from a compound or list.
    mutating func removeChild(at index: Int) throws {
        switch self {
        case .compound(var entries):
            guard entries.indices.contains(index) else { throw Self.missing }
            entries.remove(at: index)
            self = .compound(entries)
        case .list(let elementType, var items):
            guard items.indices.contains(index) else { throw Self.missing }
            items.remove(at: index)
            self = .list(elementType, items)
        default:
            throw Self.missing
        }
    }

    /// Appends a tag to a compound (under `name`) or a list. A list takes
    /// only its own element type; an empty one adopts that of `value`.
    mutating func appendChild(_ value: NBTValue, name: String = "") throws {
        switch self {
        case .compound(var entries):
            guard !name.isEmpty else { throw FileFormatError("Der Name darf nicht leer sein.") }
            guard !entries.contains(where: { $0.name == name }) else {
                throw FileFormatError("Ein Eintrag „\(name)“ ist bereits vorhanden.")
            }
            entries.append(NBTNamedTag(name: name, value: value))
            self = .compound(entries)
        case .list(let elementType, var items):
            guard items.isEmpty || elementType == value.type else {
                throw FileFormatError("Diese Liste nimmt nur Einträge vom Typ \(elementType.label) auf.")
            }
            items.append(value)
            self = .list(value.type, items)
        default:
            throw Self.missing
        }
    }

    /// Short description for a row on screen.
    var summary: String {
        switch self {
        case .byte(let value): String(value)
        case .short(let value): String(value)
        case .int(let value): String(value)
        case .long(let value): String(value)
        case .float(let value): String(value)
        case .double(let value): String(value)
        case .string(let value): value
        case .byteArray(let values): Self.countLabel(values.count, "Wert", "Werte")
        case .intArray(let values): Self.countLabel(values.count, "Wert", "Werte")
        case .longArray(let values): Self.countLabel(values.count, "Wert", "Werte")
        case .list(_, let items): Self.countLabel(items.count, "Eintrag", "Einträge")
        case .compound(let entries): Self.countLabel(entries.count, "Eintrag", "Einträge")
        }
    }

    private static func countLabel(_ count: Int, _ one: String, _ many: String) -> String {
        "\(count) \(count == 1 ? one : many)"
    }

    /// The text a user edits; `nil` for tags that are not edited as text.
    var editText: String? {
        switch self {
        case .list, .compound:
            return nil
        case .byteArray(let values):
            return Self.arrayText(values)
        case .intArray(let values):
            return Self.arrayText(values)
        case .longArray(let values):
            return Self.arrayText(values)
        default:
            return summary
        }
    }

    private static func arrayText<T: FixedWidthInteger>(_ values: [T]) -> String? {
        guard values.count <= maxEditableArrayCount else { return nil }
        return values.map { String($0) }.joined(separator: ", ")
    }

    /// A tag of the same type as this one with the value given as `text`.
    func parsing(_ text: String) throws -> NBTValue {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        func integer<T: FixedWidthInteger>(_ text: String, _ type: T.Type) throws -> T {
            switch text.lowercased() {
            case "true": return 1
            case "false": return 0
            default: break
            }
            guard let value = T(text) else {
                throw FileFormatError(
                    "„\(text)“ ist keine ganze Zahl von \(T.min) bis \(T.max).")
            }
            return value
        }

        func array<T: FixedWidthInteger>(_ type: T.Type) throws -> [T] {
            try trimmed
                .split(whereSeparator: { $0 == "," || $0 == ";" || $0.isWhitespace })
                .map { try integer(String($0), type) }
        }

        func decimal<T: LosslessStringConvertible>(_ type: T.Type) throws -> T {
            guard let value = T(trimmed.replacingOccurrences(of: ",", with: ".")) else {
                throw FileFormatError("„\(trimmed)“ ist keine Zahl.")
            }
            return value
        }

        switch self {
        case .byte: return .byte(try integer(trimmed, Int8.self))
        case .short: return .short(try integer(trimmed, Int16.self))
        case .int: return .int(try integer(trimmed, Int32.self))
        case .long: return .long(try integer(trimmed, Int64.self))
        case .float: return .float(try decimal(Float.self))
        case .double: return .double(try decimal(Double.self))
        case .string: return .string(text)
        case .byteArray: return .byteArray(try array(Int8.self))
        case .intArray: return .intArray(try array(Int32.self))
        case .longArray: return .longArray(try array(Int64.self))
        case .list, .compound:
            throw FileFormatError("Dieser Eintrag kann nicht als Text bearbeitet werden.")
        }
    }
}
