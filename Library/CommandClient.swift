import Combine
import Foundation
import Libmihomo

/// Host-app-side counterpart to the gRPC command server running inside
/// the Network Extension. Subscribes to `Status` (traffic + memory) and
/// `Log` streams over a Unix-domain socket in the App Group container.
///
/// The actual gRPC speaking is done in Go (`Libmihomo.CommandClient`),
/// matching sing-box's libbox approach. Swift only implements a delegate
/// protocol the Go runtime calls back into; this keeps the dependency
/// footprint on the Swift side at zero (no grpc-swift).
@MainActor
public final class CommandClient: ObservableObject {
    @Published public private(set) var isConnected: Bool = false
    @Published public private(set) var logs: [LogEntry] = []
    @Published public private(set) var traffic: TrafficSnapshot = .zero
    /// Memory used by the *extension* process. Reported by the server in
    /// every Status frame so the host always reads the right process'
    /// usage (the host app has a separate, much larger jetsam budget).
    @Published public private(set) var memory: MemoryStats = .zero
    @Published public var defaultLogLevel: LogLevel = .info

    public static let maxLogBuffer = 1500

    private var goClient: LibmihomoCommandClient?
    private var bridge: ClientBridge?

    // Reconnect bookkeeping. The extension may not be up the moment the
    // host app first calls connect(); a simple capped backoff handles
    // the racing-startup case as well as transient drops.
    private var reconnectTask: Task<Void, Never>?
    private var shouldRun: Bool = false

    public init() {}

    public func connect() {
        guard !shouldRun else { return }
        shouldRun = true
        startReconnectLoop()
    }

    public func disconnect() {
        shouldRun = false
        reconnectTask?.cancel()
        reconnectTask = nil
        let oldClient = goClient
        goClient = nil
        bridge = nil
        isConnected = false
        // CommandClient.Disconnect() in Go calls wg.Wait() — gRPC stream
        // teardown can take 100–500ms on a Unix socket, so do it off the
        // main actor to keep the UI responsive.
        if let oldClient {
            Task.detached { oldClient.disconnect() }
        }
    }

    public func clearLogs() {
        logs.removeAll(keepingCapacity: false)
    }

    // MARK: - Reconnect loop

    private func startReconnectLoop() {
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var backoffMs: UInt64 = 200
            while !Task.isCancelled, self.shouldRun {
                let connected = await self.attemptConnect()
                if connected {
                    backoffMs = 200
                    // Wait until the bridge signals disconnection.
                    await self.waitForDisconnect()
                    if !self.shouldRun { return }
                }
                try? await Task.sleep(nanoseconds: backoffMs * NSEC_PER_MSEC)
                backoffMs = min(backoffMs * 2, 5_000)
            }
        }
    }

    private func attemptConnect() async -> Bool {
        // Tear down any leftover Go client from the previous attempt.
        // Otherwise its goroutines + gRPC connection leak across each
        // reconnect cycle and the bridge's stale signal can race the
        // new bridge.
        if let old = goClient {
            goClient = nil
            bridge = nil
            await Task.detached { old.disconnect() }.value
        }

        let options = LibmihomoCommandClientOptions()
        options.subscribeStatus = true
        options.subscribeLogs = true
        options.statusIntervalMs = 1_000

        let bridge = ClientBridge(owner: self)
        guard let client = LibmihomoNewCommandClient(bridge, options) else {
            return false
        }
        self.bridge = bridge
        self.goClient = client
        do {
            try client.connect(FilePath.commandSocketPath)
            return true
        } catch {
            client.disconnect()
            self.goClient = nil
            self.bridge = nil
            return false
        }
    }

    private func waitForDisconnect() async {
        guard let bridge else { return }
        await bridge.waitForDisconnect()
    }

    // MARK: - Bridge callbacks (called from Go via gomobile)

    fileprivate func didConnect() {
        isConnected = true
    }

    fileprivate func didDisconnect(_ reason: String) {
        isConnected = false
    }

    fileprivate func didReceive(status: LibmihomoStatus) {
        traffic = TrafficSnapshot(
            up: status.up,
            down: status.down,
            upTotal: status.upTotal,
            downTotal: status.downTotal,
            connections: status.connections
        )
        let resident = Int(status.memoryResident)
        let budget = Int(status.memoryBudget)
        let available = max(0, budget - resident)
        memory = MemoryStats(resident: resident, available: available)
    }

    fileprivate func didReceive(log entry: LogEntry) {
        logs.append(entry)
        if logs.count > Self.maxLogBuffer {
            logs.removeFirst(logs.count - Self.maxLogBuffer)
        }
    }
}

/// Glue between the gomobile-generated handler protocol and our Swift
/// view-model. Methods are invoked from arbitrary Go-runtime threads,
/// so every UI-touching update is dispatched onto the main actor.
private final class ClientBridge: NSObject, LibmihomoCommandClientHandlerProtocol {
    private weak var owner: CommandClient?
    private let disconnect = AsyncOneShot()

    init(owner: CommandClient) {
        self.owner = owner
    }

    func waitForDisconnect() async {
        await disconnect.wait()
    }

    // MARK: LibmihomoCommandClientHandlerProtocol

    func connected() {
        Task { @MainActor [weak owner] in owner?.didConnect() }
    }

    func disconnected(_ message: String?) {
        Task { @MainActor [weak owner] in owner?.didDisconnect(message ?? "") }
        disconnect.signal()
    }

    func write(_ status: LibmihomoStatus?) {
        guard let status else { return }
        Task { @MainActor [weak owner] in owner?.didReceive(status: status) }
    }

    func writeLog(_ level: Int, payload: String?) {
        let entry = LogEntry(rawLevel: level, message: payload ?? "")
        Task { @MainActor [weak owner] in owner?.didReceive(log: entry) }
    }
}

/// Tiny one-shot async signal used to await the bridge's disconnect.
private actor AsyncOneShot {
    private var fired = false
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if fired { return }
        await withCheckedContinuation { cont in
            continuations.append(cont)
        }
    }

    nonisolated func signal() {
        Task { await self._signal() }
    }

    private func _signal() {
        guard !fired else { return }
        fired = true
        for c in continuations { c.resume() }
        continuations.removeAll()
    }
}

