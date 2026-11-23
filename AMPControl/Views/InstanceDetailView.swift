import SwiftUI

/// One instance: server control, console, players and the plugin sections
/// this AMP installation supports.
struct InstanceDetailView: View {
    @State private var model: InstanceDetailViewModel

    init(instance: AMPInstance, client: AMPClient, toasts: ToastCenter) {
        _model = State(
            initialValue: InstanceDetailViewModel(
                instance: instance, client: client, toasts: toasts))
    }

    var body: some View {
        VStack(spacing: 0) {
            DetailTabBar(tabs: model.tabs, selection: $model.selectedTab)
            if let error = model.error {
                pollingError(error)
            }
            tabContent(model.selectedTab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(model.instance.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if let status = model.status {
                    StateBadge(state: status.state)
                }
            }
        }
        .task { await model.run() }
        .dialogs(model.dialogs)
    }

    private func pollingError(_ error: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
            Text(error)
                .font(.subheadline)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Erneut") { Task { await model.poll() } }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.18))
    }

    @ViewBuilder private func tabContent(_ tab: DetailTab) -> some View {
        if let error = model.tabErrors[tab] {
            ErrorMessage(text: error) { await model.reload(tab) }
        } else {
            switch tab {
            case .overview: OverviewTab(model: model)
            case .console: ConsoleTab(model: model)
            case .users: UsersTab(model: model)
            case .backups: BackupsTab(model: model)
            case .files: FilesTab(model: model)
            case .settings: SettingsTab(model: model)
            case .tasks: TasksTab(model: model)
            case .events: EventsTab(model: model)
            case .updates: UpdatesTab(model: model)
            }
        }
    }
}

extension DetailTab {
    var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .console: "terminal"
        case .users: "person.2"
        case .backups: "externaldrive.badge.timemachine"
        case .files: "folder"
        case .settings: "slider.horizontal.3"
        case .tasks: "clock"
        case .events: "bell"
        case .updates: "arrow.down.circle"
        }
    }
}

/// Horizontally scrolling tab strip below the navigation bar.
private struct DetailTabBar: View {
    let tabs: [DetailTab]
    @Binding var selection: DetailTab

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabs) { tab in
                        tabButton(tab)
                            .id(tab)
                    }
                }
            }
            .accessibilityIdentifier("detail-tabs")
            .onChange(of: selection) { _, tab in
                withAnimation { proxy.scrollTo(tab, anchor: .center) }
            }
        }
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func tabButton(_ tab: DetailTab) -> some View {
        let selected = tab == selection
        return Button {
            selection = tab
        } label: {
            VStack(spacing: 4) {
                Image(systemName: tab.systemImage)
                    .font(.body)
                    .frame(height: 22)
                Text(tab.label)
                    .font(.caption)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)
            .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
                    .frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("tab-\(tab.rawValue)")
    }
}

/// Shows `content` once a value is there; until then a spinner while loading.
private struct Loadable<Value, Content: View>: View {
    let value: Value?
    let loading: Bool
    @ViewBuilder let content: (Value) -> Content

