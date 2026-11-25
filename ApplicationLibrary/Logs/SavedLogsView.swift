import Library
import SwiftUI

/// Browser for the per-session log files the Network Extension drops
/// in the App Group container. The extension opens a fresh
/// `mihomo-YYYYMMDD-HHMMSS.log` for Go-side logs and
/// `proxycat-YYYYMMDD-HHMMSS.log` for Swift-side logs whenever it starts
/// the tunnel; this view lists them newest-first with size + the
/// session's start time (parsed from the filename — file mtime drifts
/// every write so it's a poor row title for the live file) and opens
/// each through an in-app UTF-8 text viewer.
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
                        .accessibilityIdentifier("savedLogs.row.\(entry.id)")
                        .contextMenu {
                            ShareLink(item: entry.url) {
                                Label("Share File", systemImage: "square.and.arrow.up")
                            }
                        }
                    }
                    .onDelete { indices in
                        Task { await model.delete(at: indices) }
                    }
                }
                .listStyle(.plain)
                .accessibilityIdentifier("savedLogs.list")
                .refreshable { await model.reload() }
            }
        }
        .navigationTitle("Saved Logs")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        Task { await model.reload() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    if model.deletableCount > 0 {
                        Button(role: .destructive) {
                            model.confirmDeleteAll = true
                        } label: {
                            Label("Delete All", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .accessibilityLabel("Actions")
                        .accessibilityIdentifier("savedLogs.actions")
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
            Button("Delete All", role: .destructive) {
                Task { await model.deleteAll() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes \(model.deletableCount) saved log files. The active session is preserved.")
        }
        .task { await model.reload() }
    }

    private func row(for entry: SavedLogFileInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(entry.startedAt, format: SavedLogsView.titleDateFormat)
                    .font(.body)
                if entry.isActive {
                    Text("LIVE")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.red.opacity(0.85), in: Capsule())
                        .foregroundStyle(.white)
                }
                Spacer()
                KindBadge(kind: entry.kind)
            }
            HStack(spacing: 8) {
                Text(entry.fileName)
                    .font(.system(.caption2, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(ByteFormatter.fileSize(entry.size))
                    .font(.caption2)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private var emptyState: some View {
        ProxyCatEmptyState(
            title: "No saved logs yet",
            systemImage: "doc.text.magnifyingglass",
            description: "A new file is created each time the tunnel connects."
        )
    }

    /// Row title uses `.dateTime` so SwiftUI picks up the user's
    /// locale + 12/24-hour preference automatically. Localized via
    /// the system catalog — no string in `Localizable.xcstrings`.
    static let titleDateFormat: Date.FormatStyle = .dateTime
        .year().month(.abbreviated).day()
        .hour().minute().second()
}

// MARK: - Kind badge

private struct KindBadge: View {
    let kind: SavedLogFileInfo.Kind

    var body: some View {
        ProxyCatBadge(
            text: kind.displayName,
            tint: kind.tint,
            font: .caption2.weight(.medium),
            verticalPadding: 1
        )
    }
}

private extension SavedLogFileInfo.Kind {
    var tint: Color {
        switch self {
        case .mihomo: return .blue
        case .proxycat: return .purple
        }
    }
}

// MARK: - Text viewer

private struct SavedLogFileView: View {
    let entry: SavedLogFileInfo

    @State private var model = SavedLogFileViewModel()

    var body: some View {
        Group {
            if let document = model.document {
                SavedLogTextList(document: document)
            } else if let error = model.loadError {
                if model.loadErrorIsRetryable {
                    ProxyCatLoadFailureView(message: error) {
                        Task { await model.load(path: entry.url.path, force: true) }
                    }
                } else {
                    ProxyCatLoadFailureView(message: error)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Title is the parsed session-start date, not the raw filename
        // — matches what the list row showed before the user tapped in
        // so the navigation doesn't feel like it's "renaming" the
        // entry between screens.
        .navigationTitle(Text(entry.startedAt, format: SavedLogsView.titleDateFormat))
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
