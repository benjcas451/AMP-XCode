import Foundation
import Testing

@testable import AMPControl

/// A fake AMP whose instance keeps files in memory and serves them through
/// the file manager's chunk methods.
@MainActor
final class FakeFileServer {
    var files: [String: [UInt8]] = [:]
    private(set) var requests: [RecordedRequest] = []

    /// Whether writing into a longer file cuts off its old end.
    var truncatesOnWrite = true
    /// Older AMP versions only; newer ones have ReadFileChunk instead.
    var hasGetFileChunk = true
    /// The most bytes handed out per request, whatever was asked for.
    var maxChunk = Int.max
    var ignoresWrites = false
    var writeFailure: String?

    private(set) lazy var client = AMPClient(
        baseURL: "http://amp.local", username: "", password: "",
        transport: MockTransport { [unowned self] request in
            requests.append(request)
            return .json(respond(to: request))
        })

    func count(_ method: String) -> Int {
        requests.filter { $0.method == method }.count
    }

    func requests(_ method: String) -> [RecordedRequest] {
        requests.filter { $0.method == method }
    }

    func store(_ text: String, at path: String) {
        files[path] = Array(text.utf8)
    }

    func text(at path: String) -> String? {
        files[path].map { String(decoding: $0, as: UTF8.self) }
    }

    /// The directory entry of a stored file.
    func entry(_ path: String) -> FileEntry {
        FileEntry(json: [
            "Filename": .string(path.components(separatedBy: "/").last ?? path),
            "Path": .string(path),
            "SizeBytes": .int(files[path]?.count ?? 0),
        ])
    }

    private func respond(to request: RecordedRequest) -> JSONValue {
        let body = request.body
        let name = body["Filename"]?.stringValue ?? ""
        switch request.method {
        case "Core/Login":
            return ["success": true, "sessionID": "session"]
        case "FileManagerPlugin/GetDirectoryListing":
            return []
        case "FileManagerPlugin/GetFileChunk":
            guard hasGetFileChunk else {
                return ["Title": "MissingMethodException", "Message": "Missing method", "StackTrace": ""]
            }
            return chunk(
                name, position: body["Position"]?.lenientInt ?? 0,
                length: body["Length"]?.lenientInt ?? 0)
        case "FileManagerPlugin/ReadFileChunk":
            return chunk(
                name, position: body["Offset"]?.lenientInt ?? 0,
                length: body["ChunkSize"]?.lenientInt ?? 0)
        case "FileManagerPlugin/WriteFileChunk":
            if let writeFailure { return ["Status": false, "Reason": .string(writeFailure)] }
            if ignoresWrites { return ["Status": true] }
            let data = [UInt8](Data(base64Encoded: body["Data"]?.stringValue ?? "") ?? Data())
            let offset = body["Offset"]?.lenientInt ?? 0
            let contents = files[name] ?? []
            guard offset <= contents.count else { return ["Status": false, "Reason": "Bad offset"] }
            var updated = Array(contents[..<offset]) + data
            if !truncatesOnWrite, contents.count > updated.count {
                updated += contents[updated.count...]
            }
            files[name] = updated
            return ["Status": true]
        case "FileManagerPlugin/TrashFile":
            files[name] = nil
            return ["Status": true]
        default:
            return .null
        }
    }

    private func chunk(_ name: String, position: Int, length: Int) -> JSONValue {
        guard let contents = files[name] else {
            return ["Status": false, "Reason": "File not found"]
        }
        let start = min(max(position, 0), contents.count)
        let end = min(start + min(max(length, 0), maxChunk), contents.count)
        let piece = Data(contents[start..<end])
        return [
            "Result": [
                "Base64Data": .string(piece.base64EncodedString()),
                "BytesLength": .int(piece.count),
            ],
            "Status": true,
        ]
    }
}

private func pattern(_ count: Int) -> [UInt8] {
    (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ $0 / 251) }
}

