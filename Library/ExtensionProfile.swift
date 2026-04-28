import Combine
import Foundation
import NetworkExtension

/// Wraps NEVPNManager so the rest of the app never imports
/// NetworkExtension directly. Mirrors sing-box-for-apple's ExtensionProfile.
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

    public func start(configContent: String) async throws {
        guard let manager else { throw ExtensionProfileError.notLoaded }
        if !manager.isEnabled {
            // Re-enabling has to be persisted before startVPNTunnel will
            // accept it. Awaiting inline lets the caller surface real
            // save errors and avoids the previous retry round-trip.
            manager.isEnabled = true
            try await manager.saveToPreferences()
            try await manager.loadFromPreferences()
        }
        var options: [String: NSObject] = [:]
        options[AppConfiguration.configContentKey] = configContent as NSString
        try manager.connection.startVPNTunnel(options: options)
    }

    public func stop() {
        manager?.connection.stopVPNTunnel()
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

    public var errorDescription: String? {
        switch self {
        case .notLoaded: return "VPN configuration not loaded"
        }
    }
}
