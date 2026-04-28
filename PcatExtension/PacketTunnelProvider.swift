import Darwin
import Foundation
import Library
import Libmihomo
import NetworkExtension
import os.log

/// The Network Extension entry point. Heavy-lifting for memory management
/// and the gomobile bridge lives here; UI lives in Pcat / ApplicationLibrary.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private static let logger = Logger(subsystem: "io.proxycat.Pcat.PcatExtension", category: "PTP")

    private var memoryObserverToken: UUID?
    private var logSubID: Int64 = 0
    private var trafficTimer: DispatchSourceTimer?
    private let mirrorQueue = DispatchQueue(label: "io.proxycat.mirror", qos: .utility)
    private var logSink: FileHandle?

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

        // 4. Open a streaming sink for logs in the shared container.
        prepareLogMirror()

        // 5. Subscribe to mihomo logs (gomobile callback). Forward each log
        //    line to the host app via the shared file. Hot path — keep
        //    allocation minimal.
        let bridge = LogBridge { [weak self] level, message in
            self?.appendLog(level: level, message: message)
        }
        logSubID = LibmihomoBridge.subscribeLogs(bridge)

        // 6a. Tell mihomo to keep its mutable state (cache.db, downloaded
        //     providers, external-ui) inside the App Group container. The
        //     default ~/.config/mihomo path is unwritable in the iOS
        //     Network Extension sandbox.
        LibmihomoBridge.setHomeDir(FilePath.workingDirectory.path)

        // 6b. Tell the Go OOM killer the actual iOS budget (resident +
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

        // 6c. Push the iOS fd into mihomo before starting so the parsed
        //     YAML's TUN inbound binds to the kernel-supplied fd and we
        //     overwrite address fields that don't apply on iOS.
        try LibmihomoBridge.setTunFd(Int(fd))

        // 7. Start mihomo with the YAML.
        guard let yamlData = yaml.data(using: .utf8) else {
            throw PTPError("config YAML not utf8")
        }
        try LibmihomoBridge.start(yaml: yamlData)

        // 8. Begin mirroring traffic stats once a second so the host app
        //    dashboard has data to read without IPC.
        startTrafficMirror()

        Self.logger.info("startTunnel done")
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        Self.logger.info("stopTunnel reason=\(reason.rawValue, privacy: .public)")
        trafficTimer?.cancel()
        trafficTimer = nil
        if logSubID != 0 {
            LibmihomoBridge.unsubscribeLogs(logSubID)
            logSubID = 0
        }
        LibmihomoBridge.stop()
        try? logSink?.close()
        logSink = nil
        if let token = memoryObserverToken {
            MemoryMonitor.shared.remove(token)
            memoryObserverToken = nil
        }
        MemoryMonitor.shared.stop()
    }

    override func sleep() async {
        // The OS asks us to quiet down. Drop log mirror frequency and idle
        // connections, but keep the tunnel alive.
        trafficTimer?.cancel()
        trafficTimer = nil
    }

    override func wake() {
        startTrafficMirror()
    }

    override func handleAppMessage(_ messageData: Data) async -> Data? {
        // Reserved for future host-app commands (reload config, set log level).
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
    ///
    /// Returns `-1` on simulator (no real utun is created) or when the
    /// extension was launched without `setTunnelNetworkSettings` having
    /// completed.
    private func packetFlowFileDescriptor() -> Int32 {
        // 1) Try KVC paths.
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

        // 2) Walk the FD table looking for the utun control socket.
        if let fd = findUtunFD() {
            Self.logger.info("found tun fd by enumeration = \(fd, privacy: .public)")
            return fd
        }

        let className = String(describing: type(of: self.packetFlow))
        Self.logger.error("KVC and FD enumeration both failed; packetFlow class=\(className, privacy: .public)")
        return -1
    }

    /// Returns the fd of the utun control socket created by
    /// `setTunnelNetworkSettings`, or nil if none is found.
    ///
    /// We manually decode `sockaddr_ctl` because `<sys/kern_control.h>`
    /// isn't part of Swift's Darwin module on iOS. utun sockets are
    /// `AF_SYSTEM`/`AF_SYS_CONTROL`, both defined in `<sys/socket.h>` /
    /// `<sys/kern_control.h>` as constants we hardcode below.
    private func findUtunFD() -> Int32? {
        // sys/socket.h: AF_SYSTEM = 32
        let kAF_SYSTEM: UInt8 = 32
        // sys/kern_control.h: AF_SYS_CONTROL = 2
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
            // sockaddr_ctl layout: { u8 sc_len; u8 sc_family; u16 ss_sysaddr; ...}
            // ss_family alone (sockaddr_storage) is u8 at offset 1 on Darwin.
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
            // Kick log mirror into a less chatty rhythm by truncating the
            // shared file. The host app already has the bytes it needs.
            mirrorQueue.async { [weak self] in self?.truncateLogMirror() }
        case .critical:
            mirrorQueue.async { [weak self] in self?.truncateLogMirror() }
            LibmihomoBridge.closeAllConnections()
        }
    }

    // MARK: - Log mirror

    private func prepareLogMirror() {
        let url = FilePath.cacheDirectory.appendingPathComponent("ne.log")
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        logSink = try? FileHandle(forWritingTo: url)
        try? logSink?.seekToEnd()
    }

    private func truncateLogMirror() {
        let url = FilePath.cacheDirectory.appendingPathComponent("ne.log")
        try? Data().write(to: url, options: .atomic)
        try? logSink?.close()
        logSink = try? FileHandle(forWritingTo: url)
    }

    private func appendLog(level: Int, message: String) {
        // Off the gomobile callback thread to avoid blocking Go's logger.
        mirrorQueue.async { [weak self] in
            guard let sink = self?.logSink else { return }
            // Format: "<level>\t<message>\n"
            let line = "\(level)\t\(message)\n"
            if let data = line.data(using: .utf8) {
                try? sink.write(contentsOf: data)
            }
        }
    }

    // MARK: - Traffic mirror

    private func startTrafficMirror() {
        let timer = DispatchSource.makeTimerSource(queue: mirrorQueue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.flushTraffic() }
        timer.resume()
        trafficTimer = timer
    }

    private func flushTraffic() {
        guard let snapshot = LibmihomoBridge.trafficNow() else { return }
        // Memory must be sampled inside the extension — the host app's
        // process has its own (much larger) memory budget so reading it
        // there would be misleading. Write the extension's phys_footprint
        // and remaining bytes into the shared snapshot for the dashboard.
        let memory = MemoryMonitor.snapshot()
        let dict: [String: Any] = [
            "up": snapshot.up,
            "down": snapshot.down,
            "upTotal": snapshot.uploadTotal,
            "downTotal": snapshot.downloadTotal,
            "connections": snapshot.connections,
            "memoryResident": memory.resident,
            "memoryAvailable": memory.available,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: dict) {
            let url = FilePath.cacheDirectory.appendingPathComponent("traffic.json")
            try? data.write(to: url, options: .atomic)
        }
    }
}

// MARK: - Helpers

private struct PTPError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Bridge that adapts a Swift closure to the gomobile-generated
/// `LibmihomoLogDelegate` protocol. The protocol declaration comes from the
/// gomobile bind output (`OnLog(_ level: Int, _ message: String)`).
private final class LogBridge: NSObject, LibmihomoLogDelegateProtocol {
    private let handler: (Int, String) -> Void
    init(_ handler: @escaping (Int, String) -> Void) {
        self.handler = handler
    }
    func onLog(_ level: Int, message: String?) {
        handler(level, message ?? "")
    }
}
