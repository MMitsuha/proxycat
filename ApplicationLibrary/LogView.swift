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
/// Patterned on sing-box-for-apple's LogView/LogViewModel. Uses an opt-in
/// "max visible" cap so SwiftUI's diffing stays fast under long sessions.
public struct LogView: View {
    @EnvironmentObject private var environment: ExtensionEnvironment
    @StateObject private var model: LogViewModel

    public init() {
        _model = StateObject(wrappedValue: LogViewModel())
    }

    public var body: some View {
        LogViewBody(model: model)
            .navigationTitle("Logs")
            .onAppear { model.bind(to: environment) }
            .onDisappear { model.unbind() }
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    savedLogsLink
                    pauseButton
                    levelMenu
                    actionsMenu
                }
            }
            .searchable(text: $model.searchText, prompt: "Search logs")
            .alert("Copied", isPresented: $model.justCopied) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("\(model.lastCopyCount) line\(model.lastCopyCount == 1 ? "" : "s") on the clipboard.")
            }
    }

    private var savedLogsLink: some View {
        NavigationLink {
            SavedLogsView()
        } label: {
            Image(systemName: "archivebox")
                .accessibilityLabel("Saved Logs")
        }
    }

    private var pauseButton: some View {
        Button {
            model.isPaused.toggle()
        } label: {
            Image(systemName: model.isPaused ? "play.circle" : "pause.circle")
                .accessibilityLabel(model.isPaused ? "Resume" : "Pause")
        }
    }

    private var levelMenu: some View {
        Menu {
            Picker("Filter Level", selection: $model.selectedLevel) {
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

    private var actionsMenu: some View {
        Menu {
            Button {
                model.copyAllVisible()
            } label: {
                Label("Copy All", systemImage: "doc.on.clipboard")
            }
            Button(role: .destructive) {
                model.clear()
            } label: {
                Label("Clear", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel("Actions")
        }
    }
}

private struct LogViewBody: View {
    @ObservedObject var model: LogViewModel

    var body: some View {
        Group {
            if model.visible.isEmpty {
                emptyState
            } else {
                logList
            }
        }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(model.visible) { entry in
                    LogRow(entry: entry, query: model.searchText)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                        .id(entry.id)
                }
            }
            .listStyle(.plain)
            .onChange(of: model.visible.last?.id) { _, newID in
                guard let id = newID, !model.isPaused else { return }
                withAnimation(.linear(duration: 0.1)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(model.isConnected ? String(localized: "No matching logs") : String(localized: "Service not started"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
    @Published var visible: [LogEntry] = []
    @Published var isConnected: Bool = false
    @Published var justCopied: Bool = false
    @Published var lastCopyCount: Int = 0

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
        self.environment = environment
        commandClient = environment.commandClient
        searchText = environment.logSearchText

        guard let client = commandClient else { return }
        // The gRPC connection is owned by ExtensionEnvironment now —
        // no per-view connect() needed. We only enable the host-side
        // log buffer while this view is visible, so a session that
        // never visits the Logs tab doesn't accumulate any log entries.
        client.enableLogBuffering()

        let debouncedSearch = $searchText
            .debounce(for: .milliseconds(250), scheduler: RunLoop.main)
            .removeDuplicates()

        Publishers.CombineLatest3(
            client.$logs,
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
        // if unbind() is called. With the weak sink the cycle is gone
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

    func unbind() {
        environment?.logSearchText = searchText
        commandClient?.disableLogBuffering()
        bag.removeAll()
    }

    func clear() {
        commandClient?.clearLogs()
        visible.removeAll()
    }

    /// Copy every line currently passing the active level + search filter.
    func copyAllVisible() {
        let text = visible.map { entry -> String in
            "[\(entry.level.displayName)] \(entry.message)"
        }.joined(separator: "\n")
        UIPasteboard.general.string = text
        lastCopyCount = visible.count
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

        let needle = query.lowercased()
        let filtered = source.filter { entry in
            entry.level.rawValue >= cutoff.rawValue &&
                (needle.isEmpty || entry.message.lowercased().contains(needle))
        }
        if filtered.count <= Self.maxVisible {
            visible = filtered
        } else {
            visible = Array(filtered.suffix(Self.maxVisible))
        }
    }
}
