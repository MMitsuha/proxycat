import Library
import Observation
import SwiftUI
import UIKit

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

// MARK: - View model

/// Carries only the high-frequency `visible` list. Held as a child object
/// of `LogViewModel` so list updates do NOT invalidate the parent
/// `LogView.body` (and therefore do not rebuild the toolbar).
@MainActor @Observable
final class LogStreamData {
    var visible: [LogEntry] = []
}

@MainActor @Observable
final class LogViewModel {
    var searchText: String = ""
    /// Mirror of `RuntimeSettings.shared.logLevel`, exposed as a
    /// `LogLevel` enum so the picker binding stays type-safe. Two-way:
    /// the didSet writes back into RuntimeSettings (which persists +
    /// nudges the extension); external changes to RuntimeSettings flow
    /// back here through the Observed.values pipe set up in `bind`.
    var selectedLevel: LogLevel {
        didSet {
            guard loaded, selectedLevel != oldValue else { return }
            settings.logLevel = selectedLevel.rawValue
        }
    }
    var isPaused: Bool = false
    var isConnected: Bool = false
    var justCopied: Bool = false
    var lastCopyCount: Int = 0

    @ObservationIgnored let stream = LogStreamData()

    @ObservationIgnored static let maxVisible = 800

    @ObservationIgnored private weak var commandClient: CommandClient?
    @ObservationIgnored private var environment: ExtensionEnvironment?
    @ObservationIgnored private let settings = RuntimeSettings.shared
    @ObservationIgnored private var pipelineTasks: [Task<Void, Never>] = []
    @ObservationIgnored private var pausedSnapshot: [LogEntry]?
    @ObservationIgnored private var loaded = false

    init() {
        self.selectedLevel = LogLevel(rawValue: RuntimeSettings.shared.logLevel) ?? .warning
        self.loaded = true
    }

    func bind(to environment: ExtensionEnvironment) {
        // onAppear can fire again when the user swipes back to the Logs
        // tab — guard against double-subscription.
        guard pipelineTasks.isEmpty else { return }
        self.environment = environment
        commandClient = environment.commandClient
        searchText = environment.logSearchText

        guard let client = commandClient else { return }
        // Keep the live log stream tied to the visible Logs tab. iOS can
        // suspend the host app in the background; leaving a log gRPC stream
        // open against a suspended reader risks backpressuring the extension.
        // CommandClient keeps already-buffered logs until Clear or memory
        // pressure, so short navigation away does not blank the view.
        client.enableLogBuffering()

        // Single observation pipeline for recompute. Touching the four
        // inputs (logs, selectedLevel, searchText, isPaused) inside the
        // read closure registers them with withObservationTracking, so
        // a change to any one re-emits a fresh tuple. @Observable's
        // tick-coalescing collapses bursts within the same runloop tick
        // and SwiftUI's render cadence further caps redraw frequency,
        // so the explicit Combine throttle/debounce is no longer
        // necessary — only views that actually read the affected
        // property invalidate, and the toolbar reads only selectedLevel
        // / isPaused / isConnected, none of which churn on log frames.
        pipelineTasks.append(Task { @MainActor [weak self, weak client] in
            guard let self, let client else { return }
            for await inputs in Observed.values({ [weak self, weak client] () -> RecomputeInputs in
                guard let self, let client else { return .empty }
                return RecomputeInputs(
                    logs: client.logs,
                    cutoff: self.selectedLevel,
                    query: self.searchText,
                    paused: self.isPaused
                )
            }) {
                self.recompute(
                    logs: inputs.logs,
                    cutoff: inputs.cutoff,
                    query: inputs.query,
                    paused: inputs.paused
                )
            }
        })

        // client.isConnected → self.isConnected
        pipelineTasks.append(Task { @MainActor [weak self, weak client] in
            guard let client else { return }
            for await connected in Observed.values({ [weak client] in client?.isConnected ?? false }) {
                self?.isConnected = connected
            }
        })

        // RuntimeSettings → picker. If something else mutates the
        // shared store (e.g. a future macOS companion app, or an
        // import/export action), reflect it back into the UI. dropFirst
        // skips the initial replay we already loaded in init().
        let settings = self.settings
        pipelineTasks.append(Task { @MainActor [weak self] in
            for await raw in Observed.values({ settings.logLevel }).dropFirst() {
                guard let self,
                      let level = LogLevel(rawValue: raw),
                      level != self.selectedLevel
                else { continue }
                self.selectedLevel = level
            }
        })
    }

    /// Called from `onDisappear`. Persists the search term and tears
    /// down the observation pipes so we stop allocating filtered arrays
    /// while invisible. The live gRPC log stream is closed, but
    /// `CommandClient` keeps its in-memory log buffer so the user finds
    /// their history intact when they return to the Logs tab. The visible
    /// list is also kept so the re-appearance is instantaneous (it gets
    /// refreshed once the new pipeline emits).
    func detach() {
        environment?.logSearchText = searchText
        for task in pipelineTasks { task.cancel() }
        pipelineTasks.removeAll()
        commandClient?.disableLogBuffering()
    }

    deinit {
        for task in pipelineTasks { task.cancel() }
        let client = commandClient
        Task { @MainActor in
            client?.disableLogBuffering()
        }
    }

    func clear() {
        commandClient?.clearLogs()
        stream.visible.removeAll()
        pausedSnapshot = nil
    }

    /// Copy every line currently passing the active level + search filter.
    func copyAllVisible() {
        let entries = stream.visible
        let text = entries.map { entry -> String in
            "[\(entry.level.displayName)] \(entry.message)"
        }.joined(separator: "\n")
        UIPasteboard.general.string = text
        lastCopyCount = entries.count
        justCopied = true
    }

    private func recompute(
        logs: [LogEntry],
        cutoff: LogLevel,
        query: String,
        paused: Bool
    ) {
        let source: [LogEntry]
        if paused {
            if pausedSnapshot == nil { pausedSnapshot = logs }
            source = pausedSnapshot ?? logs
        } else {
            pausedSnapshot = nil
            source = logs
        }

        let cutoffRaw = cutoff.rawValue
        let needle = query.lowercased()
        let hasNeedle = !needle.isEmpty
        var filtered: [LogEntry] = []
        filtered.reserveCapacity(min(source.count, Self.maxVisible))
        for entry in source {
            guard entry.level.rawValue >= cutoffRaw else { continue }
            if hasNeedle, !entry.message.lowercased().contains(needle) { continue }
            filtered.append(entry)
        }
        if filtered.count > Self.maxVisible {
            filtered.removeFirst(filtered.count - Self.maxVisible)
        }
        stream.visible = filtered
    }
}

private struct RecomputeInputs: Sendable {
    let logs: [LogEntry]
    let cutoff: LogLevel
    let query: String
    let paused: Bool

    static let empty = RecomputeInputs(logs: [], cutoff: .silent, query: "", paused: false)
}
