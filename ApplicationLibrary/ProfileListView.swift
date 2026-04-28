import Library
import SwiftUI
import UniformTypeIdentifiers

public struct ProfileListView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @State private var showImporter = false
    @State private var importError: String?
    @State private var showInlineEditor = false

    public init() {}

    public var body: some View {
        List {
            if profileStore.profiles.isEmpty {
                ContentUnavailableView(
                    "No profiles",
                    systemImage: "doc.text",
                    description: Text("Import a YAML config or paste one in.")
                )
            }

            ForEach(profileStore.profiles) { profile in
                Button {
                    try? profileStore.setActive(profile)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                                .foregroundStyle(.primary)
                            if let url = profile.remoteURL {
                                Text(url.absoluteString)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        if profileStore.activeProfileID == profile.id {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.tint)
                        }
                    }
                }
                .swipeActions(allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        try? profileStore.delete(profile)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Profiles")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import YAML", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        showInlineEditor = true
                    } label: {
                        Label("Paste YAML", systemImage: "doc.text.below.ecg")
                    }
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [
                UTType(filenameExtension: "yaml") ?? .plainText,
                UTType(filenameExtension: "yml") ?? .plainText,
                .plainText,
            ],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                _ = url.startAccessingSecurityScopedResource()
                defer { url.stopAccessingSecurityScopedResource() }
                do {
                    let content = try String(contentsOf: url, encoding: .utf8)
                    try profileStore.importYAML(content, name: url.deletingPathExtension().lastPathComponent)
                } catch {
                    importError = error.localizedDescription
                }
            case let .failure(error):
                importError = error.localizedDescription
            }
        }
        .sheet(isPresented: $showInlineEditor) {
            InlineYAMLEditor { name, body in
                do {
                    try profileStore.importYAML(body, name: name)
                } catch {
                    importError = error.localizedDescription
                }
            }
        }
        .alert("Import failed", isPresented: .constant(importError != nil)) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
    }
}

private struct InlineYAMLEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = "New Profile"
    @State private var yaml: String = ""

    let onSave: (String, String) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Profile name", text: $name)
                }
                Section("YAML") {
                    TextEditor(text: $yaml)
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 240)
                }
            }
            .navigationTitle("New Profile")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        onSave(name, yaml)
                        dismiss()
                    }
                    .disabled(yaml.isEmpty || name.isEmpty)
                }
            }
        }
    }
}
