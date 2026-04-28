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
    @State private var validation: Validation = .pristine
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
                TextField("Profile name", text: $name)
                    .autocorrectionDisabled()
                    .onChange(of: name) { _, _ in nameEdited = true }
            } header: {
                Text("Name")
            } footer: {
                validationFooter
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
                    .disabled(!hasValidURL)
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
        .alert("Save failed", isPresented: .constant(saveError != nil)) {
            Button("OK") { saveError = nil }
        } message: {
            Text(saveError ?? "")
        }
    }

    @ViewBuilder
    private var validationFooter: some View {
        switch validation {
        case .pristine:
            Text("Tap **Validate** to download and parse with mihomo before saving.")
        case .ok:
            Label("Configuration looks valid.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case let .failed(message):
            Label {
                Text(message)
                    .font(.caption.monospaced())
            } icon: {
                Image(systemName: "xmark.octagon.fill")
            }
            .foregroundStyle(.red)
        }
    }

    private var hasValidURL: Bool {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return false }
        return true
    }

    private var canSave: Bool {
        guard hasValidURL, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        if case .failed = validation { return false }
        return true
    }

    private func invalidate() {
        downloadedYAML = nil
        validation = .pristine
    }

    @MainActor
    private func validate() async {
        guard let url = parsedURL else {
            validation = .failed(ProfileError.invalidURL.localizedDescription)
            return
        }
        isWorking = true
        defer { isWorking = false }

        do {
            let yaml = try await RemoteProfileFetcher.fetch(url)
            let data = Data(yaml.utf8)
            try await Task.detached(priority: .userInitiated) {
                try LibmihomoBridge.validate(yaml: data)
            }.value
            downloadedYAML = yaml
            validation = .ok
        } catch {
            downloadedYAML = nil
            validation = .failed(error.localizedDescription)
        }
    }

    @MainActor
    private func save() async {
        // Re-fetch and re-validate before persisting in case the URL or
        // remote content changed since the user last tapped Validate.
        await validate()
        guard case .ok = validation, let yaml = downloadedYAML, let url = parsedURL else {
            if case let .failed(msg) = validation { saveError = msg }
            return
        }
        do {
            let trimmedName = name.trimmingCharacters(in: .whitespaces)
            try store.importYAML(yaml, name: trimmedName, remoteURL: url)
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

    private enum Validation: Equatable {
        case pristine
        case ok
        case failed(String)
    }
}
