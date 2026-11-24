import Foundation
import Library
import Network

/// Watches the OS default network path and nudges mihomo when it changes.
///
/// iOS surfaces Wi-Fi ↔ cellular switches and post-sleep reconnects
/// through `NWPathMonitor`; mihomo's own `DefaultInterfaceMonitor`
/// can't run inside the NE sandbox (AF_ROUTE is blocked). Without this,
/// mihomo's interface cache and DNS upstream connections silently go
/// stale across a network change and the tunnel appears alive but
/// forwards nothing.
///
/// All mutable state lives on one serial queue. The class deliberately
/// owns the whole debounce / generation state machine so
/// `PacketTunnelProvider` only has to call `start`, `stop`, and
/// `handleWake`.
final class NetworkPathMonitor {
    private enum Baseline {
        case awaiting
        case sawUnsatisfied
        case established

        var logDescription: String {
            switch self {
            case .awaiting: return "awaiting"
            case .sawUnsatisfied: return "sawUnsatisfied"
            case .established: return "established"
            }
        }
    }

    /// Coarse normalized path identity. We intentionally ignore object
    /// identity and available-interface ordering so repeated callbacks for
    /// the same still-satisfied cellular path do not look like route changes.
    private struct PathSignature: Equatable {
        let status: String
        let expensive: Bool
        let constrained: Bool
        let supportsDNS: Bool
        let usesWiFi: Bool
        let usesCellular: Bool
        let usesWired: Bool
        let usesLoopback: Bool
        let usesOther: Bool
        let interfaces: [String]

        init(_ path: NWPath) {
            status = describe(path.status)
            expensive = path.isExpensive
            constrained = path.isConstrained
            supportsDNS = path.supportsDNS
            usesWiFi = path.usesInterfaceType(.wifi)
            usesCellular = path.usesInterfaceType(.cellular)
            usesWired = path.usesInterfaceType(.wiredEthernet)
            usesLoopback = path.usesInterfaceType(.loopback)
            usesOther = path.usesInterfaceType(.other)
            interfaces = Array(Set(path.availableInterfaces.map {
                "\($0.name):\(describe($0.type))"
            })).sorted()
        }
    }

    /// How long to coalesce NWPathMonitor updates before nudging mihomo.
    /// iOS often emits two or three updates back-to-back during a single
    /// transition (e.g. "Wi-Fi up but unsatisfied" → "cellular satisfied"
    /// → "Wi-Fi satisfied" all within a second); collapse them so mihomo
    /// only refreshes once per real-world transition.
    private static let pathChangeDebounce: DispatchTimeInterval = .milliseconds(500)
    private static let wakeConnectionCloseMinimumInterval: TimeInterval = 30

    private let logger: ProxyCatLogger
    private let queue = DispatchQueue(label: "io.proxycat.pcat.path", qos: .utility)

    private var monitor: NWPathMonitor?
    private var generation = 0
    private var baseline: Baseline = .awaiting
    private var currentSignature: PathSignature?
    private var pendingWorkItem: DispatchWorkItem?
    private var pendingClosesConnections = false
    private var pendingReason: String?
    private var lastWakeConnectionCloseAt: Date?

    init(logger: ProxyCatLogger) {
        self.logger = logger
    }

