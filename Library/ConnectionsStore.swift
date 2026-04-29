import Combine
import Foundation

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

/// Subscribes to mihomo's `/connections` WebSocket and exposes the live
/// list to SwiftUI. One instance per ConnectionsView appearance — not a
/// shared singleton, so the WS is torn down when the user leaves the
/// screen.
@MainActor
public final class ConnectionsStore: ObservableObject {
    @Published public private(set) var connections: [Connection] = []
    @Published public private(set) var uploadTotal: Int64 = 0
    @Published public private(set) var downloadTotal: Int64 = 0
    @Published public private(set) var isStreaming: Bool = false
    @Published public private(set) var loadError: String?

    /// `chain → bytes/sec` aggregate, mirroring metacubexd's
    /// `speedGroupByName`. Useful for color-coding rows by outbound.
    @Published public private(set) var speedByChain: [String: Int64] = [:]

    private let baseURL: URL
    private let session: URLSession
    private var streamTask: Task<Void, Never>?
    private var wsTask: URLSessionWebSocketTask?

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

    public init(
        baseURL: URL = MihomoController.defaultBaseURL,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.session = session
    }

    public func start() {
        guard streamTask == nil else { return }
        streamTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var backoffMs: UInt64 = 200
            while !Task.isCancelled {
                let ok = await self.runOnce()
                if Task.isCancelled { break }
                if ok {
                    backoffMs = 200
                }
                try? await Task.sleep(nanoseconds: backoffMs * NSEC_PER_MSEC)
                backoffMs = min(backoffMs * 2, 5_000)
            }
            self.isStreaming = false
        }
    }

    public func stop() {
        streamTask?.cancel()
        streamTask = nil
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        isStreaming = false
    }

    deinit {
        // Cannot await on main actor; just signal cancellation.
        streamTask?.cancel()
        wsTask?.cancel(with: .goingAway, reason: nil)
    }

    /// `DELETE /connections/{id}`. The connection disappears from the
    /// next snapshot frame, so we don't optimistically remove it locally
    /// — that would cause a row to flash back if the close fails.
    public func close(id: String) async {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("connections/\(id)"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = nil
        var req = URLRequest(url: components.url!)
        req.httpMethod = "DELETE"
        req.timeoutInterval = 5
        do {
            let (_, response) = try await session.data(for: req)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                loadError = "Could not close (HTTP \(http.statusCode))"
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// `DELETE /connections`.
    public func closeAll() async {
        var req = URLRequest(url: baseURL.appendingPathComponent("connections"))
        req.httpMethod = "DELETE"
        req.timeoutInterval = 5
        do {
            _ = try await session.data(for: req)
        } catch {
            loadError = error.localizedDescription
        }
    }

    // MARK: - Private

    private func runOnce() async -> Bool {
        // ws scheme on loopback. mihomo's binding (binding.go) forces the
        // controller secret empty for proxycat, so no auth header.
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("connections"),
            resolvingAgainstBaseURL: false
        ) else { return false }
        components.scheme = (baseURL.scheme == "https") ? "wss" : "ws"
        components.queryItems = [URLQueryItem(name: "interval", value: "1000")]
        guard let wsURL = components.url else { return false }

        let task = session.webSocketTask(with: wsURL)
        wsTask = task
        task.resume()

        do {
            // First receive doubles as a connection-success signal: if
            // the handshake fails (extension still booting, controller
            // not bound yet), receive() throws and we back off.
            let firstFrame = try await task.receive()
            try Task.checkCancellation()
            isStreaming = true
            loadError = nil
            try handle(frame: firstFrame)

            while !Task.isCancelled {
                let frame = try await task.receive()
                try handle(frame: frame)
            }
            return true
        } catch is CancellationError {
            return true
        } catch {
            loadError = humanReadable(error)
            isStreaming = false
            task.cancel(with: .goingAway, reason: nil)
            wsTask = nil
            return false
        }
    }

    private func handle(frame: URLSessionWebSocketTask.Message) throws {
        let data: Data
        switch frame {
        case .data(let d): data = d
        case .string(let s): data = Data(s.utf8)
        @unknown default: return
        }
        let snapshot: ConnectionsSnapshot
        do {
            snapshot = try Self.dateDecoder.decode(ConnectionsSnapshot.self, from: data)
        } catch {
            // A malformed frame is not fatal — keep the stream open.
            // We surface the error as a banner via loadError so the user
            // knows the table may be stale.
            loadError = "Decode failed: \(error.localizedDescription)"
            return
        }
        apply(snapshot)
    }

    private func apply(_ snapshot: ConnectionsSnapshot) {
        let prev = connections
        var prevByID: [String: Connection] = [:]
        prevByID.reserveCapacity(prev.count)
        for c in prev { prevByID[c.id] = c }

        var next: [Connection] = []
        next.reserveCapacity(snapshot.connections?.count ?? 0)
        var chainSpeeds: [String: Int64] = [:]

        for var c in snapshot.connections ?? [] {
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
    }

    private func humanReadable(_ error: Error) -> String {
        if let urlError = error as? URLError {
            return urlError.localizedDescription
        }
        return error.localizedDescription
    }
}