// MARK: - Client

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct FileTransferTests {
    private let server = FakeFileServer()
    private var client: AMPClient { server.client }
    private let chunkSize = AMPClient.fileChunkSize

    @Test func readsAFileInPieces() async throws {
        let contents = pattern(chunkSize * 2 + 1000)
        server.files["big.bin"] = contents

        let data = try await client.readFile("mc", path: "big.bin")
        #expect([UInt8](data) == contents)
        let reads = server.requests("FileManagerPlugin/GetFileChunk")
        #expect(reads.first?.path == "/API/ADSModule/Servers/mc/API/FileManagerPlugin/GetFileChunk")
        #expect(reads.first?.body["Filename"] == "big.bin")
        #expect(reads.first?.body["Length"] == .int(chunkSize))
        // The last request finds the end of the file.
        #expect(
            reads.map { $0.body["Position"]?.lenientInt }
                == [0, chunkSize, chunkSize * 2, contents.count])
    }

    @Test func aServerHandingOutSmallerPiecesIsReadToTheEnd() async throws {
        let contents = pattern(5000)
        server.files["latest.log"] = contents
        server.maxChunk = 1000
        let data = try await client.readFile("mc", path: "latest.log")
        #expect([UInt8](data) == contents)
        #expect(server.count("FileManagerPlugin/GetFileChunk") == 6)
    }

    @Test func emptyFilesAreRead() async throws {
        server.files["empty.txt"] = []
        let data = try await client.readFile("mc", path: "empty.txt")
        #expect(data.isEmpty)
        #expect(server.count("FileManagerPlugin/GetFileChunk") == 1)
    }

    @Test func fallsBackToReadFileChunkWhereGetFileChunkIsMissing() async throws {
        server.hasGetFileChunk = false
        let contents = pattern(chunkSize + 5)
        server.files["a.bin"] = contents

        let data = try await client.readFile("mc", path: "a.bin")
        #expect([UInt8](data) == contents)
        // Asked once, then remembered as missing.
        #expect(server.count("FileManagerPlugin/GetFileChunk") == 1)
        let reads = server.requests("FileManagerPlugin/ReadFileChunk")
        #expect(reads.map { $0.body["Offset"]?.lenientInt } == [0, chunkSize, contents.count])
        #expect(reads.first?.body["ChunkSize"] == .int(chunkSize))
    }

    @Test func aPieceMayBeTheBareBase64Text() async throws {
        let client = AMPClient(
            baseURL: "http://amp.local", username: "", password: "",
            transport: MockTransport { request in
                switch request.method {
                case "Core/Login":
                    return .json(["success": true, "sessionID": "session"])
                case "FileManagerPlugin/GetFileChunk":
                    let piece = request.body["Position"] == 0 ? "aGFsbG8=" : ""
                    return .json(["result": .string(piece)])
                default:
                    return .json(.null)
                }
            })
        let data = try await client.readFile("mc", path: "a.txt")
        #expect(String(decoding: data, as: UTF8.self) == "hallo")
    }

    @Test func readFailuresSurfaceTheReason() async {
        let missing = await ampError { _ = try await client.readFile("mc", path: "nope.txt") }
        #expect(missing?.message == "File not found")
        let empty = await ampError { _ = try await client.readFile("mc", path: "  ") }
        #expect(empty?.message == "Pfad darf nicht leer sein.")
    }

    @Test func writesAFileInPiecesAndReadsItBack() async throws {
        let contents = pattern(chunkSize + 300)
        server.files["world/level.dat"] = pattern(40)

        try await client.writeFile("mc", path: "world/level.dat", data: Data(contents))
        #expect(server.files["world/level.dat"] == contents)
        let writes = server.requests("FileManagerPlugin/WriteFileChunk")
        #expect(writes.map { $0.body["Offset"]?.lenientInt } == [0, chunkSize])
        #expect(writes.map { $0.body["FinalChunk"] == .bool(true) } == [false, true])
        #expect(writes.first?.body["Filename"] == "world/level.dat")
        // Read back: two pieces and the empty one at the end.
        #expect(server.count("FileManagerPlugin/GetFileChunk") == 3)
        #expect(server.count("FileManagerPlugin/TrashFile") == 0)
    }

    @Test func anEmptyFileIsWrittenWithOneEmptyPiece() async throws {
        server.store("old", at: "a.txt")
        try await client.writeFile("mc", path: "a.txt", data: Data())
        #expect(server.files["a.txt"] == [])
        let writes = server.requests("FileManagerPlugin/WriteFileChunk")
        #expect(writes.count == 1)
        #expect(writes.first?.body["Data"] == "")
        #expect(writes.first?.body["FinalChunk"] == true)
    }

    @Test func aShorterFileReplacesTheLongerOneWhereAMPKeepsTheOldEnd() async throws {
        server.truncatesOnWrite = false
        server.store(#"{"motd": "a much longer line than before"}"#, at: "config.json")

        try await client.writeFile("mc", path: "config.json", data: Data("{}".utf8))
        #expect(server.text(at: "config.json") == "{}")
        #expect(server.count("FileManagerPlugin/TrashFile") == 1)
        #expect(server.count("FileManagerPlugin/WriteFileChunk") == 2)
    }

    @Test func aFileThatDoesNotHoldTheNewContentsIsReported() async {
        server.store("old", at: "a.txt")
        server.ignoresWrites = true
        let error = await ampError {
            try await client.writeFile("mc", path: "a.txt", data: Data("new".utf8))
        }
        #expect(error?.message.hasPrefix("Die Datei wurde nicht vollständig gespeichert.") == true)
        #expect(server.count("FileManagerPlugin/TrashFile") == 0)
    }

    @Test func writeFailuresSurfaceTheReason() async {
        server.store("old", at: "a.txt")
        server.writeFailure = "Disk full"
        let error = await ampError {
            try await client.writeFile("mc", path: "a.txt", data: Data("new".utf8))
        }
        #expect(error?.message == "Disk full")
        #expect(server.text(at: "a.txt") == "old")
    }

    @Test func oversizedContentsAreNotSent() async {
        let data = Data(count: AMPClient.maxEditableFileSize + 1)
        let error = await ampError { try await client.writeFile("mc", path: "a.bin", data: data) }
        #expect(error == AMPClient.fileTooLarge)
        #expect(server.requests.isEmpty)
    }
}

