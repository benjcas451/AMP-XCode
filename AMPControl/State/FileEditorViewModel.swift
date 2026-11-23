import Foundation
import Observation

/// State and actions of the file editor: loads one file of an instance,
/// lets the user change it as text or as an NBT tag tree, and writes it back.
@MainActor
@Observable
final class FileEditorViewModel {
    enum Phase: Equatable, Sendable {
        case loading
        case failed(String)
        case ready
    }

    /// Text files beyond this size are too slow to edit on screen.
    static let maxTextSize = 1024 * 1024

    let file: FileEntry
    let dialogs = DialogCoordinator()
    let toasts: ToastCenter

    private(set) var phase = Phase.loading
    private(set) var document: FileDocument?
    /// The text on screen, for text files.
    var text = ""
    private(set) var isSaving = false

    private var savedText = ""
    private var nbtChanged = false

    @ObservationIgnored private let instanceID: String
    @ObservationIgnored private let client: AMPClient
    @ObservationIgnored private let onClose: @MainActor (_ saved: Bool) async -> Void
    @ObservationIgnored private var isLoading = false

    init(
        file: FileEntry,
        instanceID: String,
        client: AMPClient,
        toasts: ToastCenter,
        onClose: @escaping @MainActor (_ saved: Bool) async -> Void
    ) {
        self.file = file
        self.instanceID = instanceID
        self.client = client
        self.toasts = toasts
        self.onClose = onClose
    }

    var textDocument: TextDocument? {
        if case .text(let document)? = document { return document }
        return nil
    }

    var nbtFile: NBTFile? {
        if case .nbt(let file)? = document { return file }
        return nil
    }

    var hasChanges: Bool {
        switch document {
        case .text?: text != savedText
        case .nbt?: nbtChanged
        case nil: false
        }
    }

    var canSave: Bool { phase == .ready && hasChanges && !isSaving }

    /// How the file is stored, e.g. "JSON · UTF-8 · LF".
    var details: String {
        switch document {
        case .text(let document)?:
            [document.syntax.label, document.encoding.label, document.usesCRLF ? "CRLF" : "LF"]
                .joined(separator: " · ")
        case .nbt(let file)?:
            "NBT · " + file.format.label
        case nil:
            ""
        }
    }

    // MARK: - Loading and saving

    func load() async {
        guard document == nil, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        phase = .loading
        do {
            if file.sizeBytes > AMPClient.maxEditableFileSize { throw AMPClient.fileTooLarge }
            let data = try await client.readFile(instanceID, path: file.path)
            let document = try FileDocument(name: file.name, data: data)
            if case .text(let textDocument) = document {
                if data.count > Self.maxTextSize {
                    throw FileFormatError(
                        "Textdateien können bis 1 MB in der App bearbeitet werden.")
                }
                text = textDocument.text
                savedText = textDocument.text
            }
            nbtChanged = false
            self.document = document
            phase = .ready
        } catch let failure as AMPError {
            phase = .failed(failure.message)
        } catch let failure as FileFormatError {
            phase = .failed(failure.message)
        } catch is CancellationError {
            phase = .failed("Das Laden wurde abgebrochen.")
        } catch {
            phase = .failed("Unerwarteter Fehler: \(error.localizedDescription)")
        }
    }

    func save() async {
        guard canSave, var document else { return }
        if case .text(var textDocument) = document {
            textDocument.text = text
            if let problem = textDocument.validationProblem {
                let confirmed = await dialogs.confirm(
                    ConfirmationPrompt(
                        title: "Ungültiges \(textDocument.syntax.label)",
                        message: "\(problem)\n\nTrotzdem speichern?",
                        confirmLabel: "Trotzdem speichern",
                        isDestructive: true))
                guard confirmed else { return }
            }
            document = .text(textDocument)
        }

        isSaving = true
        defer { isSaving = false }
        do {
            let data = try document.encoded()
            try await client.writeFile(instanceID, path: file.path, data: data)
        } catch let failure as AMPError {
            toasts.show(failure.message, isError: true)
            return
        } catch let failure as FileFormatError {
            toasts.show(failure.message, isError: true)
            return
        } catch {
            return
        }
        self.document = document
        savedText = text
        nbtChanged = false
        toasts.show("„\(file.name)“ gespeichert.")
        await onClose(true)
    }

