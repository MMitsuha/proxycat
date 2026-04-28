import Combine
import Library
import SwiftUI
import UIKit

/// Streaming log viewer with the user-requested controls:
///   • Log level filter — initial value is read from the active profile's
///     `log-level:` key, falling back to `.debug` when absent
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
    @Published var selectedLevel: LogLevel = .debug
    @Published var isPaused: Bool = false
    @Published var visible: [LogEntry] = []
    @Published var isConnected: Bool = false
    @Published var justCopied: Bool = false
    @Published var lastCopyCount: Int = 0

    static let maxVisible = 800

    private weak var commandClient: CommandClient?
    private var environment: ExtensionEnvironment?
    private var bag = Set<AnyCancellable>()
    private var pausedSnapshot: [LogEntry]?
    private var hasLoadedConfigLevel = false

    func bind(to environment: ExtensionEnvironment) {
        self.environment = environment
        commandClient = environment.commandClient
        searchText = environment.logSearchText

        if !hasLoadedConfigLevel {
            hasLoadedConfigLevel = true
            Task { await self.loadLevelFromActiveConfig() }
        }

        guard let client = commandClient else { return }
        // The gRPC connection is owned by ExtensionEnvironment now —
        // no per-view connect() needed.

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

        client.$isConnected
            .receive(on: RunLoop.main)
            .assign(to: \.isConnected, on: self)
            .store(in: &bag)
    }

    func unbind() {
        environment?.logSearchText = searchText
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

    private func loadLevelFromActiveConfig() async {
        guard let active = ProfileStore.shared.active else { return }
        let url = FilePath.profilesDirectory.appendingPathComponent(active.fileName)
        let level = await Task.detached(priority: .utility) { () -> LogLevel in
            guard let yaml = try? String(contentsOf: url, encoding: .utf8) else {
                return .debug
            }
            return Self.parseLogLevel(in: yaml) ?? .debug
        }.value
        selectedLevel = level
    }

    /// Picks the first top-level `log-level: <value>` line out of a mihomo
    /// YAML config. Indented occurrences (which would belong to a nested
    /// mapping) are skipped so we don't accidentally read a sub-key.
    nonisolated static func parseLogLevel(in yaml: String) -> LogLevel? {
        let pattern = #"(?m)^log-level\s*:\s*["']?([A-Za-z]+)["']?"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: yaml, range: NSRange(yaml.startIndex..., in: yaml)),
              let range = Range(match.range(at: 1), in: yaml) else {
            return nil
        }
        switch String(yaml[range]).lowercased() {
        case "debug": return .debug
        case "info": return .info
        case "warning": return .warning
        case "error": return .error
        case "silent": return .silent
        default: return nil
        }
    }
}