// MARK: - Text documents

@Suite struct FileDocumentTests {
    @Test func plainUTF8TextIsKeptAsItIs() throws {
        let data = Data("{\"a\": 1}\n".utf8)
        let document = try TextDocument(name: "config.json", data: data)
        #expect(document.text == "{\"a\": 1}\n")
        #expect(document.syntax == .json)
        #expect(document.encoding == .utf8)
        #expect(!document.usesCRLF)
        #expect(try document.encoded() == data)
    }

    @Test func byteOrderMarkAndWindowsLineEndsSurviveEditing() throws {
        let data = Data([0xEF, 0xBB, 0xBF]) + Data("a=1\r\nb=2\r\n".utf8)
        var document = try TextDocument(name: "settings.ini", data: data)
        #expect(document.text == "a=1\nb=2\n")
        #expect(document.encoding == .utf8WithBOM)
        #expect(document.usesCRLF)
        #expect(try document.encoded() == data)

        document.text = "a=1\nb=3\nc=4\n"
        #expect(
            try document.encoded() == Data([0xEF, 0xBB, 0xBF]) + Data("a=1\r\nb=3\r\nc=4\r\n".utf8))
    }

    @Test func latin1FilesStayLatin1() throws {
        let data = Data([0x6D, 0x6F, 0x74, 0x64, 0x3D, 0xFC])
        var document = try TextDocument(name: "server.properties", data: data)
        #expect(document.text == "motd=ü")
        #expect(document.encoding == .latin1)
        #expect(try document.encoded() == data)

        document.text = "motd=€"
        #expect(throws: FileFormatError.self) { _ = try document.encoded() }
    }

    @Test func binaryDataIsNotText() {
        #expect(throws: TextDocument.binaryFile) {
            _ = try TextDocument(name: "a.txt", data: Data([0x50, 0x4B, 0x03, 0x04, 0x00]))
        }
    }

    @Test func syntaxFollowsTheFileName() {
        #expect(TextDocument.syntax(forFileName: "ops.JSON") == .json)
        #expect(TextDocument.syntax(forFileName: "pack.mcmeta") == .json)
        #expect(TextDocument.syntax(forFileName: "log4j2.xml") == .xml)
        #expect(TextDocument.syntax(forFileName: "players.csv") == .csv)
        #expect(TextDocument.syntax(forFileName: "server.properties") == .plain)
        #expect(TextDocument.syntax(forFileName: "README") == .plain)
        #expect(FileDocument.fileExtension("level.dat_old") == "dat_old")
        #expect(FileDocument.fileExtension(".gitignore") == "")
        #expect(FileDocument.fileExtension("a.tar.GZ") == "gz")
    }

    @Test func jsonAndXMLAreChecked() {
        func problem(_ text: String, _ syntax: TextDocument.Syntax) -> String? {
            TextDocument(text: text, syntax: syntax).validationProblem
        }
        #expect(problem(#"{"a": [1, 2, {"b": null}]}"#, .json) == nil)
        #expect(problem("[]", .json) == nil)
        #expect(problem(#"{"a": }"#, .json) != nil)
        #expect(problem("", .json) != nil)
        #expect(problem("<a><b c=\"d\"/></a>", .xml) == nil)
        #expect(problem("<a><b></a>", .xml)?.hasPrefix("Zeile 1, Spalte ") == true)
        #expect(problem("a;b;c\n1;2", .csv) == nil)
        #expect(problem("{", .plain) == nil)
    }

    @Test func datFilesAreNBTOrText() throws {
        guard case .nbt(let java) = try FileDocument(name: "level.dat", data: NBTFixtures.javaGzip)
        else {
            Issue.record("Expected an NBT document")
            return
        }
        #expect(java.format == .java)
        guard
            case .nbt(let bedrock) = try FileDocument(
                name: "level.dat_old", data: NBTFixtures.bedrockLevel)
        else {
            Issue.record("Expected an NBT document")
            return
        }
        #expect(bedrock.format == .bedrockLevel)

        // Other games use the extension for text.
        let text = try FileDocument(name: "banned.dat", data: Data("steam:1\n".utf8))
        #expect(text == .text(TextDocument(text: "steam:1\n", syntax: .plain)))
        #expect(throws: NBTFile.unknownFormat) {
            _ = try FileDocument(name: "region.dat", data: Data([0, 1, 2, 3, 4, 5]))
        }
        // NBT is recognised by the file name, not by the contents.
        #expect(throws: TextDocument.binaryFile) {
            _ = try FileDocument(name: "level.bin", data: NBTFixtures.javaGzip)
        }
    }
}

