import Foundation

/// A text file as it is edited: the text with `\n` line ends, plus what is
/// needed to write it back the way it was stored.
struct TextDocument: Equatable, Sendable {
    enum Syntax: Equatable, Sendable {
        case json, xml, csv, plain

        var label: String {
            switch self {
            case .json: "JSON"
            case .xml: "XML"
            case .csv: "CSV"
            case .plain: "Text"
            }
        }
    }

    enum Encoding: Equatable, Sendable {
        case utf8, utf8WithBOM, latin1

        var label: String {
            switch self {
            case .utf8: "UTF-8"
            case .utf8WithBOM: "UTF-8 mit BOM"
            case .latin1: "ISO-8859-1"
            }
        }
    }

    var text: String
    var syntax: Syntax
    var encoding: Encoding
    var usesCRLF: Bool

    static let binaryFile = FileFormatError(
        "Die Datei ist keine Textdatei und kann nicht in der App bearbeitet werden.")

    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    static func syntax(forFileName name: String) -> Syntax {
        switch FileDocument.fileExtension(name) {
        case "json", "mcmeta", "geojson", "jsonl": .json
        case "xml", "xaml", "config", "csproj", "plist": .xml
        case "csv", "tsv": .csv
        default: .plain
        }
    }

    init(text: String, syntax: Syntax, encoding: Encoding = .utf8, usesCRLF: Bool = false) {
        self.text = text
        self.syntax = syntax
        self.encoding = encoding
        self.usesCRLF = usesCRLF
    }

    init(name: String, data: Data) throws {
        var bytes = [UInt8](data)
        // Control characters other than tab, line ends, form feed and
        // escape do not occur in text files.
        let allowed: Set<UInt8> = [0x09, 0x0A, 0x0C, 0x0D, 0x1B]
        guard !bytes.contains(where: { $0 < 0x20 && !allowed.contains($0) }) else {
            throw Self.binaryFile
        }

        var encoding = Encoding.utf8
        if bytes.starts(with: Self.byteOrderMark) {
            encoding = .utf8WithBOM
            bytes.removeFirst(Self.byteOrderMark.count)
        }
        var text: String
        if let decoded = String(bytes: bytes, encoding: .utf8) {
            text = decoded
        } else if encoding == .utf8, let decoded = String(bytes: bytes, encoding: .isoLatin1) {
            // Older server files, such as server.properties, are Latin-1.
            text = decoded
            encoding = .latin1
        } else {
            throw Self.binaryFile
        }

        let usesCRLF = text.contains("\r\n")
        if usesCRLF { text = text.replacingOccurrences(of: "\r\n", with: "\n") }
        self.init(
            text: text, syntax: Self.syntax(forFileName: name), encoding: encoding,
            usesCRLF: usesCRLF)
    }

    func encoded() throws -> Data {
        var text = self.text.replacingOccurrences(of: "\r\n", with: "\n")
        if usesCRLF { text = text.replacingOccurrences(of: "\n", with: "\r\n") }
        switch encoding {
        case .utf8:
            return Data(text.utf8)
        case .utf8WithBOM:
            return Data(Self.byteOrderMark) + Data(text.utf8)
        case .latin1:
            guard let data = text.data(using: .isoLatin1) else {
                throw FileFormatError(
                    "Die Datei ist in ISO-8859-1 gespeichert; der Text enthält Zeichen, "
                        + "die es dort nicht gibt.")
            }
            return data
        }
    }

    /// What is wrong with the text as JSON or XML; `nil` when it is fine or
    /// the file has no syntax to check.
    var validationProblem: String? {
        switch syntax {
        case .csv, .plain:
            return nil
        case .json:
            do {
                _ = try JSONSerialization.jsonObject(
                    with: Data(text.utf8), options: [.fragmentsAllowed])
                return nil
            } catch {
                let details = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
                return details ?? error.localizedDescription
            }
        case .xml:
            let parser = XMLParser(data: Data(text.utf8))
            if parser.parse() { return nil }
            let reason = parser.parserError?.localizedDescription ?? "Unbekannter Fehler"
            return "Zeile \(parser.lineNumber), Spalte \(parser.columnNumber): \(reason)"
        }
    }
}

/// The contents of a file opened in the editor.
enum FileDocument: Equatable, Sendable {
    case text(TextDocument)
    case nbt(NBTFile)

    /// File name extensions of Minecraft's NBT files.
    static let nbtExtensions: Set<String> = [
        "dat", "dat_old", "dat_new", "nbt", "mcstructure", "schem", "schematic", "litematic",
    ]

    /// The part after the last dot, in lower case.
    static func fileExtension(_ name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    init(name: String, data: Data) throws {
        guard Self.nbtExtensions.contains(Self.fileExtension(name)) else {
            self = .text(try TextDocument(name: name, data: data))
            return
        }
        if let file = try? NBTFile(data: data) {
            self = .nbt(file)
        } else if let text = try? TextDocument(name: name, data: data) {
            // Other games use these extensions for plain text.
            self = .text(text)
        } else {
            throw NBTFile.unknownFormat
        }
    }

    func encoded() throws -> Data {
        switch self {
        case .text(let document): try document.encoded()
        case .nbt(let file): try file.encoded()
        }
    }
}
