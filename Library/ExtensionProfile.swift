import Foundation
import Observation
// NetworkExtension predates Swift concurrency annotations; types like
// NETunnelProviderSession aren't formally Sendable but are fine to pass
// across actors for the call patterns we use. @preconcurrency demotes
// the resulting Sendable diagnostics to warnings.
@preconcurrency import NetworkExtension

/// Wraps NEVPNManager so the rest of the app never imports
/// NetworkExtension directly. Mirrors sing-box-for-apple's
/// ExtensionProfile.
///
/// The shape is deliberately small: `start()` and `stop()` for
/// lifecycle, `applyAutoConnect` for on-demand rules. Reload and
/// log-level changes flow through `CommandClient` (gRPC) instead — the
/// extension reads runtime_settings.json on every Start / Reload, so
/// settings travel through the file system + a single gRPC nudge, not
/// through `sendProviderMessage`.
@MainActor @Observable
public final class ExtensionProfile {
    public private(set) var status: NEVPNStatus = .invalid
    public private(set) var manager: NETunnelProviderManager?

    @ObservationIgnored private var statusObservationTask: Task<Void, Never>?

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
        statusObservationTask?.cancel()
        let connection = manager.connection
        statusObservationTask = Task { @MainActor [weak self] in
            for await note in NotificationCenter.default.notifications(named: .NEVPNStatusDidChange, object: connection) {
                guard let conn = note.object as? NEVPNConnection else { continue }
                self?.status = conn.status
            }
        }
    }

    deinit {
        statusObservationTask?.cancel()
    }
}

public enum ExtensionProfileError: LocalizedError {
    case notLoaded

    public var errorDescription: String? {
        switch self {
        case .notLoaded: return String(localized: "VPN configuration not loaded", bundle: .main)
        }
    }
}
