import SwiftUI

/// All instances of the ADS with their status, metrics and start/stop controls.
struct InstancesView: View {
    @State private var model: InstancesViewModel
    @Binding private var path: [Route]

    init(app: AppModel, client: AMPClient, path: Binding<[Route]>) {
        _model = State(
            initialValue: InstancesViewModel(
                client: client,
                toasts: app.toasts,
                isActive: { [weak app] in app?.client === client }
            ))
        _path = path
    }

    var body: some View {
        content
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Instanzen")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Einstellungen", systemImage: "gearshape") {
                        path.append(.settings)
                    }
                }
            }
            .refreshable { await model.load() }
            .task { await model.autoRefresh() }
            .dialogs(model.dialogs)
    }

    @ViewBuilder private var content: some View {
        if let instances = model.instances {
            if instances.isEmpty {
                message("Keine Instanzen gefunden.", systemImage: "tray")
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if let error = model.error {
                            Label(error, systemImage: "exclamationmark.triangle")
                                .padding(16)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    Color.red.opacity(0.15),
                                    in: RoundedRectangle(cornerRadius: 12))
                        }
                        ForEach(instances) { instance in
                            InstanceTile(
                                instance: instance,
                                starting: model.pendingStart(instance),
                                onOpen: { open(instance) },
                                onToggle: { Task { await model.toggle(instance) } }
                            )
                        }
                    }
                    .padding(8)
                }
            }
        } else if let error = model.error {
            message(error, systemImage: "icloud.slash", showsRetry: true)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func open(_ instance: AMPInstance) {
        Task {
            if await model.open(instance) { path.append(.instance(instance)) }
        }
    }

    /// Scrollable so that pull-to-refresh works on empty and error states.
    private func message(_ text: String, systemImage: String, showsRetry: Bool = false)
        -> some View
    {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text(text)
                    .multilineTextAlignment(.center)
                if showsRetry {
                    Button("Erneut versuchen") { Task { await model.load() } }
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 32)
            .padding(.top, 112)
        }
    }
}

private struct InstanceTile: View {
    let instance: AMPInstance
    /// `nil` when idle, otherwise whether the instance is starting (or stopping).
    let starting: Bool?
    let onOpen: () -> Void
    let onToggle: () -> Void

    private var idle: Bool { starting == nil }

    private var processStatus: String {
        if let starting { return starting ? "Instanz startet …" : "Instanz stoppt …" }
        return "AMP-Instanz: \(instance.running ? "Läuft" : "Gestoppt")"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(instance.displayName)
                    .font(.headline)
                Text(instance.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            FlowLayout(spacing: 16) {
                Text(processStatus)
                if instance.running {
                    HStack(spacing: 4) {
                        Text("Server:")
                        StateBadge(state: instance.appState)
                    }
                }
            }
            .font(.subheadline)

            if instance.running, !instance.metrics.isEmpty {
                FlowLayout(spacing: 16, lineSpacing: 4) {
                    ForEach(instance.metrics) { metric in
                        Text(verbatim: "\(metric.label): \(metric.valueText)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            FlowLayout {
                Button(action: onToggle) {
                    HStack(spacing: 6) {
                        if idle {
                            Image(systemName: instance.running ? "stop.fill" : "play.fill")
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(instance.running ? "Instanz stoppen" : "Instanz starten")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!idle)
                .accessibilityIdentifier("toggle-\(instance.id)")

                if instance.running {
                    Button(action: onOpen) {
                        HStack(spacing: 4) {
                            Text("Server verwalten")
                            Image(systemName: "chevron.right")
                        }
                    }
                    .buttonStyle(.borderless)
                    .disabled(!idle)
                    .accessibilityIdentifier("manage-\(instance.id)")
                }
            }
        }
        .card()
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .onTapGesture { if idle { onOpen() } }
    }
}

#Preview("Instanzkarte – Zeilenumbruch") {
    if let instance = try? AMPInstance(json: [
        "InstanceID": "preview", "InstanceName": "Minecraft01",
        "FriendlyName": "Rumpelkammer", "Module": "Minecraft",
        "Running": true, "AppState": 35,
        "Metrics": [
            "CPU Usage": ["RawValue": 1, "Percent": 1, "Units": "%"],
            "Memory Usage": ["RawValue": 2182, "MaxValue": 28672, "Units": "MB"],
            "Active Users": ["RawValue": 0, "MaxValue": 10],
            "TPS": ["RawValue": 20, "MaxValue": 20, "Units": "TPS"],
        ],
    ]) {
        ScrollView {
            InstanceTile(instance: instance, starting: nil, onOpen: {}, onToggle: {})
                .padding(8)
        }
        .preferredColorScheme(.dark)
    }
}
