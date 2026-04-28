import Combine
import Foundation
import NetworkExtension

/// Single object injected as @EnvironmentObject so views can reach the VPN
/// profile and the streaming command client without prop-drilling.
///
/// Owns the lifetime of the gRPC `CommandClient`: starts it as soon as the
/// VPN reaches `.connecting` / `.connected` and stops it on disconnect.
/// Views just read `@Published` traffic/memory/logs — none of them need to
/// call `connect()` themselves any more.
@MainActor
public final class ExtensionEnvironment: ObservableObject {
    public let profile: ExtensionProfile
    public let commandClient: CommandClient

    /// Persisted across log view appearances so the user's search term
    /// survives navigation. Mirrors sing-box-for-apple's logSearchText.
    @Published public var logSearchText: String = ""

    private var statusObservation: AnyCancellable?

    public init() {
        Self.bootstrapMihomoPaths()
        self.profile = ExtensionProfile()
        self.commandClient = CommandClient()
    }

    public init(profile: ExtensionProfile, commandClient: CommandClient) {
        Self.bootstrapMihomoPaths()
        self.profile = profile
        self.commandClient = commandClient
    }

    // The host app process has its own Go runtime, so the extension's
    // SetHomeDir doesn't propagate. Without this, validate() lets mihomo
    // fall back to ~/.config/mihomo which doesn't exist in the iOS app
    // sandbox — any `[GEOIP,…]` rule then fails to write the downloaded
    // MMDB with "open: no such file or directory".
    //
    // Also seeds compile-time bundled assets (geo dbs, external UI)
    // into the working directory so the host app's Settings and any
    // host-side validate() calls see the same files mihomo would.
    private static func bootstrapMihomoPaths() {
        LibmihomoBridge.setHomeDir(FilePath.workingDirectory.path)
        BundledAssets.installIfNeeded()
    }

    public func bootstrap() async {
        do {
            try await profile.load()
        } catch {
            // Profile load failure is non-fatal; the user can retry from UI.
        }
        observeProfileStatus()
        // Make sure the current state is honored even before the
        // observer's first event fires (e.g. app cold-launches with VPN
        // already connected from a previous session).
        applyStatus(profile.status)
    }

    private func observeProfileStatus() {
        guard statusObservation == nil else { return }
        statusObservation = profile.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.applyStatus(status)
            }
    }

    private func applyStatus(_ status: NEVPNStatus) {
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