// MARK: - Editor

@MainActor
@Suite(.timeLimit(.minutes(1)))
final class FileEditorViewModelTests {
    private let server = FakeFileServer()
    private let toasts = ToastCenter()
    /// One entry per closing of the editor: whether the file was saved.
    private var closed: [Bool] = []

    private func editor(_ path: String) async -> FileEditorViewModel {
        let model = FileEditorViewModel(
            file: server.entry(path), instanceID: "mc", client: server.client, toasts: toasts
        ) { [unowned self] saved in
            closed.append(saved)
        }
        await model.load()
        return model
    }

    private func storedNBT(_ path: String) throws -> NBTFile {
        try NBTFile(data: Data(try #require(server.files[path])))
    }

    @Test func editsAndSavesATextFile() async throws {
        server.store("{\"a\": 1}\r\n", at: "config/app.json")
        let model = await editor("config/app.json")
        #expect(model.phase == .ready)
        #expect(model.text == "{\"a\": 1}\n")
        #expect(model.details == "JSON · UTF-8 · CRLF")
        #expect(!model.hasChanges)
        #expect(!model.canSave)

        model.text = "{\"a\": 2}\n"
        #expect(model.hasChanges)
        await model.save()

        #expect(server.text(at: "config/app.json") == "{\"a\": 2}\r\n")
        #expect(closed == [true])
        #expect(toasts.current?.text == "„app.json“ gespeichert.")
        #expect(!model.hasChanges)
        #expect(!model.isSaving)
    }

    @Test func invalidJSONIsOnlySavedAfterConfirmation() async throws {
        server.store("{}", at: "ops.json")
        let model = await editor("ops.json")
        model.text = "{"

        let declined = Task { await model.save() }
        await waitUntil("the problem is shown") { model.dialogs.isConfirming }
        #expect(model.dialogs.confirmation?.title == "Ungültiges JSON")
        #expect(model.dialogs.confirmation?.message.hasSuffix("Trotzdem speichern?") == true)
        model.dialogs.answerConfirmation(false)
        await declined.value
        #expect(server.count("FileManagerPlugin/WriteFileChunk") == 0)
        #expect(closed.isEmpty)
        #expect(model.hasChanges)

        let confirmed = Task { await model.save() }
        await waitUntil("the problem is shown again") { model.dialogs.isConfirming }
        model.dialogs.answerConfirmation(true)
        await confirmed.value
        #expect(server.text(at: "ops.json") == "{")
        #expect(closed == [true])
    }

    @Test func csvAndXMLFilesOpenAsText() async {
        server.store("name;score\nAlex;3\n", at: "scores.csv")
        server.store("<config><port>25565</port></config>", at: "config.xml")
        let csv = await editor("scores.csv")
        #expect(csv.details == "CSV · UTF-8 · LF")
        #expect(csv.text == "name;score\nAlex;3\n")
        let xml = await editor("config.xml")
        #expect(xml.details == "XML · UTF-8 · LF")
    }

    @Test func failedSavesKeepTheEditorOpen() async {
        server.store("a=1", at: "server.properties")
        let model = await editor("server.properties")
        model.text = "a=2"
        server.writeFailure = "Disk full"
        await model.save()
        #expect(toasts.current?.text == "Disk full")
        #expect(toasts.current?.isError == true)
        #expect(closed.isEmpty)
        #expect(model.hasChanges)
        #expect(model.canSave)
    }

    @Test func editsAJavaLevelDat() async throws {
        server.files["world/level.dat"] = [UInt8](NBTFixtures.javaGzip)
        let model = await editor("world/level.dat")
        #expect(model.phase == .ready)
        #expect(model.details == "NBT · Java Edition (Big-Endian) · gzip")
        #expect(model.nbtValue(at: [])?.children?.map(\.name) == ["Data"])
        #expect(!model.hasChanges)

        let levelName = try #require(model.nbtValue(at: [0])?.children?.first)
        #expect(levelName.name == "LevelName")
        let edit = Task { await model.editValue(levelName, in: [0]) }
        await waitUntil("the value is asked for") { model.dialogs.isRequestingText }
        #expect(model.dialogs.textPrompt?.title == "LevelName")
        #expect(model.dialogs.textPrompt?.message == "String")
        #expect(model.dialogs.text == "Survival")
        model.dialogs.answerText("Neue Welt")
        await edit.value
        #expect(model.nbtValue(at: [0, 0]) == .string("Neue Welt"))
        #expect(model.hasChanges)

        await model.save()
        #expect(closed == [true])
        let stored = try storedNBT("world/level.dat")
        #expect(stored.format == .java)
        let data = nbtEntry(stored.root.value, "Data")
        #expect(nbtEntry(data, "LevelName") == .string("Neue Welt"))
        // Everything else is as it was.
        #expect(nbtEntry(data, "Time") == .long(123_456_789_012))
        #expect(nbtEntry(data, "motd") == .string("Grüße 🎮 \u{0} Ende"))
    }

    @Test func editsABedrockLevelDat() async throws {
        server.files["worlds/Bedrock level/level.dat"] = [UInt8](NBTFixtures.bedrockLevel)
        let model = await editor("worlds/Bedrock level/level.dat")
        #expect(
            model.details == "NBT · Bedrock Edition (Little-Endian) · unkomprimiert · Header v10")

        let gameType = try #require(
            model.nbtValue(at: [])?.children?.first { $0.name == "GameType" })
        let edit = Task { await model.editValue(gameType, in: []) }
        await waitUntil("the value is asked for") { model.dialogs.isRequestingText }
        #expect(model.dialogs.text == "1")
        model.dialogs.answerText("0")
        await edit.value
        await model.save()

        let bytes = try #require(server.files["worlds/Bedrock level/level.dat"])
        #expect(bytes.count == NBTFixtures.bedrockLevel.count)
        #expect(Array(bytes[0..<8]) == Array(NBTFixtures.bedrockLevel.prefix(8)))
        let stored = try storedNBT("worlds/Bedrock level/level.dat")
        #expect(stored.format == .bedrockLevel)
        #expect(nbtEntry(stored.root.value, "GameType") == .int(0))
        #expect(nbtEntry(stored.root.value, "LevelName") == .string("Bedrock Welt"))
    }

