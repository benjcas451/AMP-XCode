import Foundation
import Observation

/// The sections of the instance detail screen.
enum DetailTab: String, CaseIterable, Identifiable, Sendable {
    case overview, console, users, backups, files, settings, tasks, events, updates

    var id: Self { self }

    var label: String {
        switch self {
        case .overview: "Übersicht"
        case .console: "Konsole"
        case .users: "Spieler"
        case .backups: "Backups"
        case .files: "Dateien"
        case .settings: "Settings"
        case .tasks: "Zeitplan"
        case .events: "Ereignisse"
        case .updates: "Updates"
        }
    }

    /// The API method a tab depends on. Tabs whose method this AMP
    /// installation lacks are hidden.
    var requiredMethod: (module: String, method: String)? {
        switch self {
        case .overview, .console, .users: nil
        case .backups: ("LocalFileBackupPlugin", "GetBackups")
        case .files: ("FileManagerPlugin", "GetDirectoryListing")
        case .settings: ("Core", "GetSettingsSpec")
        case .tasks: ("Core", "GetScheduleData")
        case .events: ("Core", "GetAuditLogEntries")
        case .updates: ("Core", "GetStatus")
        }
    }
}

/// A console entry with a stable identity for the list on screen.
struct ConsoleLine: Identifiable, Hashable, Sendable {
    let id: Int
    let entry: ConsoleEntry
}

/// A file opened in the editor. A new session for every opening, so that
/// the editor screen is built afresh.
struct FileEditorSession: Identifiable {
    let id = UUID()
    let model: FileEditorViewModel
}

/// How far the upload of a file has got.
struct UploadProgress: Equatable, Sendable {
    var name: String
    /// Which of the chosen files this is, starting at 1.
    var position: Int
    var count: Int
    var sent = 0
    var total = 0

    var fraction: Double { total > 0 ? Double(sent) / Double(total) : 0 }
}

/// State and actions of the instance detail screen.
@MainActor
@Observable
final class InstanceDetailViewModel {
    enum Operation: Hashable, Sendable {
        case server, backups, files, settings, tasks, update
    }

    static let maxConsoleLines = 500

    let instance: AMPInstance
    let dialogs = DialogCoordinator()

    private(set) var status: InstanceStatus?
    /// Error of the status/console polling, shown above all tabs.
    private(set) var error: String?
    private(set) var console: [ConsoleLine] = []
    private(set) var users: [String]?
    private(set) var backups: [BackupEntry]?
    private(set) var files: [FileEntry]?
    private(set) var directory = ""
    /// The file being edited, shown on top of the detail screen.
    var editor: FileEditorSession?
    /// The upload in progress, if any.
    private(set) var upload: UploadProgress?
    private(set) var settings: [SettingEntry]?
    private(set) var tasks: [SchedulerTask]?
    private(set) var events: [AMPEvent]?
    private(set) var updateStatus: InstanceStatus?

    private(set) var tabs: [DetailTab] = []
    var selectedTab = DetailTab.overview
    private(set) var tabErrors: [DetailTab: String] = [:]
    private(set) var loadingTabs: Set<DetailTab> = []
    private(set) var busy: Set<Operation> = []

    @ObservationIgnored private let client: AMPClient
    @ObservationIgnored private let toasts: ToastCenter
    @ObservationIgnored private var polling = false
    @ObservationIgnored private var uploadTask: Task<UploadReport, Never>?
    @ObservationIgnored private var nextConsoleID = 0
    /// Cleared when the screen is gone, so late results stay silent.
    @ObservationIgnored private var onScreen = true

    private var id: String { instance.id }

    init(instance: AMPInstance, client: AMPClient, toasts: ToastCenter) {
        self.instance = instance
        self.client = client
        self.toasts = toasts
        refreshTabs()
    }

    func isBusy(_ operation: Operation) -> Bool { busy.contains(operation) }
    func isLoading(_ tab: DetailTab) -> Bool { loadingTabs.contains(tab) }

    // MARK: - Tabs

    private func isTabSupported(_ tab: DetailTab) -> Bool {
        guard let required = tab.requiredMethod else { return true }
        if tab == .updates, !client.isMethodSupported("UpdateApplication", instanceID: id) {
            return false
        }
        return client.isMethodSupported(required.method, module: required.module, instanceID: id)
    }