    /// Closes the editor, asking first when changes would be lost.
    func close() async {
        guard !isSaving else { return }
        if hasChanges {
            let confirmed = await dialogs.confirm(
                ConfirmationPrompt(
                    title: "Änderungen verwerfen?",
                    message: "Die Änderungen an „\(file.name)“ wurden nicht gespeichert.",
                    confirmLabel: "Verwerfen",
                    isDestructive: true))
            guard confirmed else { return }
        }
        await onClose(false)
    }

    // MARK: - NBT

    /// The tag reached from the root by following `path`.
    func nbtValue(at path: [Int]) -> NBTValue? {
        nbtFile?.root.value.value(at: path)
    }

    /// Applies `change` to the root tag. Returns whether it went through.
    @discardableResult
    private func updateNBT(_ change: (inout NBTValue) throws -> Void) -> Bool {
        guard case .nbt(var file)? = document, !isSaving else { return false }
        do {
            try change(&file.root.value)
        } catch let failure as FileFormatError {
            toasts.show(failure.message, isError: true)
            return false
        } catch {
            return false
        }
        document = .nbt(file)
        nbtChanged = true
        return true
    }

    /// Asks for a new value of `child`, an entry of the tag at `parent`.
    func editValue(_ child: NBTChild, in parent: [Int]) async {
        guard let current = child.value.editText else {
            toasts.show("Dieser Eintrag ist zu groß, um ihn in der App zu bearbeiten.")
            return
        }
        var hint = child.value.type.label
        switch child.value {
        case .byteArray, .intArray, .longArray: hint += ": Werte durch Komma getrennt"
        case .byte: hint += " (−128 bis 127, auch true/false)"
        default: break
        }
        let input = await dialogs.requestText(
            TextPrompt(
                title: child.name,
                message: hint,
                placeholder: "Wert",
                initialText: current,
                confirmLabel: "Übernehmen"))
        guard let input, input != current else { return }
        let path = parent + [child.index]
        updateNBT { root in
            try root.modify(at: path) { tag in
                // The tree may have changed while the prompt was open.
                guard tag == child.value else {
                    throw FileFormatError("Der Eintrag ist nicht mehr vorhanden.")
                }
                tag = try tag.parsing(input)
            }
        }
    }

    func removeChild(_ child: NBTChild, from parent: [Int]) async {
        let confirmed = await dialogs.confirm(
            ConfirmationPrompt(
                title: "Eintrag löschen?",
                message: "„\(child.name)“ mit allen enthaltenen Werten aus der Datei entfernen?",
                confirmLabel: "Löschen",
                isDestructive: true))
        guard confirmed else { return }
        updateNBT { root in
            try root.modify(at: parent) { tag in
                guard tag.children?.contains(child) == true else {
                    throw FileFormatError("Der Eintrag ist nicht mehr vorhanden.")
                }
                try tag.removeChild(at: child.index)
            }
        }
    }

    /// Adds an empty tag of `type` to the compound or list at `parent`.
    func addChild(_ type: NBTType, to parent: [Int]) async {
        guard let target = nbtValue(at: parent), let value = NBTValue.empty(type) else { return }
        var name = ""
        if case .compound = target {
            let input = await dialogs.requestText(
                TextPrompt(
                    title: "Neuer Eintrag",
                    message: type.label,
                    placeholder: "Name",
                    confirmLabel: "Hinzufügen"))
            guard let input else { return }
            name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        updateNBT { root in
            try root.modify(at: parent) { tag in try tag.appendChild(value, name: name) }
        }
    }
}
