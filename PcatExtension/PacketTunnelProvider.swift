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
        //    doesn't expose this publicly; use KVC. Same approach used by
        //    sing-box-for-apple, Clash, Stash, Quantumult.
        let fd = packetFlowFileDescriptor()
        guard fd > 0 else {
            throw PTPError("could not obtain TUN file descriptor")
        }
        Self.logger.info("packet flow fd = \(fd)")

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

        // 6. Push the iOS fd into mihomo before starting so the parsed YAML's
        //    TUN inbound binds to the kernel-supplied fd.
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

    private func packetFlowFileDescriptor() -> Int32 {
        // NEPacketTunnelFlow has a private socket.fileDescriptor key. This
        // is the standard cross-vendor approach for fd-based TUN integration.
        if let fd = packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            return fd
        }
        if let n = packetFlow.value(forKeyPath: "socket.fileDescriptor") as? NSNumber {
            return n.int32Value
        }
        return -1
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
        let dict: [String: Any] = [
            "up": snapshot.up,
            "down": snapshot.down,
            "upTotal": snapshot.uploadTotal,
            "downTotal": snapshot.downloadTotal,
            "connections": snapshot.connections,
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
