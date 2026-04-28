import Combine
import Foundation
import Libmihomo

/// Runs *inside the host app* and brokers data from the Network Extension.
///
/// In the sing-box-for-apple architecture this is a Unix-socket / XPC client
/// to a long-running command server inside the extension. For the mihomo
/// port we take a simpler route appropriate to mihomo's design:
///
/// • The extension talks directly to mihomo via the gomobile binding.
/// • Logs and traffic produced *inside the extension* don't traverse a
///   socket; they're written into the shared app-group container as a
///   ring file (`Cache/ne.log`) plus a small `Cache/traffic.json` snapshot
///   that the extension refreshes on a 1s timer.
/// • The host app polls/reads those files. This avoids a custom IPC
///   protocol while still staying within the NE memory budget.
///
/// The CommandClient hides the file-watching detail behind @Published
/// signals identical to sing-box's CommandClient API.
@MainActor
public final class CommandClient: ObservableObject {
    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var logs: [LogEntry] = []
    @Published public private(set) var traffic: TrafficSnapshot = .zero
    /// Currently effective log level. Mirrors mihomo's runtime filter so the
    /// log view's "Default" option matches what the extension is producing.
    @Published public var defaultLogLevel: LogLevel = .info

    public static let maxLogBuffer = 1500

    private var trafficTimer: Timer?
    private var logTimer: Timer?
    private var lastLogOffset: UInt64 = 0
    private let logURL = FilePath.cacheDirectory.appendingPathComponent("ne.log")
    private let trafficURL = FilePath.cacheDirectory.appendingPathComponent("traffic.json")

    public init() {}

    public func connect() {
        isConnected = true
        startTrafficPoll()
        startLogPoll()
    }

    public func disconnect() {
        trafficTimer?.invalidate()
        trafficTimer = nil
        logTimer?.invalidate()
        logTimer = nil
        isConnected = false
    }

    public func clearLogs() {
        logs.removeAll(keepingCapacity: false)
        try? Data().write(to: logURL, options: .atomic)
        lastLogOffset = 0
    }

    private func startTrafficPoll() {
        trafficTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTraffic() }
        }
    }

    private func startLogPoll() {
        logTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tailLog() }
        }
    }

    private func refreshTraffic() {
        guard let data = try? Data(contentsOf: trafficURL),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return }
        traffic = TrafficSnapshot(
            up: (dict["up"] as? NSNumber)?.int64Value ?? 0,
            down: (dict["down"] as? NSNumber)?.int64Value ?? 0,
            upTotal: (dict["upTotal"] as? NSNumber)?.int64Value ?? 0,
            downTotal: (dict["downTotal"] as? NSNumber)?.int64Value ?? 0,
            connections: (dict["connections"] as? NSNumber)?.int64Value ?? 0
        )
    }

    private func tailLog() {
        guard let handle = try? FileHandle(forReadingFrom: logURL) else { return }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        if size < lastLogOffset {
            // File rotated/truncated.
            lastLogOffset = 0
        }
        guard size > lastLogOffset else { return }
        try? handle.seek(toOffset: lastLogOffset)
        let chunk = (try? handle.readToEnd()) ?? Data()
        lastLogOffset = size

        guard let text = String(data: chunk, encoding: .utf8), !text.isEmpty else { return }

        var newEntries: [LogEntry] = []
        for line in text.split(separator: "\n") {
            // Format: "<level>\t<message>"
            let parts = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let raw = Int(parts[0]) else { continue }
            newEntries.append(LogEntry(rawLevel: raw, message: String(parts[1])))
        }
        if newEntries.isEmpty { return }
        logs.append(contentsOf: newEntries)
        if logs.count > Self.maxLogBuffer {
            logs.removeFirst(logs.count - Self.maxLogBuffer)
        }
    }
}
