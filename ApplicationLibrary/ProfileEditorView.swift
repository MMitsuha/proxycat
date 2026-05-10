import Library
import SwiftUI

/// In-app YAML editor for creating and editing local profiles. The single
/// Save action validates with mihomo and writes only after parsing succeeds.
public struct ProfileEditorView: View {
    public enum Mode: Equatable {
        case create
        case edit(Profile)
    }

    @Environment(ProfileStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private let mode: Mode

    @State private var name: String
    @State private var originalName: String
    @State private var yaml: String
    @State private var originalYAML: String?
    @State private var validation: ProfileValidation = .pristine
    @State private var validatedYAML: ValidatedProfileYAML?
    @State private var isWorking = false
    @State private var saveError: String?
    @State private var loadError: String?
    @State private var isLoading: Bool
    @FocusState private var editorFocused: Bool

    public init(mode: Mode) {
        self.mode = mode
        switch mode {
        case .create:
            let initialName = "New Profile"
            _name = State(initialValue: initialName)
            _originalName = State(initialValue: initialName)
            _yaml = State(initialValue: "")
            _originalYAML = State(initialValue: "")
            _isLoading = State(initialValue: false)
        case let .edit(profile):
            _name = State(initialValue: profile.name)
            _originalName = State(initialValue: profile.name)
            _yaml = State(initialValue: "")
            _originalYAML = State(initialValue: nil)
            _isLoading = State(initialValue: true)
        }
    }

    public var body: some View {
        VStack(spacing: ProxyCatUI.pageSpacing) {
            if let loadError {
                loadErrorBanner(loadError)
            }
            nameCard
            editorCard
        }
        .padding(.horizontal, ProxyCatUI.pageHorizontalPadding)
        .padding(.top, ProxyCatUI.pageTopPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color(uiColor: .systemGroupedBackground))
        .safeAreaInset(edge: .bottom) {
            statusBar
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task { await loadInitial() }
        .errorAlert($saveError, title: "Save failed")
    }

    // MARK: - Subviews

    private func loadErrorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, ProxyCatUI.cardPadding)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: ProxyCatUI.cardCornerRadius, style: .continuous)
                    .fill(Color.red.opacity(0.12))
            )
    }

    private var nameCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            ProxyCatMetricHeader(title: "Profile", systemImage: "doc.text", tint: .accentColor)
            HStack(spacing: 12) {
                Text("Name")
                    .foregroundStyle(.secondary)
                TextField("Profile name", text: $name)
                    .multilineTextAlignment(.trailing)
                    .font(.body.weight(.medium))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .disabled(isWorking)
            }
        }
        .proxyCatCard()
    }

    private var editorCard: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                ProxyCatMetricHeader(title: "YAML", systemImage: "curlybraces.square", tint: .blue)
                Spacer(minLength: 8)
                editorStat("\(lineCount)", systemImage: "list.number", label: "lines")
                editorStat("\(yaml.count)", systemImage: "textformat.size", label: "chars")
            }
            .padding(.horizontal, ProxyCatUI.cardPadding)
            .padding(.vertical, 10)

            Divider()

            ZStack(alignment: .topLeading) {
                TextEditor(text: $yaml)
                    .focused($editorFocused)
                    .font(.system(.caption, design: .monospaced))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 4)
                    .disabled(isLoading || isWorking)
                    .onChange(of: yaml) { _, _ in
                        invalidateValidation()
                    }

                if !isLoading, yaml.isEmpty {
                    Text("Paste or type YAML here…")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .allowsHitTesting(false)
                }

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(uiColor: .systemBackground))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: ProxyCatUI.cardCornerRadius, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: ProxyCatUI.cardCornerRadius, style: .continuous)
                .fill(Color(uiColor: .secondarySystemGroupedBackground))
        )
    }

    private func editorStat(_ value: String, systemImage: String, label: LocalizedStringKey) -> some View {
        Label {
            Text(value)
                .font(.caption2.monospacedDigit())
            Text(label)
                .font(.caption2)
        } icon: {
            Image(systemName: systemImage)
        }
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
    }

    private var statusBar: some View {
        HStack(alignment: .center, spacing: 10) {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
            }
            ProfileValidationFooter(
                validation: validation,
                pristineHint: "Save validates with mihomo before writing."
            )
            .font(.caption)
            .lineLimit(2)

            Spacer(minLength: 10)

            Label(hasChanges ? "Edited" : "Saved", systemImage: hasChanges ? "pencil" : "checkmark.circle")
                .font(.caption2)
                .foregroundStyle(hasChanges ? Color.secondary : Color.green)
        }
        .padding(.horizontal, ProxyCatUI.pageHorizontalPadding)
        .padding(.vertical, 9)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button("Cancel") { dismiss() }
                .disabled(isWorking)
        }
        ToolbarItem(placement: .topBarTrailing) {
            if isWorking {
                ProgressView()
            } else {
                Button {
                    Task { await save() }
                } label: {
                    Label("Save", systemImage: "checkmark.circle")
                }
                .disabled(!canSave)
            }
        }
        ToolbarItemGroup(placement: .keyboard) {
            Button {
                Task { await save() }
            } label: {
                Label("Save", systemImage: "checkmark.circle")
            }
            .disabled(!canSave)
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

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var lineCount: Int {
        guard !yaml.isEmpty else { return 0 }
        return yaml.reduce(1) { count, character in
            character == "\n" ? count + 1 : count
        }
    }

    private var hasChanges: Bool {
        switch mode {
        case .create:
            return !yaml.isEmpty || trimmedName != originalName
        case .edit:
            guard let originalYAML else {
                return !yaml.isEmpty || trimmedName != originalName
            }
            return yaml != originalYAML || trimmedName != originalName
        }
    }

    private var canSave: Bool {
        guard !isLoading, !isWorking, !trimmedName.isEmpty else { return false }
        guard !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if case .failed = validation { return false }
        return hasChanges
    }

    /// Reads the YAML off disk on a background queue. Synchronously reading
    /// on the main actor would freeze the UI for large configs.
    private func loadInitial() async {
        guard case let .edit(profile) = mode else { return }
        let fileName = profile.fileName
        let result: Result<String, Error> = await Task.detached(priority: .userInitiated) {
            let url = FilePath.profilesDirectory.appendingPathComponent(fileName)
            do {
                return .success(try String(contentsOf: url, encoding: .utf8))
            } catch {
                return .failure(error)
            }
        }.value
        switch result {
        case let .success(text):
            yaml = text
            originalYAML = text
        case let .failure(error):
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func invalidateValidation() {
        validation = .pristine
        validatedYAML = nil
    }

    @MainActor
    private func validatedDraft() async -> ValidatedProfileYAML? {
        if let validatedYAML, validatedYAML.content == yaml {
            return validatedYAML
        }
        return await validateCurrentYAML()
    }

    @MainActor
    private func validateCurrentYAML() async -> ValidatedProfileYAML? {
        let submittedYAML = yaml
        guard !submittedYAML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            validatedYAML = nil
            validation = .failed(String(localized: "YAML is empty.", bundle: .main))
            return nil
        }

        do {
            let validated = try await ProfileStore.validateYAML(submittedYAML)
            guard yaml == submittedYAML else { return nil }
            validatedYAML = validated
            validation = .ok
            return validated
        } catch {
            guard yaml == submittedYAML else { return nil }
            validatedYAML = nil
            validation = .failed(error.localizedDescription)
            return nil
        }
    }

    @MainActor
    private func save() async {
        guard canSave else { return }
        isWorking = true
        defer { isWorking = false }

        guard let validated = await validatedDraft() else {
            if case let .failed(message) = validation {
                saveError = message
            }
            return
        }

        let finalName = trimmedName
        do {
            switch mode {
            case .create:
                try await store.importYAML(validated, name: finalName)
            case let .edit(profile):
                try await store.updateContent(of: profile, validatedYAML: validated, name: finalName)
            }
            originalName = finalName
            originalYAML = validated.content
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
