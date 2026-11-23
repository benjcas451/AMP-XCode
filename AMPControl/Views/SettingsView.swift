import SwiftUI

/// Server URL, user and password, with a connection test.
struct SettingsView: View {
    /// Shown as start screen when nothing is configured yet.
    let firstRun: Bool
    /// Called after new settings were saved.
    let onSaved: () -> Void

    private let app: AppModel
    @State private var model: SettingsViewModel
    @State private var showsPassword = false
    @FocusState private var focus: SettingsViewModel.Field?

    init(app: AppModel, firstRun: Bool, onSaved: @escaping () -> Void) {
        self.app = app
        self.firstRun = firstRun
        self.onSaved = onSaved
        _model = State(initialValue: SettingsViewModel(app: app))
    }

    var body: some View {
        Form {
            if firstRun {
                Section {
                    Text(
                        "Gib die Adresse deines AMP-Panels und deine Zugangsdaten ein. "
                            + "Die Daten werden verschlüsselt auf dem Gerät gespeichert.")
                }
            }

            Section {
                TextField(
                    "Server-URL", text: $model.url,
                    prompt: Text("https://amp.example.com oder http://192.168.1.10:8080")
                )
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.next)
                .focused($focus, equals: .url)
                .onSubmit { focus = .username }
                .accessibilityIdentifier("settings-url")
            } header: {
                Label("Server-URL", systemImage: "server.rack")
            } footer: {
                validationError(.url)
            }

            Section {
                TextField("Benutzer", text: $model.username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.next)
                    .focused($focus, equals: .username)
                    .onSubmit { focus = .password }
                    .accessibilityIdentifier("settings-username")
            } header: {
                Label("Benutzer", systemImage: "person")
            } footer: {
                validationError(.username)
            }

            Section {
                HStack {
                    Group {
                        if showsPassword {
                            TextField("Passwort", text: $model.password)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            SecureField("Passwort", text: $model.password)
                        }
                    }
                    .textContentType(.password)
                    .submitLabel(.done)
                    .focused($focus, equals: .password)
                    .onSubmit { save() }
                    .accessibilityIdentifier("settings-password")

                    Button(
                        showsPassword ? "Verbergen" : "Anzeigen",
                        systemImage: showsPassword ? "eye.slash" : "eye"
                    ) {
                        showsPassword.toggle()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                }
            } header: {
                Label("Passwort", systemImage: "lock")
            } footer: {
                validationError(.password)
            }

            Section {
                HStack(spacing: 12) {
                    Button {
                        Task { await model.test() }
                    } label: {
                        Label("Testen", systemImage: "dot.radiowaves.left.and.right")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("settings-test")

                    Button {
                        save()
                    } label: {
                        HStack(spacing: 6) {
                            if model.busy {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "square.and.arrow.down")
                            }
                            Text("Speichern")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("settings-save")
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } footer: {
                Text(
                    "Tipp: Lege in AMP einen eigenen Benutzer für die App an und "
                        + "nutze für den Zugriff von unterwegs HTTPS oder ein VPN.")
                    .padding(.top, 8)
            }

            if app.isConfigured && !firstRun {
                Section {
                    Button("Zugangsdaten löschen", systemImage: "trash", role: .destructive) {
                        Task { await model.clear() }
                    }
                }
            }
        }
        .disabled(model.busy)
        .navigationTitle(firstRun ? "AMP Control einrichten" : "Einstellungen")
        .navigationBarTitleDisplayMode(firstRun ? .large : .inline)
        .dialogs(model.dialogs)
    }

    private func save() {
        focus = nil
        Task {
            if await model.save() { onSaved() }
        }
    }

    @ViewBuilder private func validationError(_ field: SettingsViewModel.Field) -> some View {
        if let error = model.errors[field] {
            Text(error)
                .foregroundStyle(.red)
        }
    }
}