    func start() {
        guard monitor == nil else { return }
        let capturedGeneration: Int = queue.sync {
            resetState()
            return generation
        }

        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path, generation: capturedGeneration)
        }
        monitor.start(queue: queue)
        self.monitor = monitor
        logger.info("started NWPathMonitor generation=\(capturedGeneration)")
    }

    func stop() {
        if monitor != nil {
            logger.info("stopping NWPathMonitor")
        }
        monitor?.cancel()
        monitor = nil
        // Bump generation so any callback or work item still queued from
        // the canceled monitor bails before reaching mihomo.
        queue.sync { resetState() }
    }

    /// Treat every wake as a potential interface change, but throttle the
    /// destructive close-all side so repeated wake callbacks do not look
    /// like a tunnel outage.
    func handleWake() {
        queue.async { [weak self] in
            guard let self else { return }
            let closeConnections = self.shouldCloseConnectionsForWake()
            self.performPathRefresh(closeConnections: closeConnections, reason: "wake")
        }
        logger.info("wake -> scheduled mihomo path refresh")
    }

    // MARK: - State machine (queue-isolated)

    /// Bumps the generation counter and clears pending work + baseline.
    /// Must be called from `queue`.
    private func resetState() {
        generation += 1
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        pendingClosesConnections = false
        pendingReason = nil
        baseline = .awaiting
        currentSignature = nil
    }

    /// Routes each NWPathMonitor callback to either a debounced refresh
    /// or a baseline transition. iOS can emit repeated callbacks for the
    /// same still-satisfied path while the host app backgrounds; those
    /// must not close all tunneled connections. Real transitions still
    /// refresh mihomo and force active apps to reconnect through the
    /// fresh route.
    private func handlePathUpdate(_ path: NWPath, generation: Int) {
        guard generation == self.generation else { return }
        let signature = PathSignature(path)
        logger.info(
            "NWPathMonitor update generation=\(generation) baseline=\(baseline.logDescription) \(describe(path))"
        )

        switch baseline {
        case .established:
            guard path.status == .satisfied else {
                baseline = .sawUnsatisfied
                currentSignature = signature
                logger.info("NWPathMonitor baseline -> \(baseline.logDescription)")
                return
            }
            guard let previous = currentSignature else {
                currentSignature = signature
                return
            }
            guard previous != signature else {
                schedulePathRefresh(closeConnections: false, reason: "path update")
                return
            }
            currentSignature = signature
            schedulePathRefresh(closeConnections: true, reason: "path changed")
        case .awaiting:
            currentSignature = signature
            baseline = path.status == .satisfied ? .established : .sawUnsatisfied
            logger.info("NWPathMonitor baseline -> \(baseline.logDescription)")
        case .sawUnsatisfied:
            guard path.status == .satisfied else { return }
            currentSignature = signature
            baseline = .established
            schedulePathRefresh(closeConnections: true, reason: "path recovered")
        }
    }

    private func schedulePathRefresh(closeConnections: Bool, reason: String) {
        let captured = generation
        pendingClosesConnections = pendingClosesConnections || closeConnections
        if closeConnections || pendingReason == nil {
            pendingReason = reason
        }
        pendingWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, captured == self.generation else { return }
            let closeConnections = self.pendingClosesConnections
            let reason = self.pendingReason ?? reason
            self.pendingWorkItem = nil
            self.pendingClosesConnections = false
            self.pendingReason = nil
            self.performPathRefresh(closeConnections: closeConnections, reason: reason)
        }
        pendingWorkItem = work
        queue.asyncAfter(deadline: .now() + Self.pathChangeDebounce, execute: work)
    }

    private func performPathRefresh(closeConnections: Bool, reason: String) {
        LibmihomoBridge.notifyDefaultInterfaceChanged()
        if closeConnections {
            let closed = LibmihomoBridge.closeAllConnections()
            logger.info("refreshed mihomo path reason=\(reason), closed \(closed) connections")
        } else {
            logger.info("refreshed mihomo path reason=\(reason)")
        }
    }

    private func shouldCloseConnectionsForWake(now: Date = Date()) -> Bool {
        if let lastWakeConnectionCloseAt,
           now.timeIntervalSince(lastWakeConnectionCloseAt) < Self.wakeConnectionCloseMinimumInterval {
            return false
        }
        lastWakeConnectionCloseAt = now
        return true
    }

    // MARK: - Logging descriptions

    private func describe(_ path: NWPath) -> String {
        let interfaces = path.availableInterfaces
            .map { "\($0.name):\(Self.describe($0.type))" }
            .joined(separator: ",")
        let uses = [
            path.usesInterfaceType(.wifi) ? "wifi" : nil,
            path.usesInterfaceType(.cellular) ? "cellular" : nil,
            path.usesInterfaceType(.wiredEthernet) ? "wired" : nil,
            path.usesInterfaceType(.loopback) ? "loopback" : nil,
            path.usesInterfaceType(.other) ? "other" : nil,
        ]
        .compactMap { $0 }
        .joined(separator: ",")
        return "status=\(Self.describe(path.status)) expensive=\(path.isExpensive) constrained=\(path.isConstrained) dns=\(path.supportsDNS) uses=[\(uses)] interfaces=[\(interfaces)]"
    }

    private static func describe(_ status: NWPath.Status) -> String {
        switch status {
        case .satisfied: return "satisfied"
        case .unsatisfied: return "unsatisfied"
        case .requiresConnection: return "requiresConnection"
        @unknown default: return "unknown"
        }
    }

    private static func describe(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: return "wifi"
        case .cellular: return "cellular"
        case .wiredEthernet: return "wired"
        case .loopback: return "loopback"
        case .other: return "other"
        @unknown default: return "unknown"
        }
    }
}
