import Darwin
import Foundation
import Library
import Libmihomo
import NetworkExtension
import os.log

/// The Network Extension entry point. Heavy lifting (memory management,
/// gomobile bridge, gRPC command server) lives here; UI lives in
/// Pcat / ApplicationLibrary.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private static let logger = Logger(subsystem: "io.proxycat.Pcat.PcatExtension", category: "PTP")

    private var memoryObserverToken: UUID?

    // MARK: - Lifecycle

    override func startTunnel(options: [String: NSObject]?) async throws {
        Self.logger.info("startTunnel")

        guard let yaml = (options?[AppConfiguration.configContentKey] as? String), !yaml.isEmpty else {
            throw PTPError("missing \(AppConfiguration.configContentKey) in startTunnel options")
        }

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

        // 4a. Tell mihomo to keep its mutable state (cache.db, downloaded
        //     providers, external-ui) inside the App Group container. The
        //     default ~/.config/mihomo path is unwritable in the iOS
        //     Network Extension sandbox.
        LibmihomoBridge.setHomeDir(FilePath.workingDirectory.path)

        // 4a.i. Seed compile-time bundled geo databases and external UI
        //       into the working directory so mihomo finds them on first
        //       run before any download happens. Idempotent — already-up-
        //       to-date assets are skipped.
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

        // 4c. Tell mihomo where to expose the gRPC command server. Same
        //     path the host app's CommandClient dials. mihomo's REST API
        //     (external-controller, port 9090) is intentionally not used
        //     for IPC — that surface is reserved for the end-user.
        LibmihomoBridge.setCommandSocketPath(FilePath.commandSocketPath)

        // 4d. Push the iOS fd into mihomo before starting so the parsed
        //     YAML's TUN inbound binds to the kernel-supplied fd and we
        //     overwrite address fields that don't apply on iOS.
        try LibmihomoBridge.setTunFd(Int(fd))

        // 4e. Open a per-session log file and tee mihomo's log stream
        //     into it. The host app reads from FilePath.logsDirectory
        //     to surface them in the Saved Logs list. Failures here
        //     are non-fatal: the live log stream still works.
        LibmihomoBridge.setLogFileDir(FilePath.logsDirectory.path)
        do {
            let logPath = try LibmihomoBridge.startLogFile()
            Self.logger.info("session log → \(logPath, privacy: .public)")
        } catch {
            Self.logger.warning("could not open session log: \(error.localizedDescription, privacy: .public)")
        }

        // 5. Start mihomo with the YAML. Start() also brings up the
        //    Unix-domain gRPC server at the path set in step 4c.
        guard let yamlData = yaml.data(using: .utf8) else {
            throw PTPError("config YAML not utf8")
        }
        try LibmihomoBridge.start(yaml: yamlData)

        Self.logger.info("startTunnel done")
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        Self.logger.info("stopTunnel reason=\(reason.rawValue, privacy: .public)")
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

    override func wake() {}

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        // Reserved for future host-app commands (e.g. reload config).
        // Streaming status / logs go through the gRPC channel, not here.
        if let cmd = String(data: messageData, encoding: .utf8) {
            switch cmd {
            case "ping":
                return "pong".data(using: .utf8)
            case let s where s.hasPrefix("loglevel:"):
                let raw = Int(s.dropFirst("loglevel:".count)) ?? 1
                LibmihomoBridge.setLogLevel(raw)
                return nil
            default:
                return nil
            }
        }
        return nil
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
}

private struct PTPError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