    var body: some View {
        if let value {
            content(value)
        } else {
            Group {
                if loading {
                    ProgressView()
                } else {
                    Text("Wird geladen…")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Overview

private struct OverviewTab: View {
    let model: InstanceDetailViewModel

    var body: some View {
        Loadable(value: model.status, loading: true) { status in
            let state = status.state
            let busy = model.isBusy(.server)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(state.color)
                            .frame(width: 16, height: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(state.label)
                                .font(.headline)
                            if !status.uptime.isEmpty && state.isRunning {
                                Text(verbatim: "Laufzeit: \(status.uptime)")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .card()

                    ForEach(status.metrics) { metric in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(metric.label)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text(metric.valueText)
                                    .font(.subheadline)
                            }
                            ProgressView(value: metric.fraction)
                        }
                        .card()
                    }

                    FlowLayout(lineSpacing: 12) {
                        Button("Starten", systemImage: "play.fill") {
                            Task { await model.startServer() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || !state.isStopped)

                        Button("Stoppen", systemImage: "stop.fill") {
                            Task { await model.stopServer() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(busy || state.isStopped)

                        Button("Neustarten", systemImage: "arrow.clockwise") {
                            Task { await model.restartServer() }
                        }
                        .buttonStyle(.bordered)
                        .disabled(busy || !state.isRunning)

                        Button("Kill", systemImage: "xmark.octagon") {
                            Task { await model.killServer() }
                        }
                        .buttonStyle(.bordered)
                        .tint(.red)
                        .disabled(busy || state.isStopped)
                    }
                    .padding(.top, 8)
                }
                .padding(16)
            }
        }
    }
}

// MARK: - Console

private struct ConsoleTab: View {
    let model: InstanceDetailViewModel
    @State private var input = ""
    @State private var sending = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if model.console.isEmpty {
                    Text("Noch keine Ausgabe.")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.54))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    // Anchored at the bottom to stay on the newest line.
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(model.console) { line in
                                Text(Self.format(line.entry))
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(8)
                    }
                    .defaultScrollAnchor(.bottom)
                }
            }
            .background(Color(red: 0.118, green: 0.118, blue: 0.118))

            HStack(spacing: 8) {
                TextField("Befehl eingeben …", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .onSubmit { send() }
                    .accessibilityIdentifier("console-input")
                Button("Senden", systemImage: "paperplane.fill") { send() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderedProminent)
                    .disabled(sending)
            }
            .padding(8)
            .background(.bar)
        }
    }

    private func send() {
        let message = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if message.isEmpty || sending { return }
        sending = true
        Task {
            if await model.sendConsole(message) { input = "" }
            sending = false
        }
    }

    private static func format(_ entry: ConsoleEntry) -> AttributedString {
        var line = AttributedString()
        if let timestamp = entry.timestamp {
            var time = AttributedString(AMPDate.clockTime(timestamp) + " ")
            time.swiftUI.foregroundColor = .white.opacity(0.38)
            line += time
        }
        if !entry.source.isEmpty {
            var source = AttributedString("[\(entry.source)] ")
            source.swiftUI.foregroundColor = Color(red: 0.25, green: 0.77, blue: 1)
            line += source
        }
        var contents = AttributedString(entry.contents)
        contents.swiftUI.foregroundColor =
            entry.type.lowercased().contains("error")
            ? Color(red: 1, green: 0.32, blue: 0.32) : .white
        line += contents
        return line
    }
}

// MARK: - Players

private struct UsersTab: View {
    let model: InstanceDetailViewModel

    var body: some View {
        Loadable(value: model.users, loading: true) { users in
            List(users, id: \.self) { user in
                HStack(spacing: 12) {
                    Text(String(user.prefix(1)).isEmpty ? "?" : String(user.prefix(1)))
                        .font(.headline)
                        .frame(width: 36, height: 36)
                        .background(Color.accentColor.opacity(0.2), in: Circle())
                    Text(user)
                }
            }
            .overlay {
                if users.isEmpty {
                    ContentUnavailableView("Niemand online.", systemImage: "person.2.slash")
                }
            }
            .refreshable { await model.loadUsers() }
        }
    }
}

// MARK: - Backups

private struct BackupsTab: View {
    let model: InstanceDetailViewModel

    var body: some View {
        Loadable(value: model.backups, loading: model.isLoading(.backups)) { backups in
            let busy = model.isBusy(.backups)
            List {
                Section {
                    Button("Backup erstellen", systemImage: "externaldrive.badge.plus") {
                        Task { await model.createBackup() }
                    }
                    .disabled(busy)
                }
                Section {
                    ForEach(backups) { backup in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(backup.name)
                                Text(
                                    [backup.createdAt ?? "", backup.sizeLabel]
                                        .filter { !$0.isEmpty }
                                        .joined(separator: " • ")
                                )
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Wiederherstellen", systemImage: "arrow.counterclockwise") {
                                Task { await model.restoreBackup(backup) }
                            }
                            Button("Löschen", systemImage: "trash") {
                                Task { await model.deleteBackup(backup) }
                            }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .disabled(busy)
                    }
                } footer: {
                    if backups.isEmpty { Text("Keine Backups vorhanden.") }
                }
            }
            .refreshable { await model.loadBackups() }
        }
    }
}

// MARK: - Files

private struct FilesTab: View {
    let model: InstanceDetailViewModel

    var body: some View {
        Loadable(value: model.files, loading: model.isLoading(.files)) { files in
            let busy = model.isBusy(.files)
            List {
                Section {
                    Button("Ordner erstellen", systemImage: "folder.badge.plus") {
                        Task { await model.createFolder() }
                    }
                    .disabled(busy)
                }
                Section {
                    ForEach(files) { file in
                        HStack(spacing: 12) {
                            Image(systemName: file.isDirectory ? "folder.fill" : "doc")
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(file.name)
                                Text(
                                    [file.path, file.sizeLabel]
                                        .filter { !$0.isEmpty }
                                        .joined(separator: " • ")
                                )
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !file.isDirectory {
                                Button("Umbenennen", systemImage: "pencil") {
                                    Task { await model.renameFile(file) }
                                }
                                Button("Löschen", systemImage: "trash") {
                                    Task { await model.deleteFile(file) }
                                }
                            }
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .disabled(busy)
                    }
                } footer: {
                    if files.isEmpty { Text("Keine Dateien gefunden.") }
                }
            }
            .refreshable { await model.loadFiles() }
        }
    }
}

// MARK: - Settings

private struct SettingsTab: View {
    let model: InstanceDetailViewModel

