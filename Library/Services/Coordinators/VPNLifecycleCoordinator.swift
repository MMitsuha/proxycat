import Foundation
import NetworkExtension

// MARK: - VPN lifecycle

/// Mirrors NEVPNStatus to the gRPC `CommandClient`'s connect/disconnect.
/// The command client must come up while the VPN is `.connecting` so log
/// + traffic streams are available the moment the tunnel finishes
/// negotiating, and tear down cleanly when the user disconnects.
@MainActor
public final class VPNLifecycleCoordinator {
    private let profile: ExtensionProfile
    private let commandClient: CommandClient
    private var observationTask: Task<Void, Never>?

    public init(profile: ExtensionProfile, commandClient: CommandClient) {
        self.profile = profile
        self.commandClient = commandClient
    }

    public func start() {
        // Honor the current state immediately for cold launches that
        // resume an already-connected VPN session.
        apply(profile.status)
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // dropFirst skips the initial replay we already applied above.
            for await status in Observed.values({ self.profile.status }).dropFirst() {
                self.apply(status)
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }

    private func apply(_ status: NEVPNStatus) {
        switch status {
        case .connecting, .connected, .reasserting:
            commandClient.connect()
        case .disconnecting, .disconnected, .invalid:
            commandClient.disconnect()
        @unknown default:
            commandClient.disconnect()
        }
    }
}