    private func refreshTabs() {
        let supported = DetailTab.allCases.filter(isTabSupported)
        if supported != tabs { tabs = supported }
        if !supported.contains(selectedTab) { selectedTab = .overview }
    }

    // MARK: - Loading

    /// Loads everything, then keeps status and console up to date until the
    /// surrounding task is cancelled.
    func run() async {
        onScreen = true
        defer { onScreen = false }
        await loadAll()
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { break }
            await poll()
        }
    }

    func loadAll() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.poll() }
            group.addTask { await self.loadUsers() }
            for tab in DetailTab.allCases where tab.requiredMethod != nil {
                group.addTask { await self.reload(tab) }
            }
        }
    }

    func poll() async {
        if polling { return }
        polling = true
        defer { polling = false }
        do {
            let updates = try await client.getUpdates(id)
            for entry in updates.console {
                console.append(ConsoleLine(id: nextConsoleID, entry: entry))
                nextConsoleID += 1
            }
            if console.count > Self.maxConsoleLines {
                console.removeFirst(console.count - Self.maxConsoleLines)
            }
            // GetUpdates may omit Status. Reconcile with a full status read
            // so an earlier transitional state cannot remain stuck on screen.
            let currentStatus: InstanceStatus
            if let status = updates.status {
                currentStatus = status
            } else {
                currentStatus = try await client.getStatus(id)
            }
            status = currentStatus
            updateStatus = currentStatus
            error = nil
        } catch let failure as AMPError {
            error = failure.message
        } catch {}
        refreshTabs()
    }

    func reload(_ tab: DetailTab) async {
        switch tab {
        case .overview, .console: break
        case .users: await loadUsers()
        case .backups: await loadBackups()
        case .files: await loadFiles()
        case .settings: await loadSettings()
        case .tasks: await loadTasks()
        case .events: await loadEvents()
        case .updates: await loadUpdateStatus()
        }
    }

    private func load(_ tab: DetailTab, _ work: @MainActor () async throws -> Void) async {
        guard isTabSupported(tab), !loadingTabs.contains(tab) else { return }
        loadingTabs.insert(tab)
        tabErrors[tab] = nil
        do {
            try await work()
        } catch let failure as AMPError {
            tabErrors[tab] = failure.message
        } catch is CancellationError {
        } catch {
            tabErrors[tab] = "Unerwarteter Fehler: \(error.localizedDescription)"
        }
        loadingTabs.remove(tab)
        refreshTabs()
    }

    func loadUsers() async {
        await load(.users) { self.users = try await self.client.getUsers(self.id) }
    }

    func loadBackups() async {
        await load(.backups) { self.backups = try await self.client.getBackups(self.id) }
    }

    func loadFiles() async {
        await loadDirectory(directory)
    }

    func openFolder(_ file: FileEntry) async {
        guard file.isDirectory, files?.contains(file) == true, !isBusy(.files) else { return }
        await loadDirectory(file.path)
    }

    func openParentFolder() async {
        guard !directory.isEmpty, !isBusy(.files) else { return }
        let parent = directory.split(separator: "/").dropLast().joined(separator: "/")
        await loadDirectory(parent)
    }

    private func loadDirectory(_ path: String) async {
        await load(.files) {
            let files = try await self.client.getFiles(self.id, directory: path)
            // Commit the path and its contents together only after a successful read.
            self.directory = path
            self.files = files
        }
    }

    func loadSettings() async {
        await load(.settings) { self.settings = try await self.client.getSettings(self.id) }
    }

    func loadTasks() async {
        await load(.tasks) { self.tasks = try await self.client.getTasks(self.id) }
    }

    func loadEvents() async {
        await load(.events) { self.events = try await self.client.getEvents(self.id) }
    }

    func loadUpdateStatus() async {
        await load(.updates) {
            self.updateStatus = try await self.client.getUpdateStatus(self.id)
        }
    }

    // MARK: - Actions

    /// Runs `work` while `operation` is marked busy and reports the outcome
    /// as a toast.
    private func perform(
        _ operation: Operation,
        success: String,
        _ work: @MainActor () async throws -> Void
    ) async {
        busy.insert(operation)
        defer {
            busy.remove(operation)
            refreshTabs()
        }
        do {
            try await work()
            if onScreen { toasts.show(success) }
        } catch let failure as AMPError {
            if onScreen { toasts.show(failure.message) }
        } catch {}
    }

    private func confirm(
        _ title: String, _ message: String, button: String, destructive: Bool = false
    ) async -> Bool {
        await dialogs.confirm(
            ConfirmationPrompt(
                title: title, message: message, confirmLabel: button, isDestructive: destructive))
    }

    // MARK: Server

    func startServer() async {
        await runServerAction("Starten") { try await self.client.startServer(self.id) }
    }

    func stopServer() async {
        await runServerAction("Stoppen", confirm: true) {
            try await self.client.stopServer(self.id)
        }
    }

    func restartServer() async {
        await runServerAction("Neustarten", confirm: true) {
            try await self.client.restartServer(self.id)
        }
    }

    func killServer() async {
        await runServerAction("Beenden erzwingen", confirm: true, destructive: true) {
            try await self.client.killServer(self.id)
        }
    }

    private func runServerAction(
        _ label: String,
        confirm needsConfirmation: Bool = false,
        destructive: Bool = false,
        _ action: @MainActor () async throws -> Void
    ) async {
        if needsConfirmation {
            let confirmed = await confirm(
                "\(label)?",
                "\(instance.displayName): Aktion „\(label)“ wirklich ausführen?",
                button: label, destructive: destructive)
            guard confirmed else { return }
        }
        await perform(.server, success: "\(label) gesendet.", action)
        await poll()
    }

    /// Sends a console command. Returns `true` when it was sent.
    func sendConsole(_ message: String) async -> Bool {
        do {
            try await client.sendConsole(id, message)
        } catch let failure as AMPError {
            if onScreen { toasts.show(failure.message) }
            return false
        } catch {
            return false
        }
        Task { await poll() }
        return true
    }

    // MARK: Backups

    static func nextBackupName(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmssSSS"
        return "backup-" + formatter.string(from: now)
    }

    func createBackup() async {
        let input = await dialogs.requestText(
            TextPrompt(
                title: "Backup erstellen",
                placeholder: "Backup-Name",
                initialText: Self.nextBackupName(),
                confirmLabel: "Erstellen"
            ))
        guard let name = input?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty
        else { return }
        await perform(.backups, success: "Backup „\(name)“ wird erstellt.") {
            try await self.client.createBackup(self.id, name: name)
            await self.loadBackups()
        }
    }

    func restoreBackup(_ backup: BackupEntry) async {
        guard
            await confirm(
                "Backup wiederherstellen?", "„\(backup.name)“ wirklich wiederherstellen?",
                button: "Wiederherstellen")
        else { return }
        await perform(.backups, success: "Backup „\(backup.name)“ wird wiederhergestellt.") {
            try await self.client.restoreBackup(self.id, backupID: backup.id)
            await self.loadBackups()
        }
    }

    func deleteBackup(_ backup: BackupEntry) async {
        guard
            await confirm(
                "Backup löschen?", "„\(backup.name)“ dauerhaft löschen?",
                button: "Löschen", destructive: true)
        else { return }
        await perform(.backups, success: "Backup „\(backup.name)“ wurde gelöscht.") {
            try await self.client.deleteBackup(self.id, backupID: backup.id)
            await self.loadBackups()
        }
    }

    // MARK: Files

    func createFolder() async {
        let input = await dialogs.requestText(
            TextPrompt(
                title: "Ordner erstellen",
                placeholder: "Pfad, z. B. config/addons",
                confirmLabel: "Erstellen"
            ))
        guard let path = input?.trimmingCharacters(in: .whitespacesAndNewlines), !path.isEmpty
        else { return }
        let fullPath = directory.isEmpty ? path : "\(directory)/\(path)"
        await perform(.files, success: "Ordner „\(path)“ wird erstellt.") {
            try await self.client.createDirectory(self.id, path: fullPath)
            await self.loadFiles()
        }
    }

    func deleteFile(_ file: FileEntry) async {
        guard
            await confirm(
                "In den Papierkorb verschieben?", "„\(file.path)“ in den Papierkorb verschieben?",
                button: "Verschieben", destructive: true)
        else { return }
        await perform(.files, success: "„\(file.name)“ wurde in den Papierkorb verschoben.") {
            try await self.client.deleteFile(
                self.id, path: file.path, isDirectory: file.isDirectory)
            await self.loadFiles()
        }
    }

    func renameFile(_ file: FileEntry) async {
        let input = await dialogs.requestText(
            TextPrompt(
                title: "Datei umbenennen",
                placeholder: "Neuer Name",
                initialText: file.name,
                confirmLabel: "Umbenennen"
            ))
        guard let newName = input?.trimmingCharacters(in: .whitespacesAndNewlines),
            !newName.isEmpty, newName != file.name
        else { return }
        await perform(.files, success: "„\(file.name)“ wird umbenannt.") {
            try await self.client.renameFile(
                self.id, path: file.path, newName: newName, isDirectory: file.isDirectory)
            await self.loadFiles()
        }
    }

    // MARK: Upload

    /// What became of the files of one upload.
    private struct UploadReport {
        /// Name and size of every file that was sent completely.
        var sent: [(name: String, size: Int)] = []
        var cancelled = false
        var problem: String?
    }

    private enum ConflictAnswer {
        case replace
        case rename(String)
        case skip
    }

    /// `name` with a counter before its extension that makes it free:
    /// `server.properties` becomes `server-1.properties`.
    static func numberedName(for name: String, isTaken: (String) -> Bool) -> String {
        var stem = name
        var suffix = ""
        // A leading dot belongs to the name (`.env`), it starts no extension.
        if let dot = name.lastIndex(of: "."), dot != name.startIndex {
            stem = String(name[..<dot])
            suffix = String(name[dot...])
        }
        var counter = 1
        while isTaken("\(stem)-\(counter)\(suffix)") {
            counter += 1
        }
        return "\(stem)-\(counter)\(suffix)"
    }

    /// Uploads local files into the folder on screen. Where a name is
    /// already taken there, the user decides what happens.
    func uploadFiles(_ sources: [URL]) async {
        guard !sources.isEmpty, uploadTask == nil, !isBusy(.files) else { return }
        let folder = directory
        busy.insert(.files)
        let task = Task { await self.sendFiles(sources, into: folder) }
        uploadTask = task
        var report = await task.value
        uploadTask = nil
        upload = nil
        busy.remove(.files)

        await loadFiles()
        if report.problem == nil, !report.cancelled, tabErrors[.files] == nil {
            // The list has just been read again: compare it with what was sent.
            for file in report.sent {
                let stored = files?.first { $0.name == file.name }
                // A listing without sizes reports 0 and cannot be compared.
                let size = stored?.sizeBytes ?? 0
                if stored == nil || (size > 0 && size != file.size) {
                    report.problem =
                        "„\(file.name)“ wurde nicht vollständig hochgeladen. "
                        + "Bitte die Datei auf dem Server prüfen."
                    break
                }
            }
        }
        guard onScreen else { return }
        if let problem = report.problem {
            toasts.show(problem, isError: true)
        } else if report.cancelled {
            toasts.show("Upload abgebrochen.")
        } else if sources.count == 1, let file = report.sent.first {
            toasts.show("„\(file.name)“ wurde hochgeladen.")
        } else if report.sent.count == sources.count {
            toasts.show("\(report.sent.count) Dateien wurden hochgeladen.")
        } else if !report.sent.isEmpty {
            toasts.show("\(report.sent.count) von \(sources.count) Dateien wurden hochgeladen.")
        }
    }

    /// Stops the upload in progress. Files already sent stay on the server.
    func cancelUpload() {
        uploadTask?.cancel()
    }

    private func sendFiles(_ sources: [URL], into folder: String) async -> UploadReport {
        var report = UploadReport()
        var taken: [String: FileEntry]
        do {
            let listing = try await client.getFiles(id, directory: folder)
            taken = Dictionary(listing.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            report.cancelled = error is CancellationError
            report.problem = (error as? AMPError)?.message
            return report
        }

        for (index, source) in sources.enumerated() {
            if Task.isCancelled {
                report.cancelled = true
                break
            }
            var name = source.lastPathComponent
            var replaced: FileEntry?
            if let existing = taken[name] {
                switch await askAboutConflict(with: existing, taken: taken, isOnlyFile: sources.count == 1) {
                case .skip: continue
                case .replace: replaced = existing
                case .rename(let free): name = free
                }
            }
            let path = folder.isEmpty ? name : "\(folder)/\(name)"
            upload = UploadProgress(name: name, position: index + 1, count: sources.count)

            var started = false
            do {
                if let replaced {
                    // Writing does not cut off a longer file, so the old one
                    // has to go first. It stays in AMP's trash.
                    try await client.deleteFile(id, path: replaced.path)
                }
                started = true
                let size = try await client.uploadFile(id, path: path, from: source) { sent, total in
                    self.upload?.sent = sent
                    self.upload?.total = total
                }
                report.sent.append((name, size))
                taken[name] = FileEntry(json: ["Filename": .string(name), "Path": .string(path)])
            } catch {
                if started { await discardPartialUpload(path) }
                if error is CancellationError || Task.isCancelled {
                    report.cancelled = true
                } else if let failure = error as? AMPError {
                    report.problem = "„\(name)“: \(failure.message)"
                } else {
                    report.problem = "„\(name)“ konnte nicht gelesen werden."
                }
                if replaced != nil, started {
                    let hint = "Die bisherige Datei liegt im Papierkorb von AMP."
                    report.problem = [report.problem ?? "Upload abgebrochen.", hint]
                        .joined(separator: " ")
                }
                break
            }
        }
        return report
    }

    private func askAboutConflict(
        with existing: FileEntry, taken: [String: FileEntry], isOnlyFile: Bool
    ) async -> ConflictAnswer {
        let free = Self.numberedName(for: existing.name) { taken[$0] != nil }
        var options = [ChoicePrompt.Option(label: "Als „\(free)“ hochladen")]
        var message = "Einen Ordner namens „\(existing.name)“ gibt es hier schon."
        if !existing.isDirectory {
            options.insert(ChoicePrompt.Option(label: "Ersetzen", isDestructive: true), at: 0)
            message =
                "„\(existing.name)“ gibt es in diesem Ordner schon. Beim Ersetzen wandert "
                + "die bisherige Datei in den Papierkorb von AMP."
        }
        let choice = await dialogs.choose(
            ChoicePrompt(
                title: "Datei existiert bereits",
                message: message,
                options: options,
                cancelLabel: isOnlyFile ? "Abbrechen" : "Überspringen"
            ))
        guard let choice else { return .skip }
        return options[choice].isDestructive ? .replace : .rename(free)
    }

    /// Moves what arrived of a failed upload to AMP's trash.
    private func discardPartialUpload(_ path: String) async {
        // In a task of its own: the upload's task may have been cancelled,
        // which would cancel this request along with it.
        await Task { _ = try? await self.client.deleteFile(self.id, path: path) }.value
    }

    /// Opens `file` in the editor. The file list is read again after a
    /// save, since size and date have changed.
    func editFile(_ file: FileEntry) {
        guard !file.isDirectory, editor == nil else { return }
        let model = FileEditorViewModel(
            file: file, instanceID: id, client: client, toasts: toasts
        ) { [weak self] saved in
            self?.editor = nil
            if saved { await self?.loadFiles() }
        }
        editor = FileEditorSession(model: model)
    }

    // MARK: Settings

    func editSetting(_ setting: SettingEntry) async {
        guard !setting.readOnly, !isBusy(.settings) else { return }
        var details = [setting.description]
        if setting.key != setting.displayName { details.append(setting.key) }
        let newValue = await dialogs.requestText(
            TextPrompt(
                title: setting.displayName,
                message: details.filter { !$0.isEmpty }.joined(separator: "\n\n"),
                placeholder: setting.type.isEmpty ? "Wert" : "Wert (\(setting.type))",
                initialText: setting.value,
                confirmLabel: "Speichern"
            ))
        guard let newValue, newValue != setting.value else { return }
        await perform(.settings, success: "Setting „\(setting.displayName)“ gespeichert.") {
            try await self.client.setSetting(self.id, node: setting.node, value: newValue)
            await self.loadSettings()
        }
    }

    // MARK: Schedule

    func toggleTask(_ task: SchedulerTask) async {
        let outcome = task.enabled ? "deaktiviert" : "aktiviert"
        await perform(.tasks, success: "Task „\(task.name)“ \(outcome).") {
            try await self.client.setTaskEnabled(
                self.id, taskID: task.id, enabled: !task.enabled)
            await self.loadTasks()
        }
    }

    // MARK: Game server update

    func runUpdate() async {
        guard
            await confirm(
                "Spielserver aktualisieren?",
                "AMP aktualisiert die Spielserver-Dateien aus der konfigurierten Quelle.",
                button: "Update starten")
        else { return }
        await perform(.update, success: "Update wird ausgeführt …") {
            try await self.client.runUpdate(self.id)
            await self.loadUpdateStatus()
        }
    }
}
