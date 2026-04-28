import Library
import SwiftUI

/// In-app YAML editor with live validation.
///
/// Two modes:
///   • `.create` — typing a brand-new profile into an empty buffer.
///   • `.edit(profile)` — reading the existing YAML from disk and saving
///     changes back through `ProfileStore.updateContent`.
///
/// Validation runs through the gomobile-bound `LibmihomoBridge.validate`,
/// which delegates to mihomo's own `executor.ParseWithBytes`. We refuse
/// to save unless the YAML parses cleanly.
public struct ProfileEditorView: View {
    public enum Mode: Equatable {
        case create
        case edit(Profile)
    }

    @EnvironmentObject private var store: ProfileStore
    @Environment(\.dismiss) private var dismiss

    private let mode: Mode

    @State private var name: String
    @State private var yaml: String
    @State private var validation: ProfileValidation = .pristine
    @State private var isValidating = false
    @State private var saveError: String?
    @State private var loadError: String?

    public init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .create:
            _name = State(initialValue: "New Profile")
            _yaml = State(initialValue: "")
        case let .edit(profile):
            _name = State(initialValue: profile.name)
            _yaml = State(initialValue: "")
        }
    }

    public var body: some View {
        Form {
            if let loadError {
                Section {
                    Label(loadError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            Section("Name") {
                TextField("Profile name", text: $name)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }

            Section {
                TextEditor(text: $yaml)
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 320)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: yaml) {
                        validation = .pristine
                    }
            } header: {
                HStack {
                    Text("YAML")
                    Spacer()
                    Text("\(yaml.count) chars")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                ProfileValidationFooter(
                    validation: validation,
                    pristineHint: "Tap **Validate** before saving. Mihomo's parser will run on this YAML."
                )
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await validate() }
                    } label: {
                        Label("Validate", systemImage: "checkmark.shield")
                    }
                    Button {
                        Task { await save() }
                    } label: {
                        Label("Save", systemImage: "tray.and.arrow.down")
                    }
                    .disabled(!canSave)
                } label: {
                    if isValidating {
                        ProgressView()
                    } else {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task { loadInitial() }
        .alert("Save failed", isPresented: .constant(saveError != nil)) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - Logic

    private var title: String {
        switch mode {
        case .create: return String(localized: "New Profile")
        case .edit: return String(localized: "Edit Profile")
        }
    }

    private var canSave: Bool {
        guard !name.isEmpty, !yaml.isEmpty else { return false }
        if case .failed = validation { return false }
        return true
    }

    private func loadInitial() {
        guard case let .edit(profile) = mode else { return }
        do {
            yaml = try store.loadContent(of: profile)
        } catch {
            loadError = error.localizedDescription
        }
    }

    @MainActor
    private func validate() async {
        let data = Data(yaml.utf8)
        isValidating = true
        do {
            try await LibmihomoBridge.validateAsync(yaml: data)
            validation = .ok
        } catch {
            validation = .failed(error.localizedDescription)
        }
        isValidating = false
    }

    @MainActor
    private func save() async {
        // Always re-validate before persisting — the user may have typed
        // since their last manual Validate.
        await validate()
        if case let .failed(msg) = validation {
            saveError = msg
            return
        }
        do {
            switch mode {
            case .create:
                try store.importYAML(yaml, name: name)
            case let .edit(profile):
                try store.updateContent(of: profile, yaml: yaml)
                if profile.name != name {
                    var updated = profile
                    updated.name = name
                    try store.rename(updated)
                }
            }
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