    var body: some View {
        Loadable(value: model.settings, loading: model.isLoading(.settings)) { settings in
            let busy = model.isBusy(.settings)
            List(settings) { setting in
                let editable = !busy && !setting.readOnly
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(setting.displayName)
                        if !setting.description.isEmpty {
                            Text(setting.description)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Text(Self.value(of: setting))
                            .font(.footnote)
                            .lineLimit(2)
                        if setting.key != setting.displayName {
                            Text(setting.key)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    Spacer()
                    Button("Bearbeiten", systemImage: "pencil") {
                        Task { await model.editSetting(setting) }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .disabled(!editable)
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if editable { Task { await model.editSetting(setting) } }
                }
            }
            .overlay {
                if settings.isEmpty {
                    ContentUnavailableView(
                        "Keine Settings gefunden.", systemImage: "slider.horizontal.3")
                }
            }
            .refreshable { await model.loadSettings() }
        }
    }

    /// The value in bold, followed by its type.
    private static func value(of setting: SettingEntry) -> AttributedString {
        var value = AttributedString(setting.value.isEmpty ? "(leer)" : setting.value)
        value.swiftUI.font = .footnote.weight(.semibold)
        if setting.type.isEmpty { return value }
        var type = AttributedString(" • \(setting.type)")
        type.swiftUI.foregroundColor = .secondary
        return value + type
    }
}

// MARK: - Schedule

private struct TasksTab: View {
    let model: InstanceDetailViewModel

    var body: some View {
        Loadable(value: model.tasks, loading: model.isLoading(.tasks)) { tasks in
            List(tasks) { task in
                Toggle(
                    isOn: Binding(
                        get: { task.enabled },
                        set: { _ in Task { await model.toggleTask(task) } })
                ) {
                    HStack(spacing: 12) {
                        Image(systemName: "clock")
                            .foregroundStyle(task.enabled ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(task.name)
                            Text(
                                [task.description, task.trigger]
                                    .filter { !$0.isEmpty }
                                    .joined(separator: " • ")
                            )
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
                .disabled(model.isBusy(.tasks))
            }
            .overlay {
                if tasks.isEmpty {
                    ContentUnavailableView("Keine Tasks vorhanden.", systemImage: "clock")
                }
            }
            .refreshable { await model.loadTasks() }
        }
    }
}

// MARK: - Events

private struct EventsTab: View {
    let model: InstanceDetailViewModel

    var body: some View {
        Loadable(value: model.events, loading: model.isLoading(.events)) { events in
            List(Array(events.enumerated()), id: \.offset) { _, event in
                HStack(spacing: 12) {
                    Circle()
                        .fill(Self.color(for: event.severity))
                        .frame(width: 12, height: 12)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.message)
                            .font(.subheadline)
                        Text(
                            [event.timestamp.map { AMPDate.clockTime($0) } ?? "", event.severity]
                                .filter { !$0.isEmpty }
                                .joined(separator: " • ")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .overlay {
                if events.isEmpty {
                    ContentUnavailableView("Keine Einträge.", systemImage: "bell.slash")
                }
            }
            .refreshable { await model.loadEvents() }
        }
    }

    private static func color(for severity: String) -> Color {
        switch severity.lowercased() {
        case "error", "critical": .red
        case "warning": .orange
        default: Color(red: 0.38, green: 0.49, blue: 0.55)
        }
    }
}

// MARK: - Game server update

private struct UpdatesTab: View {
    let model: InstanceDetailViewModel

    var body: some View {
        Loadable(value: model.updateStatus, loading: model.isLoading(.updates)) { status in
            let state = status.state
            let updating = state == .updating
            let canUpdate = state.isStopped && state != .undefined
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 12) {
                        Image(systemName: updating ? "arrow.down.circle" : "info.circle")
                            .font(.title2)
                            .foregroundStyle(state.color)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(
                                updating
                                    ? "Spielserver wird aktualisiert"
                                    : "Spielserver aktualisieren"
                            )
                            .font(.headline)
                            Text(verbatim: "Status: \(state.label)")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .card()

                    Text(
                        canUpdate
                            ? "AMP aktualisiert die Serverdateien aus der konfigurierten Quelle."
                            : updating
                                ? "Die Aktualisierung läuft."
                                : "Stoppe den Server vor einer Aktualisierung."
                    )

                    Button("Update starten", systemImage: "arrow.down.circle") {
                        Task { await model.runUpdate() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy(.update) || !canUpdate)
                }
                .padding(16)
            }
            .refreshable { await model.loadUpdateStatus() }
        }
    }
}
