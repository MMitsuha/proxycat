import Library
import SwiftUI

/// Downloads, validates, and saves a profile from a user-supplied URL.
/// The view owns only input and progress state; `ProfileStore.importRemote`
/// owns the fetch/validate/write pipeline so the URL path has one save path.
public struct ProfileDownloadView: View {
    @Environment(ProfileStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var urlText: String = ""
    @State private var name: String = ""
    @State private var nameEdited: Bool = false
    @State private var isSaving: Bool = false
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
                    }
                    .disabled(isSaving)
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
                .disabled(isSaving)
            } header: {
                Text("Name")
            } footer: {
                Text("Save downloads the profile, validates it with mihomo, then adds it. Nothing is written if validation fails.")
            }
        }
        .navigationTitle("Download Profile")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
                    .disabled(isSaving)
            }
            ToolbarItem(placement: .topBarTrailing) {
                if isSaving {
                    ProgressView()
                } else {
                    Button {
                        Task { await save() }
                    } label: {
                        Label("Save", systemImage: "tray.and.arrow.down")
                    }
                    .disabled(!canSave)
                }
            }
        }
        .errorAlert($saveError, title: "Save failed")
    }

    private var canSave: Bool {
        parsedURL != nil && !trimmedName.isEmpty && !isSaving
    }

    @MainActor
    private func save() async {
        guard !isSaving else { return }
        guard let url = parsedURL else {
            saveError = ProfileError.invalidURL.localizedDescription
            return
        }
        let finalName = trimmedName
        guard !finalName.isEmpty else {
            saveError = String(localized: "Profile name cannot be empty.")
            return
        }
        isSaving = true
        defer { isSaving = false }
        do {
            try await store.importRemote(from: url, name: finalName)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedURL: URL? {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return nil }
        return url
    }

    private static func deriveName(from text: String) -> String? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host,
              !host.isEmpty
        else { return nil }
        let last = url.deletingPathExtension().lastPathComponent
        if last.isEmpty || last == "/" { return host }
        return last
    }
}
