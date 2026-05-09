import Foundation
import Observation

// MARK: - Models (mirror mihomo's `/connections` snapshot; see
// tunnel/statistic/manager.go and constant/metadata.go)

public struct ConnectionMetadata: Codable, Hashable, Sendable {
    public let network: String
    public let type: String
    public let sourceIP: String
    public let destinationIP: String
    /// `,string` json tag → arrives as string in the wire format.
    public let sourcePort: String
    public let destinationPort: String
    public let host: String
    public let process: String
    public let processPath: String
    public let dnsMode: String?
    public let sniffHost: String?

    public var displayHost: String {
        // Mirror metacubexd's host column: prefer host (sniffed/SNI),
        // fall back to destinationIP. Either may be empty for very early
        // packets so we end up with a "—" placeholder downstream.
        if !host.isEmpty { return host }
        return destinationIP
    }

    public var displayPort: String {
        destinationPort
    }
}

public struct Connection: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let metadata: ConnectionMetadata
    public let upload: Int64
    public let download: Int64
    public let start: Date
    public let chains: [String]
    public let rule: String
    public let rulePayload: String

    /// Bytes/sec since the previous snapshot. Computed on the Swift side
    /// (see ConnectionsStore.diff) — not a wire field.
    public var uploadSpeed: Int64 = 0
    public var downloadSpeed: Int64 = 0

    /// Outermost hop in the proxy chain. mihomo's chain is reversed
    /// relative to display order (DIRECT/Proxy first), and this is the
    /// one users care about. Empty when no chain has been established yet.
    public var primaryChain: String { chains.first ?? "" }

    enum CodingKeys: String, CodingKey {
        case id, metadata, upload, download, start, chains, rule, rulePayload
    }
}

public struct ConnectionsSnapshot: Codable, Sendable {
    public let downloadTotal: Int64
    public let uploadTotal: Int64
    public let connections: [Connection]?
    public let memory: UInt64?
}

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
/// rides the App-Group Unix socket now and stays up regardless of the
/// user's "Disable Web Controller" toggle.
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

    @ObservationIgnored private let client: UnixHTTPClient
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var filterDebounceTask: Task<Void, Never>?

    /// Reusable scratch buffers for `apply(_:)`. Avoids allocating a
    /// fresh `[String: Connection]` and `[String: Int64]` every poll
    /// (1 Hz) — over a long session that's hundreds of dictionary
    /// allocations Swift's allocator + ARC have to chew through, on
    /// top of the connection list itself.
    @ObservationIgnored private var prevByID: [String: Connection] = [:]
    @ObservationIgnored private var chainSpeedsBuf: [String: Int64] = [:]

    /// `ISO8601DateFormatter` parses are thread-safe after configuration,
    /// but the type isn't formally Sendable, so we wrap them. mihomo
    /// emits RFC3339Nano (Go default for `time.Time` JSON), which the
    /// fractional-seconds formatter handles; the plain one is the rare
    /// whole-second fallback.
    private struct DateParsers: @unchecked Sendable {
        let withFraction: ISO8601DateFormatter
        let plain: ISO8601DateFormatter
        init() {
            let wf = ISO8601DateFormatter()
            wf.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            self.withFraction = wf
            let p = ISO8601DateFormatter()
            p.formatOptions = [.withInternetDateTime]
            self.plain = p
        }
        func parse(_ s: String) -> Date? {
            withFraction.date(from: s) ?? plain.date(from: s)
        }
    }

    private static let dateParsers = DateParsers()
    private static let dateDecoder: JSONDecoder = {
        let d = JSONDecoder()
        let parsers = dateParsers
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let s = try container.decode(String.self)
            if let date = parsers.parse(s) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "unexpected date format: \(s)"
            )
        }
        return d
    }()

    /// Polling interval. Matches the WebSocket cadence the server-side
    /// /connections endpoint pushes at, so the UI feels identical.
    private static let pollInterval: Duration = .milliseconds(1_000)

    public init(client: UnixHTTPClient = UnixHTTPClient(socketPath: FilePath.controllerSocketPath)) {
        self.client = client
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
        pollTask = Task { @MainActor [weak self] in
            await RetryLoop.run { [weak self] in
                guard let self else { return true }
                return await self.runPollLoop()
            }
            self?.isStreaming = false
        }
    }

    public func stop() {
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
        chainSpeedsBuf.removeAll(keepingCapacity: true)
    }

    deinit {
        pollTask?.cancel()
        filterDebounceTask?.cancel()
    }

    /// `DELETE /connections/{id}`. The connection disappears from the
    /// next snapshot frame, so we don't optimistically remove it locally
    /// — that would cause a row to flash back if the close fails.
    public func close(id: String) async {
        // mihomo IDs are UUIDs, but escape anyway so a future server
        // change (or a synthetic test) can't smuggle path traversal in.
        let path = MihomoController.makePath(
            "connections/\(MihomoController.percentEncodeSegment(id))"
        )
        await sendDelete(path: path, errorPrefix: "Could not close")
    }

    /// `DELETE /connections`.
    public func closeAll() async {
        await sendDelete(path: MihomoController.makePath("connections"), errorPrefix: "Could not close all")
    }

    /// Lets the view dismiss an error alert. `loadError` stays
    /// `private(set)` so external code can't fabricate one, but an alert
    /// binding does need to clear on user dismissal.
    public func clearLoadError() {
        loadError = nil
    }

    // MARK: - Private

    private func sendDelete(path: String, errorPrefix: String) async {
        let request = UnixHTTPRequest(method: "DELETE", path: path)
        do {
            let response = try await client.send(request, timeout: 5)
            if !response.isSuccess {
                loadError = "\(errorPrefix) (HTTP \(response.status))"
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// One iteration of the poll-and-sleep cycle. Returns true on
    /// success so RetryLoop resets its backoff between snapshots —
    /// failures keep the original backoff so a stuck extension doesn't
    /// pin the loop hot.
    private func runPollLoop() async -> Bool {
        let path = MihomoController.makePath(
            "connections",
            queryItems: [URLQueryItem(name: "interval", value: "1000")]
        )
        let request = UnixHTTPRequest(method: "GET", path: path)
        do {
            let response = try await client.send(request, timeout: 5)
            try Task.checkCancellation()
            guard response.isSuccess else {
                loadError = "Controller returned HTTP \(response.status)"
                isStreaming = false
                return false
            }
            try handle(body: response.body)
            isStreaming = true
            loadError = nil
        } catch is CancellationError {
            return true
        } catch {
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

    private func handle(body: Data) throws {
        let snapshot: ConnectionsSnapshot
        do {
            snapshot = try Self.dateDecoder.decode(ConnectionsSnapshot.self, from: body)
        } catch {
            // A malformed snapshot is not fatal — keep polling. We
            // surface the error as a banner via loadError so the user
            // knows the table may be stale.
            loadError = "Decode failed: \(error.localizedDescription)"
            return
        }
        apply(snapshot)
    }

    private func apply(_ snapshot: ConnectionsSnapshot) {
        let prev = connections
        prevByID.removeAll(keepingCapacity: true)
        prevByID.reserveCapacity(prev.count)
        for c in prev { prevByID[c.id] = c }

        let incoming = snapshot.connections ?? []
        var next: [Connection] = []
        next.reserveCapacity(incoming.count)
        chainSpeedsBuf.removeAll(keepingCapacity: true)

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
                chainSpeedsBuf[chain, default: 0] += c.downloadSpeed
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
        speedByChain = chainSpeedsBuf
        recomputeFilter()
    }
}
