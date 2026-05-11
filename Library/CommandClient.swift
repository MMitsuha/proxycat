import Foundation
import Observation
// gomobile-generated types (LibmihomoCommandClient, LibmihomoCommandStatus,
// ClientBridge delegate) lack Sendable conformance; @preconcurrency downgrades
// the resulting strict-concurrency diagnostics on calls across the host/Go
// boundary.
@preconcurrency import Libmihomo

public enum CommandConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
}

/// Host-app-side counterpart to the gRPC command server running inside
/// the Network Extension. Subscribes to `Status` (traffic + memory) and
/// `Log` streams over a Unix-domain socket in the App Group container,
/// and exposes unary `reload` / controller request RPCs the host calls
/// when the user changes the active profile, edits the active YAML, or
/// drives native controller UI.
///
/// The actual gRPC speaking is done in Go (`Libmihomo.CommandClient`),
/// matching sing-box's libbox approach. Swift only implements a delegate
/// protocol the Go runtime calls back into; this keeps the dependency
/// footprint on the Swift side at zero (no grpc-swift).
@MainActor @Observable
public final class CommandClient: ControllerTransport {
    public private(set) var connectionState: CommandConnectionState = .disconnected
    public private(set) var lastDisconnectMessage: String?
    public private(set) var logs: [LogEntry] = []
    public private(set) var traffic: TrafficSnapshot = .zero
    /// Memory used by the *extension* process. Reported by the server in
    /// every Status frame so the host always reads the right process'
    /// usage (the host app has a separate, much larger jetsam budget).
    public private(set) var memory: MemoryStats = .zero

    public static let maxLogBuffer = 1500

    /// Soft cap above which we trim back down to `maxLogBuffer`. Trimming
    /// every append at exactly the cap is `removeFirst(1)` — O(n) on an
    /// `Array` of 1500 entries, paid every single log frame. Letting the
    /// buffer overshoot by 25% before a single bulk trim amortizes the
    /// memmove across ~375 appends, turning the per-append cost into O(1).
    private static let trimThreshold = maxLogBuffer + maxLogBuffer / 4

    /// Logs from the gRPC stream are kept on the host side only while a
    /// LogView is on screen. Off by default so a host app that never
    /// visits the Logs tab pays no buffer cost over a long session.
    @ObservationIgnored private var logBufferingEnabled = false

    @ObservationIgnored private var goClient: LibmihomoCommandClient?
    @ObservationIgnored private var bridge: ClientBridge?
    @ObservationIgnored private var bridgeID: UUID?

    @ObservationIgnored private var logGoClient: LibmihomoCommandClient?
    @ObservationIgnored private var logBridge: ClientBridge?
    @ObservationIgnored private var logBridgeID: UUID?
    @ObservationIgnored private var logReconnectTask: Task<Void, Never>?

    // Reconnect bookkeeping. The extension may not be up the moment the
    // host app first calls connect(); a simple capped backoff handles
    // the racing-startup case as well as transient drops.
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var shouldRun: Bool = false
    @ObservationIgnored private var appIsActive: Bool = true

    public init() {}

    public var isConnected: Bool {
        connectionState == .connected
    }

    public func connect() {
        guard !shouldRun else { return }
        shouldRun = true
        connectionState = .connecting
        lastDisconnectMessage = nil
        startReconnectLoop()
        reconcileLogStreaming()
    }

    public func disconnect() {
        shouldRun = false
        reconnectTask?.cancel()
        reconnectTask = nil
        stopLogStreaming()
        let oldClient = goClient
        goClient = nil
        bridge = nil
        bridgeID = nil
        connectionState = .disconnected
        lastDisconnectMessage = nil
        // The last Status frame sticks around in `traffic`/`memory`
        // otherwise, so the Dashboard would keep rendering a non-zero
        // up/down rate and "N active" connections after disconnect —
        // reads like the tunnel is still doing work even though it's
        // gone. Zero them on teardown; the next reconnect will repopulate
        // from a fresh frame.
        traffic = .zero
        memory = .zero
        // CommandClient.Close() in Go calls wg.Wait() — gRPC stream
        // teardown can take 100–500ms on a Unix socket, so do it off the
        // main actor to keep the UI responsive.
        if let oldClient {
            Task.detached { oldClient.close() }
        }
    }

    public func clearLogs() {
        logs.removeAll(keepingCapacity: false)
    }

