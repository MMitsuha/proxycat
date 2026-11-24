import Library
import SwiftUI
import UIKit

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
                ProxyCatInlineErrorBanner(message: loadError)
            }
            nameCard
            editorCard
        }
        .proxyCatPage(bottomPadding: 12)
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
                    .accessibilityIdentifier("profileEditor.name")
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
                // UIKit-backed editor: SwiftUI's `TextEditor` resets its
                // internal scroll offset whenever the parent view rebuilds,
                // which happens on every keystroke here (live char/line
                // counts, validation invalidation). Wrapping `UITextView`
                // directly keeps the scroll position stable.
                YAMLCodeEditor(text: $yaml, isEditable: !isLoading && !isWorking)
                    .onChange(of: yaml) { _, _ in
                        invalidateValidation()
                    }
                    .accessibilityIdentifier("profileEditor.yaml")

                Text("Paste or type YAML here…")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
                    .opacity(!isLoading && yaml.isEmpty ? 1 : 0)

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
                .fill(ProxyCatUI.cardBackground)
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
        FormSaveToolbar(
            isWorking: isWorking,
            canSave: canSave,
            onCancel: { dismiss() },
            onSave: { Task { await save() } }
        )
        ToolbarItemGroup(placement: .keyboard) {
            Button {
                Task { await save() }
            } label: {
                Label("Save", systemImage: "checkmark.circle")
            }
            .disabled(!canSave)
            Spacer()
            Button("Done") {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil, from: nil, for: nil
                )
            }
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
        do {
            let text = try await ProfileStore.readYAML(of: profile)
            yaml = text
            originalYAML = text
        } catch {
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
