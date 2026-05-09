import Darwin
import Foundation
import Library
// gomobile + NetworkExtension predate Swift concurrency annotations;
// @preconcurrency demotes the resulting Sendable diagnostics on
// override signatures and Go-bridge calls to warnings.
@preconcurrency import Libmihomo
import Network
@preconcurrency import NetworkExtension
import os.log

/// Network Extension entry point. Intentionally a thin shim — the Go
/// core owns all runtime state (YAML, settings, log level, controller
/// config), and we only configure paths once and trigger lifecycle
/// events. A setting toggled in the host UI propagates by writing
/// runtime_settings.json (which Go re-reads) and a gRPC `Reload` /
/// `SetLogLevel` RPC handled inside the embedded command server. This
/// type owns no business logic of its own.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private static let logger = Logger(subsystem: "io.proxycat.Pcat.PcatExtension", category: "PTP")

    private var memoryObserverToken: UUID?

    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "io.proxycat.pcat.path", qos: .utility)
    private var pathMonitorGeneration = 0
    private var pathBaseline: PathBaselineState = .awaiting
    private var pendingPathChangeWorkItem: DispatchWorkItem?

    /// Whether NWPathMonitor has delivered a usable path yet. Suppresses
    /// the very first satisfied callback because mihomo just started —
    /// its caches are fresh, nothing is stale to flush. But if startup
    /// first observed an unsatisfied path, the later satisfied callback
    /// is a real offline→online transition and should refresh mihomo.
    private enum PathBaselineState {
        case awaiting
        case sawUnsatisfied
        case established
    }

    /// How long to coalesce NWPathMonitor updates before nudging mihomo.
    /// iOS often emits two or three updates back-to-back during a single
    /// transition (e.g. "Wi-Fi up but unsatisfied" → "cellular satisfied"
    /// → "Wi-Fi satisfied" all within a second); collapse them so mihomo
    /// only refreshes once per real-world transition.
    private static let pathChangeDebounce: DispatchTimeInterval = .milliseconds(500)

    // MARK: - Lifecycle

    override func startTunnel(options _: [String: NSObject]?) async throws {
        Self.logger.info("startTunnel")

        // 1. Configure tunnel network settings *before* taking the fd. iOS
        //    materializes the utun device only after this completes.
        try await configureNetworkSettings()

        // 2. Acquire file descriptor for the packet flow. NEPacketTunnelFlow
        //    doesn't expose this publicly; we try several KVC paths used by
        //    different iOS versions, then fall back to enumerating the
        //    process's file descriptors and picking out the utun control
        //    socket — the same trick libbox uses for sing-box.
        let fd = packetFlowFileDescriptor()
        guard fd > 0 else {
            throw PTPError("could not obtain TUN file descriptor — likely running on simulator (no real utun) or KVC path changed in this iOS version")
        }
        Self.logger.info("packet flow fd = \(fd, privacy: .public)")

        // 3. Wire memory monitor *before* loading mihomo so we can already
        //    react if the bind itself spikes memory.
        startMemoryMonitor()

        // 4. Tell the Go core where every shared file lives. After this
        //    point Start / Reload re-read the active YAML and runtime
        //    settings on their own — nothing flows through this
        //    extension's options dictionary. Host commands ride the gRPC
        //    command service (Reload / SetLogLevel RPCs).
        configureLibmihomoPaths()

        // 4a. Seed compile-time bundled geo databases and external UI
        //     into the working directory so mihomo finds them on first
        //     run before any download happens. Idempotent — already-up-
        //     to-date assets are skipped.
        BundledAssets.installIfNeeded()

        // 4b. Tell the Go OOM killer the actual iOS budget (resident +
        //     available) instead of the 50 MB sing-box default. iOS
        //     doesn't expose the real jetsam limit; this approximation
        //     captures it the moment we ask, before mihomo allocates much.
        let resident = MemoryMonitor.residentBytes()
        let available = MemoryMonitor.availableBytes()
        let budget = Int64(resident + available)
        if budget > 0 {
            LibmihomoBridge.setMemoryLimit(budget)
            Self.logger.info("OOM budget set to \(budget, privacy: .public) (resident=\(resident, privacy: .public) available=\(available, privacy: .public))")
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
            Self.logger.info("session log → \(logPath, privacy: .public)")
        } catch {
            Self.logger.warning("could not open session log: \(error.localizedDescription, privacy: .public)")
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
        startPathMonitor()

        Self.logger.info("startTunnel done")
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        Self.logger.info("stopTunnel reason=\(reason.rawValue, privacy: .public)")
        stopPathMonitor()
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
    }

    override func sleep() async {
        // The OS asks us to quiet down. mihomo's command server keeps
        // serving so the host app can still see status if it foregrounds.
    }

    override func wake() {
        // Belt-and-suspenders for the case where iOS quietly swapped the
        // default route during deep sleep without letting our
        // NWPathMonitor witness the transition. Treat every wake as a
        // potential interface change — the notify is idempotent (cache
        // flush + DNS upstream reset + tunneled-connection close) and a
        // no-op if mihomo already saw the same path.
        LibmihomoBridge.notifyDefaultInterfaceChanged()
        Self.logger.info("wake → notified mihomo of possible interface change")
    }

    // MARK: - Setup

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
        // uses HTTP loopback when enabled), but the host app's native
        // UI dials a sibling Unix socket instead — see below.
        LibmihomoBridge.setCommandSocketPath(FilePath.commandSocketPath)

        // Tell mihomo where to bind its REST controller's Unix-domain
        // listener. The host app's `MihomoController` and
        // `ConnectionsStore` dial this socket so /proxies, /connections,
        // and /group/.../delay traffic stays in the App Group sandbox
        // instead of the toggleable loopback HTTP listener.
        LibmihomoBridge.setControllerSocketPath(FilePath.controllerSocketPath)

        // Wire the on-disk shared state Go reads on every Reload:
        // runtime_settings.json (active profile id, controller toggle,
        // log level) and the profiles directory.
        LibmihomoBridge.setRuntimeSettingsPath(FilePath.runtimeSettingsFilePath)
        LibmihomoBridge.setProfilesDir(FilePath.profilesDirectory.path)

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

    /// Find the file descriptor backing the iOS packet flow.
    ///
    /// Strategies, in order:
    ///   1. KVC against several historically-known key paths.
    ///   2. Enumerate process FDs and pick the one whose peer is an
    ///      `AF_SYSTEM` control socket (utun). This is what libbox does
    ///      when KVC fails on newer iOS.
    private func packetFlowFileDescriptor() -> Int32 {
        let candidates = [
            "socket.fileDescriptor",
            "_socket.fileDescriptor",
            "socket._fileDescriptor",
            "_socket._fileDescriptor",
        ]
        for keyPath in candidates {
            if let n = packetFlow.value(forKeyPath: keyPath) as? NSNumber {
                let fd = n.int32Value
                if fd > 0 {
                    Self.logger.info("found tun fd via KVC \(keyPath, privacy: .public) = \(fd, privacy: .public)")
                    return fd
                }
            }
            if let fd = packetFlow.value(forKeyPath: keyPath) as? Int32, fd > 0 {
                Self.logger.info("found tun fd via KVC \(keyPath, privacy: .public) = \(fd, privacy: .public)")
                return fd
            }
        }

        if let fd = findUtunFD() {
            Self.logger.info("found tun fd by enumeration = \(fd, privacy: .public)")
            return fd
        }

        let className = String(describing: type(of: self.packetFlow))
        Self.logger.error("KVC and FD enumeration both failed; packetFlow class=\(className, privacy: .public)")
        return -1
    }

    /// Returns the fd of the utun control socket created by
    /// `setTunnelNetworkSettings`, or nil if none is found. We manually
    /// decode `sockaddr_ctl` because `<sys/kern_control.h>` isn't part
    /// of Swift's Darwin module on iOS.
    private func findUtunFD() -> Int32? {
        let kAF_SYSTEM: UInt8 = 32
        let kAF_SYS_CONTROL: UInt16 = 2
        let limit = Int32(getdtablesize())
        var storage = sockaddr_storage()
        for fd in 0 ..< limit {
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let result = withUnsafeMutablePointer(to: &storage) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    getpeername(fd, saPtr, &len)
                }
            }
            guard result == 0 else { continue }
            let scFamily: UInt8 = withUnsafeBytes(of: storage) { raw in raw[1] }
            guard scFamily == kAF_SYSTEM else { continue }
            let ssSysaddr: UInt16 = withUnsafeBytes(of: storage) { raw in
                raw.load(fromByteOffset: 2, as: UInt16.self)
            }
            if ssSysaddr == kAF_SYS_CONTROL {
                return fd
            }
        }
        return nil
    }

    // MARK: - Memory pressure

    private func startMemoryMonitor() {
        MemoryMonitor.shared.start()
        memoryObserverToken = MemoryMonitor.shared.observe { [weak self] pressure in
            self?.handleMemoryPressure(pressure)
        }
    }

    private func handleMemoryPressure(_ pressure: MemoryMonitor.Pressure) {
        let avail = MemoryMonitor.availableBytes()
        Self.logger.warning("memory pressure=\(String(describing: pressure), privacy: .public) avail=\(avail, privacy: .public)")
        switch pressure {
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

    // MARK: - Network path

    private func startPathMonitor() {
        guard pathMonitor == nil else { return }
        let generation: Int = pathMonitorQueue.sync {
            resetPathMonitorState()
            return pathMonitorGeneration
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path, generation: generation)
        }
        monitor.start(queue: pathMonitorQueue)
        pathMonitor = monitor
    }

    private func stopPathMonitor() {
        pathMonitor?.cancel()
        pathMonitor = nil
        // Bump generation so any callback or work item still queued from
        // the canceled monitor bails before reaching mihomo.
        pathMonitorQueue.sync { resetPathMonitorState() }
    }

    /// Bumps the generation counter and clears pending work + baseline.
    /// Must be called from `pathMonitorQueue`.
    private func resetPathMonitorState() {
        pathMonitorGeneration += 1
        pendingPathChangeWorkItem?.cancel()
        pendingPathChangeWorkItem = nil
        pathBaseline = .awaiting
    }

    /// Routes each NWPathMonitor callback to either a debounced notify
    /// or a baseline transition. We deliberately don't fingerprint the
    /// path to detect "real" changes — same-name reconnects (Wi-Fi DHCP
    /// renewal, cellular APN refresh, post-sleep gateway swap) keep the
    /// same `(name, index)` while invalidating the underlying socket
    /// bindings, and missing those is the whole class of bug this fix
    /// exists to address. NWPathMonitor's own event coalescing plus the
    /// 500ms debounce keep the call rate reasonable.
    private func handlePathUpdate(_ path: Network.NWPath, generation: Int) {
        guard generation == pathMonitorGeneration else { return }
        pendingPathChangeWorkItem?.cancel()

        switch pathBaseline {
        case .established:
            schedulePathChangeNotification()
        case .awaiting:
            pathBaseline = path.status == .satisfied ? .established : .sawUnsatisfied
        case .sawUnsatisfied:
            guard path.status == .satisfied else { return }
            pathBaseline = .established
            schedulePathChangeNotification()
        }
    }

    private func schedulePathChangeNotification() {
        let captured = pathMonitorGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self, captured == self.pathMonitorGeneration else { return }
            LibmihomoBridge.notifyDefaultInterfaceChanged()
            Self.logger.info("notified mihomo of default interface change")
        }
        pendingPathChangeWorkItem = work
        pathMonitorQueue.asyncAfter(deadline: .now() + Self.pathChangeDebounce, execute: work)
    }
}

private struct PTPError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
