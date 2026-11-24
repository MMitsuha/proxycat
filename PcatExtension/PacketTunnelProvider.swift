import Foundation
import Library
// NetworkExtension predates Swift concurrency annotations;
// @preconcurrency demotes the resulting Sendable diagnostics on
// override signatures to warnings.
@preconcurrency import NetworkExtension

/// Network Extension entry point. Intentionally a thin shim — the Go
/// core owns all runtime state (YAML, settings, controller config),
/// and we only configure paths once and trigger lifecycle events. A
/// setting toggled in the host UI propagates by writing
/// runtime_settings.json (which Go re-reads) and a gRPC `Reload` RPC
/// handled inside the embedded command server. Log level is the
/// exception: it is a host-side display filter for the Logs tab, so
/// no IPC ever carries it — mihomo here always emits every event,
/// the host filters before display. This type owns no business logic
/// of its own.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private static let logger = ProxyCatLogger(subsystem: "io.proxycat.Pcat.PcatExtension", category: "PTP")

    private var memoryObserverToken: UUID?
    private lazy var pathMonitor = NetworkPathMonitor(logger: Self.logger)

    // MARK: - Lifecycle

    override func startTunnel(options _: [String: NSObject]?) async throws {
        startProxyCatLogFile()
        do {
            try await startTunnelImpl()
        } catch {
            Self.logger.error("startTunnel failed: \(error.localizedDescription)")
            // A failure can happen anywhere between "memory monitor up"
            // and "mihomo fully started". Tear down everything the
            // partial attempt created, otherwise a retry leaks the path
            // monitor / memory listener and may leave mihomo half-alive
            // with a stale TUN fd.
            tearDownTunnelResources()
            throw error
        }
    }

    private func startTunnelImpl() async throws {
        Self.logger.info("startTunnel")

        // 1. Configure tunnel network settings *before* taking the fd. iOS
        //    materializes the utun device only after this completes.
        try await configureNetworkSettings()

        // 2. Acquire file descriptor for the packet flow. NEPacketTunnelFlow
        //    doesn't expose this publicly; we try several KVC paths used by
        //    different iOS versions, then fall back to enumerating the
        //    process's file descriptors and picking out the utun control
        //    socket — the same trick libbox uses for sing-box.
        let fd = TunnelFileDescriptor.locate(in: packetFlow, logger: Self.logger)
        guard fd > 0 else {
            throw PTPError("could not obtain TUN file descriptor — likely running on simulator (no real utun) or KVC path changed in this iOS version")
        }
        Self.logger.info("packet flow fd = \(fd)")

        // 3. Wire memory monitor *before* loading mihomo so we can already
        //    react if the bind itself spikes memory.
        startMemoryMonitor()

        // 4. Tell the Go core where every shared file lives. After this
        //    point Start / Reload re-read the active YAML and runtime
        //    settings on their own — nothing flows through this
        //    extension's options dictionary. Host commands (Reload,
        //    ControllerRequest) ride the gRPC command service.
        configureLibmihomoPaths()

        // 4a. Seed compile-time bundled geo databases and external UI
        //     into the working directory so mihomo finds them on first
        //     run before any download happens. Idempotent — already-up-
        //     to-date assets are skipped. Copied off the extension's
        //     async context so a large first-run install doesn't hold
        //     the start path.
        _ = await Task.detached(priority: .utility) {
            BundledAssets.installIfNeeded()
        }.value

        // 4b. Tell the Go OOM killer the actual iOS budget (resident +
        //     available) instead of the 50 MB sing-box default. iOS
        //     doesn't expose the real jetsam limit; this approximation
        //     captures it the moment we ask, before mihomo allocates much.
        let memory = MemoryMonitor.snapshot()
        let budget = Int64(memory.estimatedLimit)
        if budget > 0 {
            LibmihomoBridge.setMemoryLimit(budget)
            Self.logger.info("OOM budget set to \(budget) (resident=\(memory.resident) available=\(memory.available))")
        }

        // 4c. Push the iOS fd into mihomo before starting so the parsed
        //     YAML's TUN inbound binds to the kernel-supplied fd and we
        //     overwrite address fields that don't apply on iOS.
        try LibmihomoBridge.setTunFd(Int(fd))

        // 4d. Open a per-session log file and tee mihomo's log stream
        //     into it. The host app reads from FilePath.logsDirectory
        //     to surface them in the Saved Logs list. Failures here
        //     are non-fatal: the live log stream still works.
        do {
            let logPath = try LibmihomoBridge.startLogFile()
            Self.logger.info("mihomo session log = \(logPath)")
        } catch {
            Self.logger.warning("could not open mihomo session log: \(error.localizedDescription)")
        }

        // 5. Start mihomo. Go reads runtime_settings.json (active
        //    profile id + runtime preferences) and the active profile
        //    YAML from disk; this call returns the parser / apply
        //    error verbatim if either fails.
        try LibmihomoBridge.start()

        // 6. Watch the OS default network path. iOS surfaces Wi-Fi ↔
        //    cellular switches and post-sleep reconnects through
        //    NWPathMonitor; mihomo's own DefaultInterfaceMonitor can't
        //    run inside the NE sandbox (AF_ROUTE is blocked). Without
        //    this, mihomo's interface cache and DNS upstream connections
        //    silently go stale across a network change and the tunnel
        //    appears alive but forwards nothing.
        pathMonitor.start()

        Self.logger.info("startTunnel done")
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        Self.logger.info("stopTunnel reason=\(reason.rawValue)")
        tearDownTunnelResources()
    }

    /// Single teardown path shared by `stopTunnel` and a failed
    /// `startTunnel`. Every step is idempotent, so calling it after a
    /// partial start is safe.
    private func tearDownTunnelResources() {
        pathMonitor.stop()
        // Flush before mihomo shuts down so the trailing "session ended"
        // marker reflects the real reason for stopping. (Stop() also
        // calls StopLogFile defensively, but doing it here is explicit.)
        LibmihomoBridge.stopLogFile()
        LibmihomoBridge.stop()
        if let token = memoryObserverToken {
            MemoryMonitor.shared.remove(token)
            memoryObserverToken = nil
        }
        MemoryMonitor.shared.stop()
        ProxyCatLogPersistence.shared.stop()
    }

    override func sleep() async {
        // The OS asks us to quiet down. mihomo's command server keeps
        // serving so the host app can still see status if it foregrounds.
        Self.logger.info("sleep -> keeping mihomo running")
    }

    override func wake() {
        // Belt-and-suspenders for the case where iOS quietly swapped the
        // default route during deep sleep without letting our
        // NWPathMonitor witness the transition. `NetworkPathMonitor`
        // throttles the destructive close-all side so repeated wake
        // callbacks do not look like a tunnel outage.
        pathMonitor.handleWake()
    }

    // MARK: - Setup

    private func startProxyCatLogFile() {
        do {
            let logPath = try ProxyCatLogPersistence.shared.start(directory: FilePath.logsDirectory)
            Self.logger.info("proxycat session log = \(logPath)")
        } catch {
            Self.logger.warning("could not open proxycat session log: \(error.localizedDescription)")
        }
    }

    /// Sets every path the Go core needs before Start. Idempotent — safe
    /// to call again on a future startTunnel after a reconnect.
    private func configureLibmihomoPaths() {
        // Tell mihomo to keep its mutable state (cache.db, downloaded
        // providers, external-ui) inside the App Group container. The
        // default ~/.config/mihomo path is unwritable in the iOS
        // Network Extension sandbox.
        LibmihomoBridge.setHomeDir(FilePath.workingDirectory.path)

        // Tell mihomo where to expose the gRPC command server. Same
        // path the host app's CommandClient dials. mihomo's REST API
        // remains user-facing (the in-app metacubexd web view still
        // uses HTTP loopback when enabled), and native UI controller
        // requests now ride this gRPC channel too.
        LibmihomoBridge.setCommandSocketPath(FilePath.commandSocketPath)

        // Tell mihomo where to bind its REST controller's Unix-domain
        // listener. `CommandClient.ControllerRequest` executes /proxies,
        // /connections, /group/.../delay, etc. against this private socket
        // inside the extension, so the host app never depends on the
        // toggleable loopback HTTP listener.
        LibmihomoBridge.setControllerSocketPath(FilePath.controllerSocketPath)

        // Wire the on-disk shared state Go reads on every Reload:
        // runtime_settings.json (active profile id, controller toggle,
        // log level), the profiles directory, and the profile catalog
        // JSON inside it.
        LibmihomoBridge.setRuntimeSettingsPath(FilePath.runtimeSettingsFilePath)
        LibmihomoBridge.setProfilesDir(FilePath.profilesDirectory.path)
        LibmihomoBridge.setProfileIndexPath(FilePath.profileIndexFilePath)

        // Where per-session log files land for the Saved Logs UI.
        LibmihomoBridge.setLogFileDir(FilePath.logsDirectory.path)
    }

    // MARK: - Network settings

    private func configureNetworkSettings() async throws {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")

        let ipv4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.0.0"])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        let ipv6 = NEIPv6Settings(addresses: ["fd00:7f::1"], networkPrefixLengths: [64])
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6

        let dns = NEDNSSettings(servers: ["198.18.0.2", "fd00:7f::2"])
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        settings.mtu = 1500

        try await setTunnelNetworkSettings(settings)
    }

    // MARK: - Memory pressure

    private func startMemoryMonitor() {
        MemoryMonitor.shared.start()
        memoryObserverToken = MemoryMonitor.shared.observe { [weak self] snapshot in
            self?.handleMemoryPressure(snapshot)
        }
    }

    private func handleMemoryPressure(_ snapshot: MemoryMonitor.Snapshot) {
        Self.logger.warning("memory pressure=\(snapshot.pressure.description) resident=\(snapshot.resident) available=\(snapshot.available)")
        switch snapshot.pressure {
        case .normal:
            return
        case .warning:
            // Logs flow through the gRPC stream to the host; nothing to
            // truncate here. The Go OOM killer also reacts on its own.
            break
        case .critical:
            LibmihomoBridge.closeAllConnections()
        }
    }
}

private struct PTPError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
