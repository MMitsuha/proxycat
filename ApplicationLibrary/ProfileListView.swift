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
            if profileStore.profiles.isEmpty {
                ContentUnavailableView(
                    localizedTitle: "No profiles",
                    systemImage: "doc.text",
                    localizedDescription: "Import a YAML config or paste one in."
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

    private struct ProfileShareItem: Identifiable {
        let id = UUID()
        let url: URL

        init(_ profile: Profile) throws {
            let source = FilePath.profilesDirectory.appendingPathComponent(profile.fileName)
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw ProfileShareError.missingFile
            }

            let exportDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("proxycat-profile-share", isDirectory: true)
            try FileManager.default.createDirectory(
                at: exportDirectory,
                withIntermediateDirectories: true
            )

            let destination = exportDirectory.appendingPathComponent(Self.fileName(for: profile))
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            url = destination
        }

        private static func fileName(for profile: Profile) -> String {
            let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
                .union(.newlines)
                .union(.controlCharacters)
            let sanitized = profile.name
                .components(separatedBy: invalid)
                .joined(separator: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let base = sanitized.isEmpty ? "profile" : sanitized
            return base.hasSuffix(".yaml") || base.hasSuffix(".yml") ? base : "\(base).yaml"
        }
    }

    private enum ProfileShareError: LocalizedError {
        case missingFile

        var errorDescription: String? {
            switch self {
            case .missingFile:
                return String(localized: "Profile file is missing.", bundle: .main)
            }
        }
    }
}
