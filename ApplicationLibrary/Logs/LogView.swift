import Library
import SwiftUI

/// Streaming mihomo log viewer. The high-frequency visible list is kept
/// on a child observable so live log frames do not rebuild the navigation
/// toolbar while the stream is busy.
public struct LogView: View {
    @Environment(ExtensionEnvironment.self) private var environment
    @State private var model = LogViewModel()

    public init() {}

    public var body: some View {
        @Bindable var model = model
        return LogStreamList(
            stream: model.stream,
            query: model.searchText,
            isPaused: model.isPaused,
            isConnected: model.isConnected
        )
        .navigationTitle("Logs")
        .onAppear { model.bind(to: environment) }
        .onDisappear { model.detach() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                SavedLogsLink()
                LogPauseButton(isPaused: $model.isPaused)
                LogLevelMenu(selectedLevel: $model.selectedLevel)
                LogActionsMenu(
                    onCopy: { model.copyAllVisible() },
                    onClear: { model.clear() }
                )
            }
        }
        .searchable(text: $model.searchText, prompt: "Search logs")
        .alert("Copied", isPresented: $model.justCopied) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("\(model.lastCopyCount) lines copied to clipboard.")
        }
    }
}

// MARK: - Toolbar

private struct SavedLogsLink: View {
    var body: some View {
        NavigationLink {
            SavedLogsView()
        } label: {
            Image(systemName: "archivebox")
                .accessibilityLabel("Saved Logs")
                .accessibilityIdentifier("logs.saved")
        }
    }
}

private struct LogPauseButton: View {
    @Binding var isPaused: Bool

    var body: some View {
        Button {
            isPaused.toggle()
        } label: {
            Image(systemName: isPaused ? "play.circle" : "pause.circle")
                .accessibilityLabel(isPaused ? "Resume" : "Pause")
                .accessibilityIdentifier("logs.pause")
        }
    }
}

private struct LogLevelMenu: View {
    @Binding var selectedLevel: LogLevel

    var body: some View {
        Menu {
            Picker("Filter Level", selection: $selectedLevel) {
                ForEach(LogLevel.allCases) { lvl in
                    Label(lvl.displayName, systemImage: lvl.symbolName)
                        .tag(lvl)
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .accessibilityLabel("Log Level")
                .accessibilityIdentifier("logs.level")
        }
    }
}

private struct LogActionsMenu: View {
    var onCopy: () -> Void
    var onClear: () -> Void

    var body: some View {
        Menu {
            Button(action: onCopy) {
                Label("Copy All", systemImage: "doc.on.clipboard")
            }
            Button(role: .destructive, action: onClear) {
                Label("Clear", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel("Actions")
                .accessibilityIdentifier("logs.actions")
        }
    }
}

// MARK: - Stream list

private struct LogStreamList: View {
    @Bindable var stream: LogStreamData
    let query: String
    let isPaused: Bool
    let isConnected: Bool

    var body: some View {
        Group {
            if stream.visible.isEmpty {
                emptyState
            } else {
                logList
            }
        }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(stream.visible) { entry in
                    LogRow(entry: entry, query: query)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        .id(entry.id)
                }
            }
            .listStyle(.plain)
            .accessibilityIdentifier("logs.list")
            .onChange(of: stream.visible.last?.id) { _, newID in
                guard let id = newID, !isPaused else { return }
                // Skipping the animation here: under a busy stream (every
                // 100ms after coalescing) the previous animation is still
                // running when the next scrollTo arrives, which produces
                // a juddery half-step. An immediate snap reads as smooth.
                proxy.scrollTo(id, anchor: .bottom)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if !isConnected {
            ContentUnavailableView(localizedTitle: "Service not started", systemImage: "powerplug.portrait")
        } else if !query.isEmpty {
            ContentUnavailableView(
                localizedTitle: "No matching logs",
                systemImage: "magnifyingglass",
                localizedDescription: "Try another search term."
            )
        } else {
            ContentUnavailableView(localizedTitle: "No logs yet", systemImage: "doc.text")
        }
    }
}

private struct LogRow: View {
    let entry: LogEntry
    let query: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label(entry.level.displayName, systemImage: entry.level.symbolName)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(color(for: entry.level))
                    .labelStyle(.titleAndIcon)
                    .fixedSize()

                Spacer(minLength: 8)

                Text(entry.timestamp, format: .dateTime.hour().minute().second())
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }

            Text(highlighted(entry.message, query: query))
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: return .gray
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        case .silent: return .secondary
        }
    }

    private func highlighted(_ text: String, query: String) -> AttributedString {
        var attr = AttributedString(text)
        guard !query.isEmpty else { return attr }
        let lower = text.lowercased()
        let needle = query.lowercased()
        var search = lower.startIndex
        while let range = lower.range(of: needle, range: search ..< lower.endIndex) {
            if let attrRange = Range<AttributedString.Index>(range, in: attr) {
                attr[attrRange].backgroundColor = .yellow.opacity(0.45)
                attr[attrRange].inlinePresentationIntent = .stronglyEmphasized
            }
            search = range.upperBound
        }
        return attr
    }
}