    @Test func invalidValuesAreRejectedWithAMessage() async throws {
        server.files["level.dat"] = [UInt8](NBTFixtures.javaGzip)
        let model = await editor("level.dat")
        let hardcore = try #require(model.nbtValue(at: [0])?.children?[1])
        #expect(hardcore.name == "hardcore")

        let edit = Task { await model.editValue(hardcore, in: [0]) }
        await waitUntil("the value is asked for") { model.dialogs.isRequestingText }
        #expect(model.dialogs.textPrompt?.message == "Byte (−128 bis 127, auch true/false)")
        model.dialogs.answerText("ja")
        await edit.value
        #expect(toasts.current?.text == "„ja“ ist keine ganze Zahl von -128 bis 127.")
        #expect(model.nbtValue(at: [0, 1]) == .byte(0))
        #expect(!model.hasChanges)

        // An unchanged or cancelled value is no change either.
        let unchanged = Task { await model.editValue(hardcore, in: [0]) }
        await waitUntil("the value is asked for again") { model.dialogs.isRequestingText }
        model.dialogs.answerText("0")
        await unchanged.value
        #expect(!model.hasChanges)
    }

    @Test func entriesAreAddedAndRemoved() async throws {
        server.files["level.dat"] = [UInt8](NBTFixtures.javaGzip)
        let model = await editor("level.dat")
        let before = try #require(model.nbtValue(at: [0])?.children)

        let add = Task { await model.addChild(.int, to: [0]) }
        await waitUntil("the name is asked for") { model.dialogs.isRequestingText }
        #expect(model.dialogs.textPrompt?.title == "Neuer Eintrag")
        model.dialogs.answerText(" DayTime ")
        await add.value
        let added = try #require(model.nbtValue(at: [0])?.children?.last)
        #expect(added == NBTChild(index: before.count, name: "DayTime", value: .int(0)))
        #expect(model.hasChanges)

        // A name that is taken is refused.
        let duplicate = Task { await model.addChild(.string, to: [0]) }
        await waitUntil("the name is asked for again") { model.dialogs.isRequestingText }
        model.dialogs.answerText("LevelName")
        await duplicate.value
        #expect(toasts.current?.text == "Ein Eintrag „LevelName“ ist bereits vorhanden.")
        #expect(model.nbtValue(at: [0])?.children?.count == before.count + 1)

        // Lists take new entries without a name.
        await model.addChild(.string, to: [0, 9])
        #expect(model.nbtValue(at: [0, 9])?.children?.map(\.value)
            == [.string("vanilla"), .string("paper"), .string("")])