    /// Asks the running mihomo core to re-read runtime_settings.json +
    /// the active profile YAML and hot-apply via hub.ApplyConfig. The
    /// host invokes this whenever the user changes the active profile,
    /// edits the active YAML, or toggles a runtime setting that needs
    /// a full rebuild (e.g. external controller).
    ///
    /// No-op (and not an error) when the gRPC connection isn't
    /// established yet: runtime_settings.json is the source of truth,
    /// so a tunnel that hasn't started will pick up the latest values
    /// on the next Start. Errors thrown here come from the Go core's
    /// reload (parse / semantic failures) and should be surfaced to
    /// the user verbatim.
    public func reload() async throws {
        guard let client = goClient else { return }
        try await Task.detached { try client.reload() }.value
    }

    /// Legacy escape hatch for changing mihomo's own logrus print level.
    /// The Logs tab no longer calls this: it receives every streamed log
    /// event and filters locally in Swift so a UI preference cannot make
    /// the extension stop persisting lower-level events.
    public func setLogLevel(_ level: Int) async throws {
        guard let client = goClient else { return }
        try await Task.detached { try client.setLogLevel(level) }.value
    }

    /// Sends a native-controller REST request through the command IPC
    /// channel. The Go side executes the HTTP request with net/http over
    /// mihomo's private controller Unix socket, so Swift never parses raw
    /// HTTP-over-UDS frames itself.
    public func sendControllerRequest(
        _ request: ControllerHTTPRequest,
        timeout: TimeInterval = 5
    ) async throws -> ControllerHTTPResponse {
        guard let client = goClient else { throw ControllerIPCError.notConnected }
        let timeoutMs = max(100, Int64((timeout * 1_000).rounded(.up)))
        let contentType = request.contentType ?? ""
        let body = request.body ?? Data()
        let response = try await Task.detached {
            try client.controllerRequest(
                request.method,
                path: request.path,
                contentType: contentType,
                body: body,
                timeoutMs: timeoutMs
            )
        }.value
        return ControllerHTTPResponse(status: response.status, body: response.body ?? Data())
    }

    /// Turn on log buffering. Subsequent log frames from the extension
    /// are appended to `logs` (capped by `maxLogBuffer`). The underlying
    /// gRPC log stream only runs while the app is active, so a suspended
    /// host app cannot backpressure the extension. Idempotent.
    public func enableLogBuffering() {
        logBufferingEnabled = true
        reconcileLogStreaming()
    }

    /// Stop live log buffering. Existing in-memory logs are kept so brief
    /// navigation away from the Logs tab does not blank the view; memory
    /// pressure and explicit Clear still drop them through `clearLogs()`.
    /// Safe to call when buffering is already off.
    public func disableLogBuffering() {
        logBufferingEnabled = false
        stopLogStreaming()
    }

    /// Lets the app lifecycle suspend live log streaming before iOS freezes
    /// the host process. Status/unary IPC stays connected for foreground UI
    /// state; logs are the high-volume stream that must not be left open
    /// against a suspended reader.
    public func setAppActive(_ active: Bool) {
        guard appIsActive != active else { return }
        appIsActive = active
        reconcileLogStreaming()
    }

    // MARK: - Reconnect loop

