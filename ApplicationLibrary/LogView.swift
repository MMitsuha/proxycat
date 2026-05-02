import Combine
import Library
import SwiftUI
import UIKit

/// Streaming log viewer with the user-requested controls:
///   • Log level filter — defaults to `.warning`, persisted across launches
///     in `RuntimeSettings.shared` (which writes settings.json in the App
///     Group). The Go core re-reads that file on every reload, so a
///     change here propagates to mihomo without going through any
///     dedicated IPC. The YAML profile's `log-level:` key is
///     intentionally ignored.
///   • Debounced search box
///   • "Copy All" — copies every line currently visible under the active
///     filter to UIPasteboard.
///
/// Patterned on sing-box-for-apple's LogView/LogViewModel. Two structural
/// notes worth keeping in mind when editing:
///
///   1. The streaming list (`visible`) lives on a *separate*
///      `LogStreamData` ObservableObject. The toolbar / searchable / alert
///      live on the parent `LogViewModel`. That split keeps the toolbar's
///      `Menu` views from rebuilding 10×/sec under heavy log traffic — the
///      visible blink the user reported on the navigation bar was caused
///      by the entire `LogView.body` reevaluating on every appended line.
///   2. The host-side log buffer is enabled lazily on first appearance
///      and intentionally NOT disabled on disappearance, so navigating
///      away from the Logs tab does not throw away accumulated lines.
public struct LogView: View {
    @EnvironmentObject private var environment: ExtensionEnvironment
    @StateObject private var model: LogViewModel

    public init() {
        _model = StateObject(wrappedValue: LogViewModel())
    }

    public var body: some View {
        LogStreamList(
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
    @ObservedObject var stream: LogStreamData
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

    private var emptyState: some View {
        ContentUnavailableView(
            isConnected ? "No matching logs" : "Service not started",
            systemImage: "doc.text.magnifyingglass"
        )
    }
}

private struct LogRow: View {
    let entry: LogEntry
    let query: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.level.symbolName)
                .foregroundStyle(color(for: entry.level))
                .font(.caption2.weight(.semibold))
                .frame(width: 14)
            Text(highlighted(entry.message, query: query))
                .font(.system(.caption2, design: .monospaced))
                .textSelection(.enabled)
        }
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
@MainActor
final class LogStreamData: ObservableObject {
    @Published var visible: [LogEntry] = []
}

@MainActor
final class LogViewModel: ObservableObject {
    @Published var searchText: String = ""
    /// Mirror of `RuntimeSettings.shared.logLevel`, exposed as a
    /// `LogLevel` enum so the picker binding stays type-safe. Two-way:
    /// changes from the picker write back into RuntimeSettings (which
    /// persists + nudges the extension), and external changes to
    /// RuntimeSettings flow back here through the Combine pipe set up
    /// in `bind`.
    @Published var selectedLevel: LogLevel
    @Published var isPaused: Bool = false
    @Published var isConnected: Bool = false
    @Published var justCopied: Bool = false
    @Published var lastCopyCount: Int = 0

    let stream = LogStreamData()

    static let maxVisible = 800

    private weak var commandClient: CommandClient?
    private var environment: ExtensionEnvironment?
    private let settings = RuntimeSettings.shared
    private var bag = Set<AnyCancellable>()
    private var pausedSnapshot: [LogEntry]?

    init() {
        self.selectedLevel = LogLevel(rawValue: RuntimeSettings.shared.logLevel) ?? .warning
    }

    func bind(to environment: ExtensionEnvironment) {
        // onAppear can fire again when the user swipes back to the Logs
        // tab — guard against double-subscription.
        guard bag.isEmpty else { return }
        self.environment = environment
        commandClient = environment.commandClient
        searchText = environment.logSearchText

        guard let client = commandClient else { return }
        // The host-side buffer is started on first visit and intentionally
        // never stopped while the model is alive: the user expects logs
        // to persist across navigation, the buffer is bounded by
        // `CommandClient.maxLogBuffer`, and memory-pressure events still
        // drop everything via `ExtensionEnvironment.handleMemoryPressure`.
        client.enableLogBuffering()

        // Coalesce log bursts. A busy mihomo session emits dozens of
        // frames per second; without a throttle each one would invalidate
        // the SwiftUI graph and rebuild the toolbar's Menu/Picker, which
        // the user observed as a navigation-bar blink. 100 ms (≈10 Hz)
        // keeps the feed feeling live while making the redraw cost
        // bounded. `latest: true` ensures we always emit the freshest
        // buffer at the end of each interval.
        let throttledLogs = client.$logs
            .throttle(for: .milliseconds(100), scheduler: RunLoop.main, latest: true)

        let debouncedSearch = $searchText
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .removeDuplicates()

        Publishers.CombineLatest3(
            throttledLogs,
            $selectedLevel,
            debouncedSearch
        )
        .combineLatest($isPaused)
        .receive(on: RunLoop.main)
        .sink { [weak self] tuple, paused in
            let (logs, picked, query) = tuple
            self?.recompute(
                logs: logs,
                cutoff: picked,
                query: query,
                paused: paused
            )
        }
        .store(in: &bag)

        // sink + [weak self] instead of assign(to:on:) — the latter
        // captures self strongly, and the resulting AnyCancellable is
        // stored in self.bag, forming a retain cycle that only breaks
        // if detach() is called. With the weak sink the cycle is gone
        // even if the view is torn down without onDisappear firing.
        client.$isConnected
            .receive(on: RunLoop.main)
            .sink { [weak self] connected in
                self?.isConnected = connected
            }
            .store(in: &bag)

        // Picker → RuntimeSettings. Writing here triggers the shared
        // store's persist + post path, which ExtensionEnvironment
        // observes and turns into a `reload` so mihomo picks up the new
        // level. dropFirst skips the initial value emission so we
        // don't immediately re-write what we loaded in init().
        $selectedLevel
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] level in
                self?.settings.logLevel = level.rawValue
            }
            .store(in: &bag)

        // RuntimeSettings → picker. If something else mutates the
        // shared store (e.g. a future macOS companion app, or an
        // import/export action), reflect it back into the UI.
        settings.$logLevel
            .receive(on: RunLoop.main)
            .compactMap { LogLevel(rawValue: $0) }
            .removeDuplicates()
            .sink { [weak self] level in
                guard let self, level != self.selectedLevel else { return }
                self.selectedLevel = level
            }
            .store(in: &bag)
    }

    /// Called from `onDisappear`. Persists the search term and tears
    /// down the Combine pipes so we stop allocating filtered arrays
    /// while invisible — but the underlying `commandClient` buffer is
    /// left running so the user finds their history intact when they
    /// return to the Logs tab. The visible list is also kept so the
    /// re-appearance is instantaneous (it gets refreshed once the new
    /// pipeline emits).
    func detach() {
        environment?.logSearchText = searchText
        bag.removeAll()
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
