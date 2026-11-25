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
    @ObservationIgnored private var desired = WebEditorSettings.defaults
    @ObservationIgnored private var appIsActive = true
    /// Kept for the lifetime of the host process so backgrounding and
    /// foregrounding does not invalidate an open browser tab.
    @ObservationIgnored private var sessionToken: String?
    @ObservationIgnored private let router = WebConfigRouter()

    public init() {}

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

    public func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        listenerID = nil
        port = nil
        token = nil
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
                    self?.handleListenerState(
                        listenerState,
                        listenerID: listenerID,
                        port: port
                    )
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.accept(connection, listenerID: listenerID)
                }
            }
            listener.start(queue: queue)
            logger.info("Web editor listening on port \(port)")
        } catch {
            listener = nil
            listenerID = nil
            self.port = nil
            self.token = nil
            accessURL = nil
            localURL = nil
            state = .failed(error.localizedDescription)
            logger.error("Web editor failed to start: \(error.localizedDescription)")
        }
    }

    private func handleListenerState(
        _ listenerState: NWListener.State,
        listenerID: UUID,
        port: Int
    ) {
        guard self.listenerID == listenerID else { return }
        switch listenerState {
        case .ready:
            let host = LocalNetworkAddress.ipv4() ?? "127.0.0.1"
            if let token {
                accessURL = URL(string: "http://\(host):\(port)/?token=\(token)")
                localURL = URL(string: "http://127.0.0.1:\(port)/?token=\(token)")
            }
            state = .running
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
        port = nil
        token = nil
        accessURL = nil
        localURL = nil
    }

    private func accept(_ connection: NWConnection, listenerID: UUID) {
        guard self.listenerID == listenerID, state.isRunning else {
            connection.cancel()
            return
        }
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
                }
            } catch {
                response = .jsonError("Connection failed", status: 400)
            }
            try? await WebConfigHTTP.send(response, to: connection)
            connection.cancel()
        }
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