        let remove = Task { await model.removeChild(added, from: [0]) }
        await waitUntil("the removal is confirmed") { model.dialogs.isConfirming }
        #expect(model.dialogs.confirmation?.title == "Eintrag löschen?")
        model.dialogs.answerConfirmation(true)
        await remove.value
        #expect(model.nbtValue(at: [0])?.children?.map(\.name) == before.map(\.name))

        await model.save()
        let stored = try storedNBT("level.dat")
        let brands = nbtEntry(nbtEntry(stored.root.value, "Data"), "ServerBrands")
        #expect(brands == .list(.string, [.string("vanilla"), .string("paper"), .string("")]))
    }

    @Test func closingWithChangesAsksFirst() async {
        server.store("a=1", at: "server.properties")
        let model = await editor("server.properties")
        await model.close()
        #expect(closed == [false])

        model.text = "a=2"
        let kept = Task { await model.close() }
        await waitUntil("the user is asked") { model.dialogs.isConfirming }
        #expect(model.dialogs.confirmation?.title == "Änderungen verwerfen?")
        model.dialogs.answerConfirmation(false)
        await kept.value
        #expect(closed == [false])

        let discarded = Task { await model.close() }
        await waitUntil("the user is asked again") { model.dialogs.isConfirming }
        model.dialogs.answerConfirmation(true)
        await discarded.value
        #expect(closed == [false, false])
        #expect(server.text(at: "server.properties") == "a=1")
    }

    @Test func filesThatCannotBeEditedSayWhy() async {
        server.files["plugin.jar"] = [0x50, 0x4B, 0x03, 0x04, 0x00, 0x00]
        let binary = await editor("plugin.jar")
        #expect(binary.phase == .failed(TextDocument.binaryFile.message))
        #expect(!binary.canSave)

        server.files["region.dat"] = [0, 1, 2, 3, 4, 5]
        let unknown = await editor("region.dat")
        #expect(unknown.phase == .failed(NBTFile.unknownFormat.message))

        let missing = await editor("gone.txt")
        #expect(missing.phase == .failed("File not found"))
    }

    @Test func largeFilesAreNotEvenDownloaded() async {
        let entry = FileEntry(json: [
            "Filename": "world.zip", "Path": "world.zip",
            "SizeBytes": .int(AMPClient.maxEditableFileSize + 1),
        ])
        let model = FileEditorViewModel(
            file: entry, instanceID: "mc", client: server.client, toasts: toasts
        ) { _ in }
        await model.load()
        #expect(model.phase == .failed(AMPClient.fileTooLarge.message))
        #expect(server.requests.isEmpty)
    }

    @Test func aFailedLoadCanBeRetried() async {
        let model = await editor("later.txt")
        #expect(model.phase == .failed("File not found"))
        server.store("da", at: "later.txt")
        await model.load()
        #expect(model.phase == .ready)
        #expect(model.text == "da")
    }
}
