import Library
import Observation
import SwiftUI
import UIKit

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
    /// Host-side display filter for the Logs tab. The mihomo extension
    /// always streams every event; this picker decides what the user
    /// sees. Mirrors `RuntimeSettings.shared.logLevel` so the choice
    /// persists across launches (and rides iCloud sync), but no IPC
    /// nudge is sent — the recompute pipeline applies the cutoff
    /// locally before publishing to `stream.visible`.
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
        // Open the live log stream and the host-side buffer. Both are
        // tied to this view's lifetime: detach() closes the stream and
        // discards the buffer so a backgrounded host never holds a
        // gRPC log subscription against a suspended reader (which
        // would backpressure mihomo's global logger).
        //
        // For historical browsing the user goes to Saved Logs; the
        // mihomo-*.log file already captures every event at every
        // level, written by the Go side independently of this stream.
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

    /// Called from `onDisappear`. Persists the search term, tears down
    /// the observation pipes, and asks CommandClient to drop the log
    /// gRPC subscription + clear its in-memory buffer. Each re-entry
    /// to the Logs tab is therefore a fresh subscription — matching
    /// "open connection to receive everything while page is visible"
    /// and guaranteeing the extension never streams logs to a host
    /// that has navigated away or backgrounded the app.
    ///
    /// Pause is reset on the way out too: the underlying `logs` buffer
    /// is cleared on disable, so a stale paused snapshot would show
    /// pre-navigation data on re-entry. Coming back in `live` mode
    /// matches what the empty buffer actually represents.
    func detach() {
        environment?.logSearchText = searchText
        for task in pipelineTasks { task.cancel() }
        pipelineTasks.removeAll()
        commandClient?.disableLogBuffering()
        pausedSnapshot = nil
        isPaused = false
        stream.visible.removeAll()
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
