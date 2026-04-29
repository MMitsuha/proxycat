import Library
import SwiftUI
import UniformTypeIdentifiers

public struct ProfileListView: View {
    @EnvironmentObject private var profileStore: ProfileStore
    @EnvironmentObject private var environment: ExtensionEnvironment
    @State private var showImporter = false
    @State private var actionError: String?
    @State private var presentedSheet: EditorSheet?

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
                profileRow(profile)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        run { try profileStore.setActive(profile) }
                    }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            presentedSheet = .editing(profile)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                        if profile.remoteURL != nil {
                            Button {
                                refresh(profile)
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .tint(.orange)
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            run { try profileStore.delete(profile) }
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
                        presentedSheet = .downloading
                    } label: {
                        Label("Download from URL", systemImage: "arrow.down.circle")
                    }
                    Button {
                        presentedSheet = .creating
                    } label: {
                        Label("New / Paste YAML", systemImage: "doc.text.below.ecg")
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
                run {
                    let content = try String(contentsOf: url, encoding: .utf8)
                    try profileStore.importYAML(content, name: url.deletingPathExtension().lastPathComponent)
                }
            case let .failure(error):
                actionError = error.localizedDescription
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            NavigationStack {
                switch sheet {
                case .creating:
                    ProfileEditorView(mode: .create)
                case let .editing(profile):
                    ProfileEditorView(mode: .edit(profile))
                case .downloading:
                    ProfileDownloadView()
                }
            }
        }
        .alert("Action failed", isPresented: .constant(actionError != nil)) {
            Button("OK") { actionError = nil }
        } message: {
            Text(actionError ?? "")
        }
        .alert("Reload failed", isPresented: .constant(environment.reloadError != nil)) {
            Button("OK") { environment.reloadError = nil }
        } message: {
            Text(environment.reloadError ?? "")
        }
    }

    /// Runs a throwing block and surfaces any thrown error in the alert.
    /// Replaces a sea of `try?` calls that previously swallowed disk and
    /// IPC errors silently, leaving the user with no feedback when a
    /// swipe action failed.
    private func run(_ block: () throws -> Void) {
        do { try block() } catch { actionError = error.localizedDescription }
    }

    private func refresh(_ profile: Profile) {
        Task {
            do {
                try await profileStore.refreshRemote(profile)
            } catch {
                actionError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private func profileRow(_ profile: Profile) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).foregroundStyle(.primary)
                if let url = profile.remoteURL {
                    Text(url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let date = profile.lastUpdated {
                    Text("Edited \(date.formatted(.relative(presentation: .named)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if profileStore.activeProfileID == profile.id {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
            }
        }
    }

    private enum EditorSheet: Identifiable {
        case creating
        case downloading
        case editing(Profile)

        var id: String {
            switch self {
            case .creating: return "creating"
            case .downloading: return "downloading"
            case let .editing(profile): return "editing-\(profile.id.uuidString)"
            }
        }
    }
}
