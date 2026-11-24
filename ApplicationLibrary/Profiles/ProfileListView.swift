import Library
import SwiftUI
import UniformTypeIdentifiers

public struct ProfileListView: View {
    @Environment(ProfileStore.self) private var profileStore
    @State private var showImporter = false
    @State private var actionError: String?
    @State private var presentedSheet: EditorSheet?
    @State private var shareItem: ProfileShareItem?

    public init() {}

    public var body: some View {
        List {
            ForEach(profileStore.profiles) { profile in
                profileRow(profile)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        profileStore.setActive(profile)
                    }
                    .accessibilityIdentifier("profile.row.\(profile.id.uuidString)")
                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                        Button {
                            presentedSheet = .editing(profile)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
                        .tint(.blue)
                        Button {
                            presentedSheet = .mitm(profile)
                        } label: {
                            Label("MITM", systemImage: "shield.lefthalf.filled")
                        }
                        .tint(.indigo)
                        Button {
                            share(profile)
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                        .tint(.green)
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
        .overlay {
            if profileStore.profiles.isEmpty {
                ProxyCatEmptyState(
                    title: "No profiles",
                    systemImage: "doc.text",
                    description: "Import a YAML config or paste one in."
                )
            }
        }
        .accessibilityIdentifier("profiles.list")
        .navigationTitle("Profiles")
        .refreshable { await refreshAllRemote() }
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
                        .accessibilityLabel(Text("Add"))
                        .accessibilityIdentifier("profiles.add")
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
                Task {
                    do {
                        _ = try await profileStore.importYAML(from: url)
                    } catch {
                        actionError = error.localizedDescription
                    }
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
                case let .mitm(profile):
                    MitmProfileConfigView(profile: profile)
                case .downloading:
                    ProfileDownloadView()
                }
            }
        }
        .sheet(item: $shareItem) { item in
            ShareSheet(items: [item.url])
        }
        .errorAlert($actionError, title: "Action failed")
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

    private func share(_ profile: Profile) {
        do {
            shareItem = try ProfileShareItem(profile)
        } catch {
            actionError = error.localizedDescription
        }
    }

    /// Re-downloads every profile that has a `remoteURL`. Errors from
    /// individual refreshes are collected so a single failure doesn't
    /// abort the rest — the user sees the first failure in the alert
    /// and can swipe-refresh again to retry.
    private func refreshAllRemote() async {
        let remotes = profileStore.profiles.filter { $0.remoteURL != nil }
        guard !remotes.isEmpty else { return }
        var firstError: String?
        for profile in remotes {
            do {
                try await profileStore.refreshRemote(profile)
            } catch {
                if firstError == nil { firstError = error.localizedDescription }
            }
        }
        if let firstError {
            actionError = firstError
        }
    }

    @ViewBuilder
    private func profileRow(_ profile: Profile) -> some View {
        let isActive = profileStore.activeProfileID == profile.id
        HStack(spacing: 12) {
            ProxyCatIconTile(
                systemImage: profile.remoteURL == nil ? "doc.text" : "cloud",
                tint: isActive ? .accentColor : .secondary
            )
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
            if isActive {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private enum EditorSheet: Identifiable {
        case creating
        case downloading
        case editing(Profile)
        case mitm(Profile)

        var id: String {
            switch self {
            case .creating: return "creating"
            case .downloading: return "downloading"
            case let .editing(profile): return "editing-\(profile.id.uuidString)"
            case let .mitm(profile): return "mitm-\(profile.id.uuidString)"
            }
        }
    }
}
