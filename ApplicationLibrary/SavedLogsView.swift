import Library
import SwiftUI
import UIKit

/// Browser for the per-session log files the Network Extension drops
/// in the App Group container. The extension opens a fresh
/// `mihomo-YYYYMMDD-HHMMSS.log` for Go-side logs and
/// `proxycat-YYYYMMDD-HHMMSS.log` for Swift-side logs whenever it starts
/// the tunnel; this view lists them newest-first with size + modified
/// date and opens files through an in-app UTF-8 text viewer.
public struct SavedLogsView: View {
    @State private var model = SavedLogsViewModel()

    public init() {}

    public var body: some View {
        @Bindable var model = model
        return Group {
            if model.entries.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(model.entries) { entry in
                        NavigationLink {
                            SavedLogFileView(entry: entry)
                        } label: {
                            row(for: entry)
                        }
                        .contextMenu {
                            ShareLink(item: entry.url) {
                                Label("Share File", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                    .onDelete { indices in
                        model.delete(at: indices)
                    }
                }
                .listStyle(.plain)
                .refreshable { model.reload() }
            }
        }
        .navigationTitle("Saved Logs")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        model.reload()
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    if !model.entries.isEmpty {
                        Button(role: .destructive) {
                            model.confirmDeleteAll = true
                        } label: {
                            Label("Delete All", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("Actions")
                }
            }
        }
        // .alert (modal) instead of .confirmationDialog: iOS 26 renders
        // confirmationDialog as a popover whose full-screen dismiss
        // region eats a rapid second tap on the trigger, making Delete
        // All look like it needs two taps. See SettingsView.
        .alert(
            "Delete all saved logs?",
            isPresented: $model.confirmDeleteAll
        ) {
            Button("Delete All", role: .destructive) { model.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Single concrete sentence — avoids the previous %lld/%@
            // duplicate-key mess in the string catalog and matches a
            // Chinese form that doesn't need a plural marker either.
            Text("This deletes \(model.entries.count) saved log files. The active session is preserved.")
        }
        .onAppear { model.reload() }
    }

    private func row(for entry: SavedLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(entry.displayDate)
                    .font(.body)
                if entry.isActive {
                    Text("LIVE")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.red.opacity(0.85), in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            HStack(spacing: 8) {
                Text(entry.fileName)
                    .font(.system(.caption2, design: .monospaced))
                Spacer()
                Text(ByteFormatter.fileSize(entry.size))
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            localizedTitle: "No saved logs yet",
            systemImage: "doc.text.magnifyingglass",
            localizedDescription: "A new file is created each time the tunnel connects."
        )
    }
}

// MARK: - Text viewer

private struct SavedLogFileView: View {
    let entry: SavedLogEntry

    @State private var model = SavedLogFileViewModel()

    var body: some View {
        Group {
            if let document = model.document {
                SavedLogTextList(document: document)
            } else if let error = model.loadError {
                ContentUnavailableView {
                    Label("Could not open log", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") {
                        Task { await model.load(path: entry.url.path, force: true) }
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(entry.fileName)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: entry.id) {
            await model.load(path: entry.url.path)
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: entry.url) {
                    Image(systemName: "square.and.arrow.up")
                }
                Button {
                    Task { await model.load(path: entry.url.path, force: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .disabled(model.isLoading)
            }
        }
    }
}

private struct SavedLogTextList: View {
    let document: SavedLogDocument

    private var lineNumberWidth: CGFloat {
        max(28, CGFloat(String(max(document.lines.count, 1)).count) * 8 + 10)
    }

    var body: some View {
        List {
            Section {
                HStack {
                    Label(ByteFormatter.fileSize(document.size), systemImage: "doc.text")
                    Spacer()
                    Text("\(document.lines.count) lines")
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if document.replacedInvalidUTF8 {
                    Label("Some invalid UTF-8 bytes were replaced.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section {
                ForEach(document.lines) { line in
                    SavedLogLineRow(line: line, lineNumberWidth: lineNumberWidth)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                }
            }
        }
        .listStyle(.plain)
    }
}

private struct SavedLogLineRow: View {
    let line: SavedLogLine
    let lineNumberWidth: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(line.number)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: lineNumberWidth, alignment: .trailing)
                .textSelection(.disabled)

            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
    }
}

@MainActor @Observable
private final class SavedLogFileViewModel {
    var document: SavedLogDocument?
    var loadError: String?
    var isLoading = false

    func load(path: String, force: Bool = false) async {
        guard force || document == nil else { return }
        isLoading = true
        loadError = nil
        do {
            let loaded = try await Task.detached(priority: .userInitiated) {
                try SavedLogFileReader.load(path: path)
            }.value
            document = loaded
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Model

@MainActor @Observable
final class SavedLogsViewModel {
    var entries: [SavedLogEntry] = []
    var confirmDeleteAll: Bool = false

    func reload() {
        let dir = FilePath.logsDirectory
        let active = FilePath.activeLogFilePaths()
        // Apply user retention policy before listing so the user
        // sees a fresh state. No-op when policy is .keepAll.
        FilePath.pruneSavedLogs(
            policy: HostSettingsStore.shared.logRetention,
            activePaths: active
        )
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let mapped: [SavedLogEntry] = urls.compactMap { url in
            guard FilePath.isManagedSavedLogFile(url),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else { return nil }
            return SavedLogEntry(
                url: url,
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast,
                isActive: active.contains(url.path)
            )
        }
        // Newest first.
        entries = mapped.sorted { $0.modified > $1.modified }
    }

    func delete(at offsets: IndexSet) {
        let fm = FileManager.default
        for index in offsets {
            let entry = entries[index]
            // Don't let the user delete the file the extension is
            // currently writing to — bbolt-style on iOS the unlink
            // succeeds but the inode keeps growing in the dark.
            if entry.isActive { continue }
            try? fm.removeItem(at: entry.url)
        }
        reload()
    }

    func deleteAll() {
        let fm = FileManager.default
        for entry in entries where !entry.isActive {
            try? fm.removeItem(at: entry.url)
        }
        reload()
    }
}

// MARK: - Entry

struct SavedLogEntry: Identifiable, Hashable {
    let url: URL
    let size: Int64
    let modified: Date
    let isActive: Bool

    var id: String { url.path }
    var fileName: String { url.lastPathComponent }
    var displayDate: String { Self.dateFormatter.string(from: modified) }

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .medium
        return df
    }()
}

// MARK: - Share sheet bridge

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
