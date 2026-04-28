import Library
import SwiftUI
import UIKit

/// Browser for the per-session log files the Network Extension drops
/// in the App Group container. The extension opens a fresh
/// `mihomo-YYYYMMDD-HHMMSS.log` whenever it starts the tunnel; this
/// view lists them newest-first with size + modified date, and pushes
/// to a detail view that renders the file contents.
public struct SavedLogsView: View {
    @StateObject private var model = SavedLogsViewModel()

    public init() {}

    public var body: some View {
        Group {
            if model.entries.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(model.entries) { entry in
                        NavigationLink {
                            SavedLogDetailView(entry: entry)
                        } label: {
                            row(for: entry)
                        }
                    }
                    .onDelete { indices in
                        model.delete(at: indices)
                    }
                }
                .listStyle(.plain)
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
        .confirmationDialog(
            "Delete all saved logs?",
            isPresented: $model.confirmDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) { model.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes every \(model.entries.count) file and cannot be undone. The active session, if any, is preserved.")
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
                Text(SavedLogEntry.byteFormatter.string(fromByteCount: entry.size))
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("No saved logs yet")
                .foregroundStyle(.secondary)
            Text("A new file is created each time the tunnel connects.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Detail view

struct SavedLogDetailView: View {
    let entry: SavedLogEntry

    @State private var content: String = ""
    @State private var loading: Bool = true
    @State private var loadError: String?
    @State private var showShareSheet = false

    var body: some View {
        Group {
            if loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let loadError {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundStyle(.orange)
                    Text(loadError)
                        .multilineTextAlignment(.center)
                        .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(content)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
            }
        }
        .navigationTitle(entry.displayDate)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        UIPasteboard.general.string = content
                    } label: {
                        Label("Copy", systemImage: "doc.on.clipboard")
                    }
                    .disabled(content.isEmpty)
                    Button {
                        showShareSheet = true
                    } label: {
                        Label("Share File", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("Actions")
                }
            }
        }
        .sheet(isPresented: $showShareSheet) {
            ShareSheet(items: [entry.url])
        }
        .task(id: entry.id) {
            await load()
        }
    }

    private func load() async {
        loading = true
        loadError = nil
        // Reading large files synchronously freezes the UI, so go to a
        // utility queue. Truncate to the last 1MB so we don't try to
        // render a multi-megabyte string in a single Text view.
        let url = entry.url
        let result: Result<String, Error> = await Task.detached(priority: .userInitiated) {
            do {
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                let limit: Int64 = 1_000_000
                if size <= limit {
                    let data = try Data(contentsOf: url)
                    return .success(String(decoding: data, as: UTF8.self))
                }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(size - limit))
                let tail = try handle.readToEnd() ?? Data()
                let header = "[truncated — showing last \(limit) of \(size) bytes]\n\n"
                return .success(header + String(decoding: tail, as: UTF8.self))
            } catch {
                return .failure(error)
            }
        }.value

        loading = false
        switch result {
        case let .success(text): content = text
        case let .failure(error): loadError = error.localizedDescription
        }
    }
}

// MARK: - Model

@MainActor
final class SavedLogsViewModel: ObservableObject {
    @Published var entries: [SavedLogEntry] = []
    @Published var confirmDeleteAll: Bool = false

    func reload() {
        let dir = FilePath.logsDirectory
        let active = LibmihomoBridge.currentLogFilePath()
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let mapped: [SavedLogEntry] = urls.compactMap { url in
            guard url.pathExtension == "log",
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true
            else { return nil }
            return SavedLogEntry(
                url: url,
                size: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast,
                isActive: url.path == active
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

    static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()
}

// MARK: - Share sheet bridge

private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
