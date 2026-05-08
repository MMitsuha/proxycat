import Library
import SwiftUI

/// Downloads a profile YAML from a user-supplied URL, validates it with
/// mihomo's parser, and adds it to the profile store with `remoteURL` set
/// so it can later be refreshed in place.
///
/// Mirrors `ProfileEditorView`'s toolbar pattern: a Menu with **Validate**
/// and **Save** actions and a footer that surfaces the parser result.
public struct ProfileDownloadView: View {
    @EnvironmentObject private var store: ProfileStore
    @Environment(\.dismiss) private var dismiss

    @State private var urlText: String = ""
    @State private var name: String = ""
    @State private var nameEdited: Bool = false
    @State private var downloadedYAML: String?
    @State private var validation: ProfileValidation = .pristine
    @State private var isWorking: Bool = false
    @State private var saveError: String?

    public init() {}

    public var body: some View {
        Form {
            Section("URL") {
                TextField("https://example.com/sub", text: $urlText)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onChange(of: urlText) { _, newValue in
                        if !nameEdited, let derived = Self.deriveName(from: newValue) {
                            name = derived
                        }
                        invalidate()
                    }
            }

            Section {
                // Custom setter so the auto-derive in the URL onChange
                // (which assigns `name` directly) doesn't flip
                // `nameEdited` and prematurely lock further auto-fills.
                // Only writes that come through this Binding — i.e. user
                // typing in this field — count as a manual edit.
                TextField("Profile name", text: Binding(
                    get: { name },
                    set: { newValue in
                        name = newValue
                        nameEdited = true
                    }
                ))
                .autocorrectionDisabled()
            } header: {
                Text("Name")
            } footer: {
                ProfileValidationFooter(
                    validation: validation,
                    pristineHint: "Tap **Validate** to download and parse with mihomo before saving."
                )
            }
        }
        .navigationTitle("Download Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
                    .disabled(isWorking)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await validate() }
                    } label: {
                        Label("Validate", systemImage: "checkmark.shield")
                    }
                    .disabled(!hasValidURL || isWorking)
                    Button {
                        Task { await save() }
                    } label: {
                        Label("Save", systemImage: "tray.and.arrow.down")
                    }
                    .disabled(!canSave)
                } label: {
                    if isWorking {
                        ProgressView()
                    } else {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .errorAlert($saveError, title: "Save failed")
    }

    private var hasValidURL: Bool { parsedURL != nil }

    private var canSave: Bool {
        guard hasValidURL, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if case .failed = validation { return false }
        // Suppress the Save tap while a previous validate/save is still
        // running. Without this guard the menu item stays enabled the
        // whole time the spinner is up, and a second tap kicks off
        // another fetch+import that ends up importing the same YAML
        // twice.
        if isWorking { return false }
        return true
    }

    private func invalidate() {
        downloadedYAML = nil
        validation = .pristine
    }

    /// Fetch + parser-validate the configured URL. Doesn't manage
    /// `isWorking` — caller owns the spinner so a single guard can span
    /// validate-then-import inside `save()` without the inner defer
    /// flipping the flag back off mid-flight.
    @MainActor
    private func performValidation() async {
        guard let url = parsedURL else {
            validation = .failed(ProfileError.invalidURL.localizedDescription)
            return
        }
        // Snapshot the URL string the user submitted. If it changes during
        // the fetch+parse round-trip, the async result belongs to old
        // input — applying it would briefly show "valid" for content the
        // user is no longer pointing at.
        let submittedURLText = urlText
        do {
            let yaml = try await RemoteProfileFetcher.fetch(url)
            try await LibmihomoBridge.validateAsync(yaml: Data(yaml.utf8))
            guard urlText == submittedURLText else { return }
            downloadedYAML = yaml
            validation = .ok
        } catch {
            guard urlText == submittedURLText else { return }
            downloadedYAML = nil
            validation = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func validate() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        await performValidation()
    }

    @MainActor
    private func save() async {
        // One guard for the entire save flow — validate + import. The
        // previous shape called `validate()` (which managed `isWorking`
        // itself), so `isWorking` was false during the import phase and
        // a second tap could queue another fetch+import for the same
        // YAML. Holding the flag across both phases here closes that gap.
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        await performValidation()
        guard case .ok = validation, let yaml = downloadedYAML, let url = parsedURL else {
            if case let .failed(msg) = validation { saveError = msg }
            return
        }
        do {
            let trimmedName = name.trimmingCharacters(in: .whitespaces)
            try await store.importYAML(yaml, name: trimmedName, remoteURL: url)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private var parsedURL: URL? {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    private static func deriveName(from text: String) -> String? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
              let host = url.host,
              !host.isEmpty
        else { return nil }
        let last = url.deletingPathExtension().lastPathComponent
        if last.isEmpty || last == "/" { return host }
        return last
    }
}