    private func startReconnectLoop() {
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var backoff = ExponentialBackoff()
            while !Task.isCancelled, self.shouldRun {
                let connected = await self.attemptConnect()
                if connected {
                    backoff.reset()
                    // Wait until the bridge signals disconnection.
                    await self.waitForDisconnect()
                    if !self.shouldRun { return }
                }
                await backoff.sleep()
            }
        }
    }

    private func attemptConnect() async -> Bool {
        // Tear down any leftover Go client from the previous attempt.
        // Otherwise its goroutines + gRPC connection leak across each
        // reconnect cycle and the bridge's stale signal can race the
        // new bridge.
        //
        // We MUST NOT await the disconnect: Go's wg.Wait() can take up
        // to 500ms, and awaiting a detached Task with .value would
        // suspend the main actor for that whole window, freezing
        // SwiftUI updates and user touches every reconnect. The new
        // bridge owns its own one-shot signal, so the old goroutines
        // shutting down in the background can't race it.
        if let old = goClient {
            goClient = nil
            bridge = nil
            bridgeID = nil
            Task.detached { old.close() }
        }

        connectionState = .connecting
        lastDisconnectMessage = nil

        let config = LibmihomoCommandClientConfig()
        config.subscribeStatus = true
        config.subscribeLogs = false
        config.statusIntervalMs = 1_000

        let bridge = ClientBridge(owner: self)
        guard let client = LibmihomoNewCommandClient(bridge, config) else {
            connectionState = .disconnected
            return false
        }
        self.bridge = bridge
        self.bridgeID = bridge.id
        self.goClient = client
        do {
            try client.connect(FilePath.commandSocketPath)
            return true
        } catch {
            client.close()
            self.goClient = nil
            self.bridge = nil
            self.bridgeID = nil
            self.connectionState = .disconnected
            self.lastDisconnectMessage = error.localizedDescription
            return false
        }
    }

    private func waitForDisconnect() async {
        guard let bridge else { return }
        await bridge.waitForDisconnect()
    }

    // MARK: - Live logs

    private func reconcileLogStreaming() {
        if logBufferingEnabled, appIsActive, shouldRun {
            startLogReconnectLoop()
        } else {
            stopLogStreaming()
        }
    }

    private func startLogReconnectLoop() {
        guard logReconnectTask == nil else { return }
        logReconnectTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var backoff = ExponentialBackoff()
            while !Task.isCancelled, self.logBufferingEnabled, self.appIsActive, self.shouldRun {
                let connected = await self.attemptLogConnect()
                if connected {
                    backoff.reset()
                    await self.waitForLogDisconnect()
                    if !self.logBufferingEnabled || !self.appIsActive || !self.shouldRun {
                        return
                    }
                }
                await backoff.sleep()
            }
        }
    }

    private func stopLogStreaming() {
        logReconnectTask?.cancel()
        logReconnectTask = nil
        let oldClient = logGoClient
        logGoClient = nil
        logBridge = nil
        logBridgeID = nil
        if let oldClient {
            Task.detached { oldClient.close() }
        }
    }

    private func attemptLogConnect() async -> Bool {
        if let old = logGoClient {
            logGoClient = nil
            logBridge = nil
            logBridgeID = nil
            Task.detached { old.close() }
        }

        let config = LibmihomoCommandClientConfig()
        config.subscribeStatus = false
        config.subscribeLogs = true
        config.statusIntervalMs = 0

        let bridge = ClientBridge(owner: self)
        guard let client = LibmihomoNewCommandClient(bridge, config) else {
            return false
        }
        self.logBridge = bridge
        self.logBridgeID = bridge.id
        self.logGoClient = client
        do {
            try client.connect(FilePath.commandSocketPath)
            return true
        } catch {
            client.close()
            self.logGoClient = nil
            self.logBridge = nil
            self.logBridgeID = nil
            return false
        }
    }

    private func waitForLogDisconnect() async {
        guard let logBridge else { return }
        await logBridge.waitForDisconnect()
    }

    // MARK: - Bridge callbacks (called from Go via gomobile)

    fileprivate func didConnect(from bridgeID: UUID) {
        guard self.bridgeID == bridgeID else { return }
        connectionState = .connected
        lastDisconnectMessage = nil
    }

    fileprivate func didDisconnect(from bridgeID: UUID, message: String?) {
        guard self.bridgeID == bridgeID else { return }
        connectionState = shouldRun ? .connecting : .disconnected
        let message = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        lastDisconnectMessage = message.isEmpty ? nil : message
    }

    fileprivate func didReceive(status: LibmihomoCommandStatus, from bridgeID: UUID) {
        guard self.bridgeID == bridgeID else { return }
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

    fileprivate func didReceive(log entry: LogEntry, from bridgeID: UUID) {
        guard self.logBridgeID == bridgeID || self.bridgeID == bridgeID else { return }
        guard logBufferingEnabled else { return }
        logs.append(entry)
        if logs.count > Self.trimThreshold {
            logs.removeFirst(logs.count - Self.maxLogBuffer)
        }
    }
}

/// Glue between the gomobile-generated delegate protocol and our Swift
/// view-model. Methods are invoked from arbitrary Go-runtime threads,
/// so every UI-touching update is dispatched onto the main actor.
/// `@unchecked Sendable`: the only stored state is a weak ref to the
/// MainActor owner and an actor-protected one-shot signal, both safe
/// to read concurrently.
private final class ClientBridge: NSObject, LibmihomoCommandClientDelegateProtocol, @unchecked Sendable {
    let id = UUID()
    private weak var owner: CommandClient?
    private let disconnect = AsyncOneShot()

    init(owner: CommandClient) {
        self.owner = owner
    }

    func waitForDisconnect() async {
        await disconnect.wait()
    }

    // MARK: LibmihomoCommandClientDelegateProtocol

    func onConnected() {
        let id = id
        Task { @MainActor [weak owner] in owner?.didConnect(from: id) }
    }

    func onDisconnected(_ message: String?) {
        let id = id
        Task { @MainActor [weak owner] in owner?.didDisconnect(from: id, message: message) }
        disconnect.signal()
    }

    func onStatus(_ status: LibmihomoCommandStatus?) {
        guard let status else { return }
        let id = id
        Task { @MainActor [weak owner] in owner?.didReceive(status: status, from: id) }
    }

    func onLog(_ level: Int, payload: String?) {
        let entry = LogEntry(rawLevel: level, message: payload ?? "")
        let id = id
        Task { @MainActor [weak owner] in owner?.didReceive(log: entry, from: id) }
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
