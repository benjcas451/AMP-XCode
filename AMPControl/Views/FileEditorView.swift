import SwiftUI
import UIKit

/// A level of an NBT tag tree pushed onto the editor's navigation stack.
struct NBTPath: Hashable {
    /// The child index to follow on each level, starting at the root.
    let indices: [Int]
    let title: String
}

/// Edits one file of an instance: text files as text, Minecraft's NBT
/// files as a tree of tags.
struct FileEditorView: View {
    let model: FileEditorViewModel
    @State private var path: [NBTPath] = []

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle(model.file.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Schließen") { Task { await model.close() } }
                            .disabled(model.isSaving)
                            .accessibilityIdentifier("file-editor-close")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        SaveButton(model: model)
                    }
                }
                .navigationDestination(for: NBTPath.self) { destination in
                    NBTNodeView(model: model, path: destination.indices)
                        .navigationTitle(destination.title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                SaveButton(model: model)
                            }
                        }
                }
        }
        .task { await model.load() }
        .dialogs(model.dialogs)
        .toastOverlay(model.toasts)
        .interactiveDismissDisabled()
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Wird geladen…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ErrorMessage(text: message) { await model.load() }
        case .ready:
            if model.textDocument != nil {
                TextFileEditor(model: model)
            } else {
                NBTNodeView(model: model, path: [])
            }
        }
    }
}

private struct SaveButton: View {
    let model: FileEditorViewModel

    var body: some View {
        if model.isSaving {
            ProgressView()
        } else {
            Button("Speichern") { Task { await model.save() } }
                .disabled(!model.canSave)
                .accessibilityIdentifier("file-editor-save")
        }
    }
}

// MARK: - Text

private struct TextFileEditor: View {
    @Bindable var model: FileEditorViewModel

    var body: some View {
        VStack(spacing: 0) {
            Text(model.details)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .accessibilityIdentifier("file-editor-details")
            Divider()
            CodeTextView(text: $model.text)
        }
    }
}

/// A plain text view for code and configuration files: fixed-width font
/// and none of the keyboard's corrections, which would for instance turn
/// the quotation marks of a JSON file into typographic ones.
private struct CodeTextView: UIViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.delegate = context.coordinator
        view.font = .monospacedSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.backgroundColor = .clear
        view.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.accessibilityIdentifier = "file-editor-text"
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.text = $text
        if view.text != text { view.text = text }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
        }
    }
}

// MARK: - NBT

/// The entries of one compound or list of an NBT file.
struct NBTNodeView: View {
    let model: FileEditorViewModel
    let path: [Int]

    var body: some View {
        if let value = model.nbtValue(at: path), let children = value.children {
            List {
                if path.isEmpty {
                    Section {
                        Text(model.details)
                            .font(.footnote)
                            .accessibilityIdentifier("file-editor-details")
                    } footer: {
                        Text(
                            "Ein laufender Server überschreibt Änderungen an seinen Weltdaten. "
                                + "Am besten vor dem Bearbeiten stoppen.")
                    }
                }
                Section {
                    ForEach(children) { child in
                        row(child)
                    }
                } footer: {
                    if children.isEmpty { Text("Keine Einträge.") }
                }
                Section {
                    addControl(for: value)
                }
            }
        } else {
            ContentUnavailableView(
                "Eintrag nicht mehr vorhanden", systemImage: "questionmark.folder")
        }
    }

    @ViewBuilder private func row(_ child: NBTChild) -> some View {
        Group {
            if child.value.isContainer {
                NavigationLink(
                    value: NBTPath(
                        indices: path + [child.index],
                        title: child.name.isEmpty ? child.value.type.label : child.name)
                ) {
                    NBTRowLabel(child: child)
                }
            } else {
                Button {
                    Task { await model.editValue(child, in: path) }
                } label: {
                    NBTRowLabel(child: child)
                }
                .tint(Color.primary)
            }
        }
        .accessibilityIdentifier("nbt-\(child.name)")
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Löschen", systemImage: "trash") {
                Task { await model.removeChild(child, from: path) }
            }
            .tint(Color.red)
        }
    }

    @ViewBuilder private func addControl(for value: NBTValue) -> some View {
        if case .list(let elementType, let items) = value, !items.isEmpty {
            // A list holds tags of one type only.
            Button("Eintrag hinzufügen", systemImage: "plus") {
                Task { await model.addChild(elementType, to: path) }
            }
            .accessibilityIdentifier("nbt-add")
        } else {
            Menu {
                ForEach(NBTType.creatable, id: \.self) { type in
                    Button(type.label) {
                        Task { await model.addChild(type, to: path) }
                    }
                }
            } label: {
                Label("Eintrag hinzufügen", systemImage: "plus")
            }
            .accessibilityIdentifier("nbt-add")
        }
    }
}

private struct NBTRowLabel: View {
    let child: NBTChild

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(child.name.isEmpty ? "(ohne Namen)" : child.name)
                Text(child.value.summary.isEmpty ? "(leer)" : child.value.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Text(child.value.type.label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
