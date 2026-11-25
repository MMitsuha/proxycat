import Foundation
import Observation

// MARK: - Store

/// Polls mihomo's `/connections` over the App-Group Unix-domain socket
/// once per second and exposes the live list to SwiftUI. One instance
/// per ConnectionsView appearance — not a shared singleton, so the
/// poller is torn down when the user leaves the screen.
///
/// Replaced an earlier WebSocket implementation that ran over the
/// loopback HTTP listener. The wire shape is identical (mihomo's
/// connectionRouter returns the same snapshot JSON whether the request
/// upgrades or not), so the rate of UI refresh is the same — it just
/// rides the command IPC now and stays up regardless of the user's
/// "Disable Web Controller" toggle.
@MainActor @Observable
public final class ConnectionsStore {
    public private(set) var connections: [Connection] = []
    public private(set) var uploadTotal: Int64 = 0
    public private(set) var downloadTotal: Int64 = 0
    public private(set) var isStreaming: Bool = false
    public private(set) var loadError: String?

    /// User's search box content. Two-way: the view binds it to a
    /// `.searchable` field; the didSet debounces and recomputes
    /// `filteredConnections`. Skip when the value didn't change so a
    /// re-render that re-binds the same string doesn't kick a
    /// pointless debounce + refilter pass.
    public var searchQuery: String = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            scheduleFilterDebounce()
        }
    }

    /// `connections` filtered by `searchQuery` (debounced). Views read
    /// this directly rather than re-running the predicate on every body
    /// pass — under heavy traffic that ran the 6-field match across
    /// hundreds of rows on every redraw, even when the query was empty.
    public private(set) var filteredConnections: [Connection] = []

    /// `chain → bytes/sec` aggregate, mirroring metacubexd's
    /// `speedGroupByName`. Useful for color-coding rows by outbound.
    public private(set) var speedByChain: [String: Int64] = [:]

    @ObservationIgnored private let controller: MihomoController
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var filterDebounceTask: Task<Void, Never>?
    /// Bumped by stop(); a poll task that outlives its generation must
    /// not apply a snapshot or clear `isStreaming` after a restart.
    @ObservationIgnored private var generation = 0

    /// Reused across polls to avoid allocating a fresh ID→connection
    /// dictionary at 1 Hz. Never published to SwiftUI, so the buffer
    /// keeps its storage between polls.
    @ObservationIgnored private var prevByID: [String: Connection] = [:]

    /// Polling interval. Matches the WebSocket cadence the server-side
    /// /connections endpoint pushes at, so the UI feels identical.
    private static let pollInterval: Duration = .milliseconds(1_000)

    public init(transport: any ControllerTransport) {
        self.controller = MihomoController(transport: transport)
    }

    private func scheduleFilterDebounce() {
        filterDebounceTask?.cancel()
        filterDebounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            self.recomputeFilter()
        }
    }

    private func recomputeFilter() {
        filteredConnections = Self.applyFilter(query: searchQuery, to: connections)
    }

    private static func applyFilter(query: String, to connections: [Connection]) -> [Connection] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return connections }
        let needle = trimmed.lowercased()
        return connections.filter { conn in
            if conn.metadata.host.lowercased().contains(needle) { return true }
            if conn.metadata.destinationIP.contains(needle) { return true }
            if conn.metadata.sourceIP.contains(needle) { return true }
            if conn.metadata.process.lowercased().contains(needle) { return true }
            if conn.rule.lowercased().contains(needle) { return true }
            if conn.chains.contains(where: { $0.lowercased().contains(needle) }) { return true }
            return false
        }
    }

    public func start() {
        guard pollTask == nil else { return }
        generation &+= 1
        let generation = self.generation
        pollTask = Task { @MainActor [weak self] in
            await RetryLoop.run { [weak self] in
                guard let self else { return true }
                return await self.runPollLoop(generation: generation)
            }
            guard let self, generation == self.generation else { return }
            self.isStreaming = false
        }
    }

    public func stop() {
        generation &+= 1
        pollTask?.cancel()
        pollTask = nil
        filterDebounceTask?.cancel()
        filterDebounceTask = nil
        isStreaming = false
        // Drop the snapshot too — otherwise on reconnect, rows from the
        // previous session render until the first fresh poll lands, and
        // a swipe-close in that gap would target a stale ID against the
        // new controller.
        connections = []
        filteredConnections = []
        uploadTotal = 0
        downloadTotal = 0
        speedByChain = [:]
        loadError = nil
        prevByID.removeAll(keepingCapacity: true)
    }

    deinit {
        pollTask?.cancel()
        filterDebounceTask?.cancel()
    }

    /// `DELETE /connections/{id}`. The connection disappears from the
    /// next snapshot frame, so we don't optimistically remove it locally
    /// — that would cause a row to flash back if the close fails.
    public func close(id: String) async {
        do {
            try await controller.closeConnection(id: id)
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// `DELETE /connections`.
    public func closeAll() async {
        do {
            try await controller.closeAllConnections()
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// Lets the view dismiss an error alert. `loadError` stays
    /// `private(set)` so external code can't fabricate one, but an alert
    /// binding does need to clear on user dismissal.
    public func clearLoadError() {
        loadError = nil
    }

    // MARK: - Private

    /// One iteration of the poll-and-sleep cycle. Returns true on a
    /// successfully decoded snapshot so `RetryLoop` resets its backoff —
    /// transport / HTTP failures keep the backoff growing so a stuck
    /// extension doesn't pin the loop hot. A malformed snapshot is
    /// surfaced through `loadError` but still counts as progress: the
    /// stream is alive, so we keep the regular cadence instead of
    /// backing off.
    private func runPollLoop(generation: Int) async -> Bool {
        do {
            let snapshot = try await controller.connections()
            try Task.checkCancellation()
            guard generation == self.generation else { return false }
            apply(snapshot)
            isStreaming = true
            loadError = nil
        } catch is CancellationError {
            return true
        } catch {
            guard generation == self.generation else { return false }
            loadError = error.localizedDescription
            isStreaming = false
            return false
        }

        // Wait the rest of the interval before the next poll. Cancellation
        // throws out of `Task.sleep`, which we treat as a clean exit
        // (RetryLoop will see `Task.isCancelled` and stop).
        try? await Task.sleep(for: Self.pollInterval)
        return true
    }

    private func apply(_ snapshot: ConnectionsSnapshot) {
        let prev = connections
        prevByID.removeAll(keepingCapacity: true)
        prevByID.reserveCapacity(prev.count)
        for c in prev { prevByID[c.id] = c }

        let incoming = snapshot.connections ?? []
        var next: [Connection] = []
        next.reserveCapacity(incoming.count)
        var chainSpeeds: [String: Int64] = [:]
        chainSpeeds.reserveCapacity(prevByID.count)

        for var c in incoming {
            if let p = prevByID[c.id] {
                // Bytes are monotonic per connection. Clamp to 0 to
                // defend against the edge case where mihomo's snapshot
                // reorders frames (we've never seen it but the cost is
                // a single max).
                c.uploadSpeed = max(0, c.upload - p.upload)
                c.downloadSpeed = max(0, c.download - p.download)
            } else {
                c.uploadSpeed = 0
                c.downloadSpeed = 0
            }
            next.append(c)
            for chain in c.chains {
                chainSpeeds[chain, default: 0] += c.downloadSpeed
            }
        }

        // Most-recent first by start time. Stable to keep the table from
        // shuffling when several connections share a timestamp (DoH does
        // this routinely).
        next.sort { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start > rhs.start }
            return lhs.id < rhs.id
        }
        connections = next
        uploadTotal = snapshot.uploadTotal
        downloadTotal = snapshot.downloadTotal
        speedByChain = chainSpeeds
        recomputeFilter()
    }
}
