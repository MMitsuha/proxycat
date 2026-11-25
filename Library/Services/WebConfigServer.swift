import Foundation
import Network
import Observation

/// LAN HTTP server that exposes the profile catalog to a small browser
/// editor. It is opt-in, token-protected, and only runs while the host app
/// is active.
@MainActor @Observable
public final class WebConfigServer {
    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case running
        case failed(String)

        public var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    public private(set) var state: State = .stopped
    public private(set) var port: Int?
    public private(set) var token: String?
    /// Address-only URL (no token) safe to display in the UI.
    public private(set) var baseURL: URL?
    /// URL using the device's LAN IPv4 address when available, otherwise
    /// loopback. Includes the access token for one-click browser opening.
    public private(set) var accessURL: URL?
    /// Loopback URL for opening the editor on the device itself.
    public private(set) var localURL: URL?

    @ObservationIgnored private let logger = ProxyCatLogger(
        subsystem: "io.proxycat.Library",
        category: "WebConfigServer"
    )
    @ObservationIgnored private let queue = DispatchQueue(
        label: "io.proxycat.webconfig",
        qos: .userInitiated
    )
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var listenerID: UUID?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    /// Connections currently being served. Tracked so `stop()` can tear
    /// them down and so unauthenticated peers can't park unbounded sockets.
    @ObservationIgnored private var connections: [UUID: NWConnection] = [:]
    @ObservationIgnored private var desired = WebEditorSettings.defaults
    @ObservationIgnored private var appIsActive = true
    /// Kept for the lifetime of the host process so backgrounding and
    /// foregrounding does not invalidate an open browser tab.
    @ObservationIgnored private var sessionToken: String?
    @ObservationIgnored private let router = WebConfigRouter()

    public init() {}

    struct URLs: Equatable, Sendable {
        let base: URL?
        let access: URL?
        let local: URL?
    }

    /// Builds the display URL (no token) and the tokenized URLs used for
    /// copy/open actions. Kept pure so tests can assert the token never
    /// leaks into `base`.
    nonisolated static func makeURLs(host: String, port: Int, token: String) -> URLs {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = "/"
        let base = components.url

        components.queryItems = [URLQueryItem(name: "token", value: token)]
        let access = components.url

        components.host = "127.0.0.1"
        let local = components.url
        return URLs(base: base, access: access, local: local)
    }

    public func apply(_ settings: WebEditorSettings) {
        desired = settings
        reconcile()
    }

    public func setAppActive(_ active: Bool) {
        appIsActive = active
        reconcile()
    }

    private func reconcile() {
        guard appIsActive, desired.isEnabled, desired.hasValidPort else {
            stop()
            return
        }
        if listener != nil, port == desired.port {
            return
        }
        start(port: desired.port)
    }

    /// Recomputes the displayed URLs from the current LAN address. Called
    /// when the listener becomes ready, when the network path changes, and
    /// when the settings screen appears, so a DHCP change or a Wi-Fi that
    /// finished connecting after startup doesn't leave a stale or loopback
    /// address on screen.
    public func refreshURLs() {
        guard state.isRunning, let port, let token else { return }
        let host = LocalNetworkAddress.ipv4() ?? "127.0.0.1"
        let urls = Self.makeURLs(host: host, port: port, token: token)
        baseURL = urls.base
        accessURL = urls.access
        localURL = urls.local
    }

    /// True when no usable LAN address was found and the displayed URL
    /// only works on this device.
    public var isLoopbackOnly: Bool {
        baseURL?.host == "127.0.0.1"
    }

    public func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        listenerID = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        for connection in connections.values {
            connection.cancel()
        }
        connections.removeAll()
        port = nil
        token = nil
        baseURL = nil
        accessURL = nil
        localURL = nil
        state = .stopped
    }

    private func start(port: Int) {
        stop()
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
            state = .failed("Invalid port")
            return
        }

        let token = sessionToken ?? Self.generateToken()
        sessionToken = token
        self.token = token
        self.port = port
        state = .starting

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: parameters, on: nwPort)
            // Advertising a Bonjour service makes iOS present the local
            // network permission prompt on first launch. Without it the
            // listener can appear "ready" while LAN clients are silently
            // denied by the privacy layer.
            listener.service = NWListener.Service(
                name: "ProxyCat",
                type: "_proxycat._tcp"
            )
            let listenerID = UUID()
            self.listener = listener
            self.listenerID = listenerID
            listener.stateUpdateHandler = { [weak self] listenerState in
                Task { @MainActor [weak self] in
                    self?.handleListenerState(listenerState, listenerID: listenerID)
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.accept(connection, listenerID: listenerID)
                }
            }
            listener.start(queue: queue)
            startPathMonitor()
            logger.info("Web editor listening on port \(port)")
        } catch {
            listener = nil
            listenerID = nil
            self.port = nil
            self.token = nil
            baseURL = nil
            accessURL = nil
            localURL = nil
            state = .failed(error.localizedDescription)
            logger.error("Web editor failed to start: \(error.localizedDescription)")
        }
    }

    private func handleListenerState(
        _ listenerState: NWListener.State,
        listenerID: UUID
    ) {
        guard self.listenerID == listenerID else { return }
        switch listenerState {
        case .ready:
            state = .running
            refreshURLs()
        case .failed(let error):
            state = .failed(error.localizedDescription)
            cleanupFailedStart()
        case .cancelled:
            if case .failed = state { return }
            state = .stopped
        default:
            break
        }
    }

    private func cleanupFailedStart() {
        listener?.cancel()
        listener = nil
        listenerID = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        port = nil
        token = nil
        baseURL = nil
        accessURL = nil
        localURL = nil
    }

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                // Wi-Fi can finish connecting after the listener turns
                // ready, and DHCP/VPN changes can move the LAN address.
                self?.refreshURLs()
            }
        }
        monitor.start(queue: queue)
    }

    private func accept(_ connection: NWConnection, listenerID: UUID) {
        guard self.listenerID == listenerID, state.isRunning else {
            connection.cancel()
            return
        }
        guard connections.count < WebConfigHTTPServerLimits.maxConcurrentConnections else {
            logger.info("Web editor connection limit reached; rejecting connection")
            connection.cancel()
            return
        }

        let connectionID = UUID()
        connections[connectionID] = connection
        connection.start(queue: queue)

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else {
                connection.cancel()
                return
            }
            let response: WebConfigHTTPResponse
            do {
                let request = try await WebConfigHTTP.readRequest(from: connection)
                let token = await self.token
                response = await self.router.respond(to: request, token: token)
            } catch let error as WebConfigHTTPError {
                switch error {
                case .tooLarge:
                    response = .jsonError("Request body is too large", status: 413)
                case .badRequest(let message):
                    response = .jsonError(message, status: 400)
                case .timedOut:
                    response = .jsonError("Request timed out", status: 408)
                }
            } catch {
                response = .jsonError("Connection failed", status: 400)
            }
            try? await WebConfigHTTP.send(response, to: connection)
            connection.cancel()
            await self.releaseConnection(connectionID)
        }
    }

    private func releaseConnection(_ id: UUID) {
        connections.removeValue(forKey: id)
    }

    private static func generateToken() -> String {
        #if DEBUG
        // Deterministic hook for local UI/integration testing. Release
        // builds always use the process-random token below.
        if let override = ProcessInfo.processInfo.environment["PROXYCAT_WEB_TOKEN"],
           !override.isEmpty {
            return override
        }
        #endif
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(32)
        for _ in 0 ..< 32 {
            bytes.append(UInt8.random(in: .min ... .max, using: &generator))
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}
