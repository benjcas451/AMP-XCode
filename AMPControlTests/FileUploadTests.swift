import Foundation
import Testing

@testable import AMPControl

@MainActor
@Suite(.timeLimit(.minutes(1)))
final class FileUploadTests {
    private let server = FakeFileServer()
    private let toasts = ToastCenter()
    private let chunkSize = AMPClient.fileChunkSize
    /// Local files to upload live here.
    private let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("upload-tests-\(UUID().uuidString)")
    private var model: InstanceDetailViewModel!

    init() async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let instance = try AMPInstance(
            json: ["InstanceID": "mc", "InstanceName": "mc", "Running": true])
        model = InstanceDetailViewModel(instance: instance, client: server.client, toasts: toasts)
        await model.loadFiles()
    }

    deinit {
        try? FileManager.default.removeItem(at: folder)
    }

    /// A local file with these contents.
    private func local(_ name: String, _ contents: [UInt8]) throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(contents).write(to: url)
        return url
    }

    private func local(_ name: String, _ text: String) throws -> URL {
        try local(name, Array(text.utf8))
    }

    private func bytes(_ count: Int) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ $0 / 253) }
    }

    private var writes: [RecordedRequest] { server.requests("FileManagerPlugin/WriteFileChunk") }

    /// Starts an upload and waits until the conflict question is on screen.
    private func uploadUntilAsked(_ sources: [URL]) async -> Task<Void, Never> {
        let upload = Task { await model.uploadFiles(sources) }
        await waitUntil("the conflict is asked about") { model.dialogs.isChoosing }
        return upload
    }

    // MARK: - Plain uploads

    @Test func uploadsANewFileInPieces() async throws {
        let contents = bytes(2 * chunkSize + 100)
        await model.uploadFiles([try local("world.zip", contents)])

        #expect(server.files["world.zip"] == contents)
        #expect(writes.map { $0.body["Filename"] } == ["world.zip", "world.zip", "world.zip"])
        #expect(writes.map { $0.body["Offset"] } == [0, .int(chunkSize), .int(2 * chunkSize)])
        #expect(writes.map { $0.body["FinalChunk"] } == [false, false, true])
        #expect(!model.dialogs.isChoosing)
        #expect(toasts.current?.text == "„world.zip“ wurde hochgeladen.")
        #expect(toasts.current?.isError == false)
        // Done: nothing in progress, and the new file is in the list.
        #expect(model.upload == nil)
        #expect(!model.isBusy(.files))
        #expect(model.files?.map(\.name) == ["world.zip"])
    }

    @Test func uploadsAnEmptyFile() async throws {
        await model.uploadFiles([try local("eula.txt", [])])
        #expect(server.files["eula.txt"] == [])
        #expect(writes.count == 1)
        #expect(writes.first?.body["FinalChunk"] == true)
        #expect(toasts.current?.text == "„eula.txt“ wurde hochgeladen.")
    }

    @Test func uploadsIntoTheFolderOnScreen() async throws {
        server.folders = ["plugins"]
        await model.loadFiles()
        await model.openFolder(try #require(model.files?.first))
        #expect(model.directory == "plugins")

        await model.uploadFiles([try local("essentials.jar", "jar")])
        #expect(server.text(at: "plugins/essentials.jar") == "jar")
        #expect(model.files?.map(\.path) == ["plugins/essentials.jar"])
    }

    @Test func reportsProgressWhileSending() async throws {
        var seen: [UploadProgress] = []
        server.onWrite = { [unowned self] in
            if let upload = model.upload { seen.append(upload) }
        }
        await model.uploadFiles([try local("a.bin", bytes(chunkSize + 10))])
        #expect(seen.map(\.sent) == [0, chunkSize])
        #expect(seen.allSatisfy { $0.name == "a.bin" && $0.total == chunkSize + 10 && $0.count == 1 })
        #expect(seen.last?.fraction ?? 0 > 0.9)
    }

    @Test func uploadsSeveralFilesInARow() async throws {
        await model.uploadFiles([try local("a.txt", "A"), try local("b.txt", "B")])
        #expect(server.text(at: "a.txt") == "A")
        #expect(server.text(at: "b.txt") == "B")
        #expect(toasts.current?.text == "2 Dateien wurden hochgeladen.")
    }

    // MARK: - A file of that name exists

    @Test func asksWhatToDoWhenTheNameIsTaken() async throws {
        server.store("old", at: "server.properties")
        let upload = await uploadUntilAsked([try local("server.properties", "new")])

        let prompt = try #require(model.dialogs.choicePrompt)
        #expect(prompt.title == "Datei existiert bereits")
        #expect(prompt.message.contains("„server.properties“"))
        #expect(prompt.options.map(\.label) == ["Ersetzen", "Als „server-1.properties“ hochladen"])
        #expect(prompt.options.map(\.isDestructive) == [true, false])
        #expect(prompt.cancelLabel == "Abbrechen")
        // Nothing is touched before the answer.
        #expect(writes.isEmpty)
        #expect(server.count("FileManagerPlugin/TrashFile") == 0)

        model.dialogs.answerChoice(nil)
        await upload.value
    }

    @Test func replacingPutsTheOldFileInTheTrashFirst() async throws {
        // This server keeps the end of a longer file that is written over.
        server.truncatesOnWrite = false
        server.store("a much longer old file", at: "motd.txt")
        let upload = await uploadUntilAsked([try local("motd.txt", "short")])
        model.dialogs.answerChoice(0)
        await upload.value

        #expect(server.text(at: "motd.txt") == "short")
        let order = server.requests.map(\.method).filter {
            $0.hasSuffix("TrashFile") || $0.hasSuffix("WriteFileChunk")
        }
        #expect(order == ["FileManagerPlugin/TrashFile", "FileManagerPlugin/WriteFileChunk"])
        #expect(toasts.current?.text == "„motd.txt“ wurde hochgeladen.")
    }

    @Test func keepingBothUploadsUnderANumberedName() async throws {
        server.store("old", at: "ops.json")
        server.store("older", at: "ops-1.json")
        let upload = await uploadUntilAsked([try local("ops.json", "new")])
        #expect(model.dialogs.choicePrompt?.options.last?.label == "Als „ops-2.json“ hochladen")
        model.dialogs.answerChoice(1)
        await upload.value

        #expect(server.text(at: "ops.json") == "old")
        #expect(server.text(at: "ops-1.json") == "older")
        #expect(server.text(at: "ops-2.json") == "new")
        #expect(server.count("FileManagerPlugin/TrashFile") == 0)
        #expect(toasts.current?.text == "„ops-2.json“ wurde hochgeladen.")
    }

    @Test func cancellingLeavesEverythingAsItWas() async throws {
        server.store("old", at: "ops.json")
        let upload = await uploadUntilAsked([try local("ops.json", "new")])
        model.dialogs.answerChoice(nil)
        await upload.value

        #expect(server.files == ["ops.json": Array("old".utf8)])
        #expect(writes.isEmpty)
        #expect(toasts.current == nil)
        #expect(!model.isBusy(.files))
    }

    @Test func aFolderOfThatNameCannotBeReplaced() async throws {
        server.folders = ["world"]
        let upload = await uploadUntilAsked([try local("world", "not a folder")])
        let prompt = try #require(model.dialogs.choicePrompt)
        #expect(prompt.options.map(\.label) == ["Als „world-1“ hochladen"])
        #expect(prompt.message.contains("Ordner"))
        model.dialogs.answerChoice(0)
        await upload.value
        #expect(server.text(at: "world-1") == "not a folder")
    }

    @Test func skippingOneFileStillUploadsTheOthers() async throws {
        server.store("old", at: "a.txt")
        let upload = await uploadUntilAsked([try local("a.txt", "new"), try local("b.txt", "B")])
        #expect(model.dialogs.choicePrompt?.cancelLabel == "Überspringen")
        model.dialogs.answerChoice(nil)
        await upload.value

        #expect(server.text(at: "a.txt") == "old")
        #expect(server.text(at: "b.txt") == "B")
        #expect(toasts.current?.text == "1 von 2 Dateien wurden hochgeladen.")
    }

    @Test func twoChosenFilesOfTheSameNameConflictWithEachOther() async throws {
        let other = folder.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let second = other.appendingPathComponent("a.txt")
        try Data("second".utf8).write(to: second)

        let upload = await uploadUntilAsked([try local("a.txt", "first"), second])
        #expect(server.text(at: "a.txt") == "first")
        model.dialogs.answerChoice(1)
        await upload.value
        #expect(server.text(at: "a.txt") == "first")
        #expect(server.text(at: "a-1.txt") == "second")
    }

    @Test func numberedNamesKeepTheExtension() {
        func numbered(_ name: String, taken: Set<String> = []) -> String {
            InstanceDetailViewModel.numberedName(for: name) { taken.contains($0) }
        }
        #expect(numbered("server.properties") == "server-1.properties")
        #expect(numbered("archive.tar.gz") == "archive.tar-1.gz")
        #expect(numbered("README") == "README-1")
        #expect(numbered(".env") == ".env-1")
        #expect(numbered("a.txt", taken: ["a-1.txt", "a-2.txt"]) == "a-3.txt")
    }

    // MARK: - Failures

    @Test func aRefusedUploadIsReportedWithItsReason() async throws {
        server.writeFailure = "Access denied"
        await model.uploadFiles([try local("a.txt", "A"), try local("b.txt", "B")])
        #expect(toasts.current?.text == "„a.txt“: Access denied")
        #expect(toasts.current?.isError == true)
        // The rest of the batch is not attempted.
        #expect(writes.count == 1)
        #expect(server.files.isEmpty)
        #expect(model.upload == nil)
        #expect(!model.isBusy(.files))
    }

    @Test func aFailedReplacementSaysWhereTheOldFileIs() async throws {
        server.store("old", at: "a.txt")
        server.writeFailure = "Disk full"
        let upload = await uploadUntilAsked([try local("a.txt", "new")])
        model.dialogs.answerChoice(0)
        await upload.value
        #expect(
            toasts.current?.text
                == "„a.txt“: Disk full Die bisherige Datei liegt im Papierkorb von AMP.")
    }

    @Test func whatArrivedOfAFailedUploadIsRemoved() async throws {
        var pieces = 0
        server.onWrite = { [unowned self] in
            pieces += 1
            if pieces == 2 { server.writeFailure = "Connection lost" }
        }
        await model.uploadFiles([try local("big.bin", bytes(3 * chunkSize))])
        #expect(toasts.current?.text == "„big.bin“: Connection lost")
        #expect(server.files["big.bin"] == nil)
        #expect(server.requests("FileManagerPlugin/TrashFile").map { $0.body["Filename"] } == ["big.bin"])
    }

    @Test func cancellingStopsAndRemovesThePartialFile() async throws {
        var pieces = 0
        server.onWrite = { [unowned self] in
            pieces += 1
            if pieces == 2 { model.cancelUpload() }
        }
        await model.uploadFiles([try local("big.bin", bytes(4 * chunkSize)), try local("b.txt", "B")])
        #expect(writes.count == 2)
        #expect(server.files.isEmpty)
        #expect(toasts.current?.text == "Upload abgebrochen.")
        #expect(toasts.current?.isError == false)
        #expect(model.upload == nil)
        #expect(!model.isBusy(.files))
    }

    @Test func anUploadThatDidNotArriveIsNotReportedAsDone() async throws {
        server.ignoresWrites = true
        await model.uploadFiles([try local("a.txt", "A")])
        #expect(toasts.current?.text.contains("nicht vollständig hochgeladen") == true)
        #expect(toasts.current?.isError == true)
    }

    @Test func aFileThatCannotBeReadIsReported() async throws {
        await model.uploadFiles([folder.appendingPathComponent("missing.txt")])
        #expect(toasts.current?.text == "„missing.txt“ konnte nicht gelesen werden.")
        #expect(writes.isEmpty)
    }

    @Test func foldersCannotBeChangedWhileUploading() async throws {
        server.folders = ["plugins"]
        await model.loadFiles()
        let plugins = try #require(model.files?.first)
        var opened = false
        server.onWrite = { [unowned self] in
            if !opened {
                opened = true
                Task { await self.model.openFolder(plugins) }
            }
        }
        await model.uploadFiles([try local("a.bin", bytes(2 * chunkSize))])
        #expect(model.directory == "")
        #expect(server.files["a.bin"]?.count == 2 * chunkSize)
    }
}
