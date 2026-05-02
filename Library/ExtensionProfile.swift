import Combine
import Foundation
import NetworkExtension

/// Wraps NEVPNManager so the rest of the app never imports
/// NetworkExtension directly. Mirrors sing-box-for-apple's
/// ExtensionProfile.
///
/// The shape is deliberately small: `start()` and `stop()` for lifecycle,
/// `reload()` to nudge the extension after the host has written new
/// state to the App Group container. There are no per-setting methods
/// because the Go core re-reads settings.json + the active profile on
/// every reload — settings flow through the file system, not this API.
@MainActor
public final class ExtensionProfile: ObservableObject {
    @Published public private(set) var status: NEVPNStatus = .invalid
    @Published public private(set) var manager: NETunnelProviderManager?

    private var statusObserver: NSObjectProtocol?

    public init() {}

    public var isConnected: Bool {
        switch status {
        case .connected: return true
        default: return false
        }
    }

    public func load() async throws {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        let mgr: NETunnelProviderManager
        if let existing = managers.first {
            mgr = existing
        } else {
            mgr = NETunnelProviderManager()
            let proto = NETunnelProviderProtocol()
            proto.providerBundleIdentifier = AppConfiguration.extensionBundleID
            proto.serverAddress = "ProxyCat"
            mgr.protocolConfiguration = proto
            mgr.localizedDescription = "ProxyCat"
            mgr.isEnabled = true
            try await mgr.saveToPreferences()
            try await mgr.loadFromPreferences()
        }
        manager = mgr
        status = mgr.connection.status
        attachObserver(mgr)
    }

    public func start() async throws {
        guard let manager else { throw ExtensionProfileError.notLoaded }
        if !manager.isEnabled {
            // Re-enabling has to be persisted before startVPNTunnel will
            // accept it. Awaiting inline lets the caller surface real
            // save errors and avoids the previous retry round-trip.
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        }
        // No options dictionary: the extension reads the active profile
        // YAML and runtime settings from the App Group container itself.
        try manager.connection.startVPNTunnel(options: nil)
    }

    public func stop() {
        manager?.connection.stopVPNTunnel()
    }

    /// Asks the running tunnel to hot-reload from disk. Triggered by the
    /// host whenever the user changes the active profile, edits the
    /// active YAML, or toggles a runtime setting — the Go core re-reads
    /// everything fresh, so a single call covers all three flows.
    ///
    /// No-op (and not an error) when the tunnel isn't connected: the
    /// next `start()` already reads the latest disk state.
    ///
    /// Throws if the extension reports a reload failure (e.g. invalid
    /// YAML on disk). The caller decides whether to surface that to the
    /// user or fall back to disconnect+reconnect.
    public func reload() async throws {
        try await sendCommand("reload", failureLabel: "Reload failed")
    }

    /// Pushes a runtime log-level change to the extension without going
    /// through the heavyweight reload path. Mihomo's filter is just one
    /// atomic; rebuilding proxies/listeners/rules to update it would be
    /// gratuitous (mihomo's own /configs PATCH handler also updates the
    /// level by calling `log.SetLevel` directly).
    ///
    /// Levels: 0=DEBUG 1=INFO 2=WARNING 3=ERROR 4=SILENT. Out-of-range
    /// values are clamped on the Go side.
    ///
    /// No-op when disconnected; the next `start()` reads the new level
    /// from settings.json.
    public func setLogLevel(_ level: Int) async throws {
        try await sendCommand("setLogLevel:\(level)", failureLabel: "Log level update failed")
    }

    /// How long to wait for the extension to reply to a provider
    /// message before giving up. The extension's handlers are short —
    /// a `reload` runs `hub.ApplyConfig` which historically completes
    /// in well under 1s. A 10s ceiling surfaces a hung extension as a
    /// proper error rather than a UI that just freezes.
    private static let providerMessageTimeout: Duration = .seconds(10)

    private func sendCommand(_ command: String, failureLabel: String) async throws {
        guard isConnected, let session = manager?.connection as? NETunnelProviderSession else {
            return
        }
        guard let payload = command.data(using: .utf8) else { return }

        let response = try await withTimeout(Self.providerMessageTimeout) {
            try await Self.sendProviderMessage(payload, on: session)
        }

        if let response, !response.isEmpty {
            let message = String(data: response, encoding: .utf8) ?? failureLabel
            throw ExtensionProfileError.reloadFailed(message)
        }
    }

