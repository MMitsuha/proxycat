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
        guard isConnected, let session = manager?.connection as? NETunnelProviderSession else {
            return
        }
        guard let payload = "reload".data(using: .utf8) else { return }

        let response: Data? = try await withCheckedThrowingContinuation { cont in
            do {
                try session.sendProviderMessage(payload) { data in
                    cont.resume(returning: data)
                }
            } catch {
                cont.resume(throwing: error)
            }
        }

        if let response, !response.isEmpty {
            let message = String(data: response, encoding: .utf8) ?? "Reload failed"
            throw ExtensionProfileError.reloadFailed(message)
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

    public var errorDescription: String? {
        switch self {
        case .notLoaded: return String(localized: "VPN configuration not loaded", bundle: .main)
        case let .reloadFailed(message): return message
        }
    }
}
