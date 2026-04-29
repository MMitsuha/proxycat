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
    @FocusState private var editorFocused: Bool

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
        VStack(spacing: 0) {
            if let loadError {
                loadErrorBanner(loadError)
            }
            nameRow
            Divider()
            editor
            Divider()
            statusBar
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task { loadInitial() }
        .alert("Save failed", isPresented: .constant(saveError != nil)) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    // MARK: - Subviews

    private func loadErrorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.red.opacity(0.12))
    }

    private var nameRow: some View {
        HStack {
            Text("Name")
                .foregroundStyle(.secondary)
            TextField("Profile name", text: $name)
                .multilineTextAlignment(.trailing)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
        }
        .padding(.horizontal)
        .padding(.vertical, 11)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var editor: some View {
        TextEditor(text: $yaml)
            .focused($editorFocused)
            .font(.system(.caption, design: .monospaced))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .scrollContentBackground(.hidden)
            .background(Color(.systemBackground))
            .overlay(alignment: .topLeading) {
                if yaml.isEmpty {
                    Text("Paste or type YAML here…")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: yaml) { validation = .pristine }
    }

    private var statusBar: some View {
        HStack(alignment: .firstTextBaseline) {
            ProfileValidationFooter(
                validation: validation,
                pristineHint: "Tap **Validate** before saving."
            )
            .font(.caption)
            Spacer(minLength: 12)
            Text("\(yaml.count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
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
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") { editorFocused = false }
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