    private static func sendProviderMessage(
        _ payload: Data,
        on session: NETunnelProviderSession
    ) async throws -> Data? {
        try await withCheckedThrowingContinuation { cont in
            // Resume exactly once. A continuation with both the timeout
            // path and sendProviderMessage's completion handler racing
            // would otherwise crash with "resumed more than once" if the
            // OS delivered the reply just as we were giving up.
            let resumed = ManagedResume(continuation: cont)
            do {
                try session.sendProviderMessage(payload) { data in
                    resumed.resume(returning: data)
                }
            } catch {
                resumed.resume(throwing: error)
            }
        }
    }

    private func withTimeout<T: Sendable>(
        _ duration: Duration,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: duration)
                throw ExtensionProfileError.timeout
            }
            // First child to finish wins; cancel the remaining one.
            guard let first = try await group.next() else {
                throw ExtensionProfileError.timeout
            }
            group.cancelAll()
            return first
        }
    }

    /// Pushes the user's Auto Connect configuration onto the
    /// NETunnelProviderManager: flips `isOnDemandEnabled` and rebuilds
    /// the `onDemandRules` array, then persists. Idempotent — if the
    /// derived state already matches what the manager has, the
    /// `saveToPreferences` is still cheap. Safe to call while
    /// connected; iOS picks up the new rules on the next network
    /// change without restarting the tunnel.
    public func applyAutoConnect(_ config: AutoConnectConfig) async throws {
        guard let manager else { return }
        manager.isOnDemandEnabled = config.enabled
        manager.onDemandRules = Self.buildOnDemandRules(from: config)
        try await manager.saveToPreferences()
        // Re-read so the in-memory manager mirrors what the system
        // actually persisted (saveToPreferences can normalize fields).
        // Mirrors the save+load pattern in load() and start().
        try await manager.loadFromPreferences()
    }

    private static func buildOnDemandRules(from c: AutoConnectConfig) -> [NEOnDemandRule] {
        var rules: [NEOnDemandRule] = []

        // SSID-specific rules first; first-match wins, so they always
        // override the cellular and fallback rules below.
        for r in c.ssidRules where !r.ssid.isEmpty {
            let rule = makeOnDemandRule(for: r.action)
            rule.interfaceTypeMatch = .wiFi
            rule.ssidMatch = [r.ssid]
            rules.append(rule)
        }

        let cell = makeOnDemandRule(for: c.cellular)
        cell.interfaceTypeMatch = .cellular
        rules.append(cell)

        // Final fallback — `.any` matches anything not yet matched,
        // including Wi-Fi networks the user has not named.
        let fallback = makeOnDemandRule(for: c.fallback)
        fallback.interfaceTypeMatch = .any
        rules.append(fallback)

        return rules
    }

    private static func makeOnDemandRule(for action: AutoConnectAction) -> NEOnDemandRule {
        switch action {
        case .connect:    return NEOnDemandRuleConnect()
        case .disconnect: return NEOnDemandRuleDisconnect()
        case .ignore:     return NEOnDemandRuleIgnore()
        }
    }

    private func attachObserver(_ manager: NETunnelProviderManager) {
        if let token = statusObserver {
            NotificationCenter.default.removeObserver(token)
        }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self] note in
            guard let conn = note.object as? NEVPNConnection else { return }
            let status = conn.status
            Task { @MainActor in
                self?.status = status
            }
        }
    }

    deinit {
        if let token = statusObserver {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

public enum ExtensionProfileError: LocalizedError {
    case notLoaded
    case reloadFailed(String)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .notLoaded: return String(localized: "VPN configuration not loaded", bundle: .main)
        case let .reloadFailed(message): return message
        case .timeout: return String(localized: "Extension did not respond in time", bundle: .main)
        }
    }
}

/// One-shot guard around a `CheckedContinuation` so callers can race
/// timeout against a callback without risking a double-resume crash.
private final class ManagedResume<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(returning value: T) {
        guard let cont = take() else { return }
        cont.resume(returning: value)
    }

    func resume(throwing error: Error) {
        guard let cont = take() else { return }
        cont.resume(throwing: error)
    }

    private func take() -> CheckedContinuation<T, Error>? {
        lock.lock()
        defer { lock.unlock() }
        let c = continuation
        continuation = nil
        return c
    }
}
