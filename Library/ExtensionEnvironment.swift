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
///
/// Also bridges the host app's runtime-settings store to the running
/// tunnel: any change to `RuntimeSettings.shared` posts
/// `runtimeSettingsDidChange`, which we react to by asking the extension
/// to reload (Go re-reads `settings.json` from disk and hot-applies).
@MainActor
public final class ExtensionEnvironment: ObservableObject {
    public let profile: ExtensionProfile
    public let commandClient: CommandClient

    /// Persisted across log view appearances so the user's search term
    /// survives navigation. Mirrors sing-box-for-apple's logSearchText.
    @Published public var logSearchText: String = ""

    private var statusObservation: AnyCancellable?
    private var activeContentObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var logLevelObserver: NSObjectProtocol?
    private var hostSettingsObserver: NSObjectProtocol?
    private var memoryObserverToken: UUID?
    /// Surfaces the most recent reload error to the UI so taps on a
    /// profile while the tunnel is up don't fail silently.
    @Published public var reloadError: String?
    /// Surfaces the most recent on-demand-rule save failure so the
    /// Auto Connect sub view can show an alert.
    @Published public var autoConnectError: String?

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

    deinit {
        if let token = activeContentObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = settingsObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = logLevelObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = hostSettingsObserver {
            NotificationCenter.default.removeObserver(token)
        }
        if let token = memoryObserverToken {
            MemoryMonitor.shared.remove(token)
        }
    }

    // The host app process has its own Go runtime, so the extension's
    // path setters don't propagate. We re-apply the same paths here so
    // host-side `validate()` finds the bundled GeoIP/GeoSite files in
    // the working directory, and so any future host-side calls into the
    // bridge see the same shared state the extension does.
    //
    // Also seeds compile-time bundled assets (geo dbs, external UI)
    // into the working directory so the host app's Settings and any
    // host-side validate() calls see the same files mihomo would.
    private static func bootstrapMihomoPaths() {
        LibmihomoBridge.setHomeDir(FilePath.workingDirectory.path)
        LibmihomoBridge.setSettingsPath(FilePath.settingsFilePath)
        LibmihomoBridge.setActiveProfilePointer(FilePath.activeProfilePointer.path)
        LibmihomoBridge.setProfilesDir(FilePath.profilesDirectory.path)
        BundledAssets.installIfNeeded()
    }

    public func bootstrap() async {
        do {
            try await profile.load()
        } catch {
            // Profile load failure is non-fatal; the user can retry from UI.
        }
        observeProfileStatus()
        observeActiveContent()
        observeRuntimeSettings()
        observeRuntimeLogLevel()
        observeHostSettings()
        startMemoryPressureWatch()
        // Make sure the current state is honored even before the
        // observer's first event fires (e.g. app cold-launches with VPN
        // already connected from a previous session).
        applyStatus(profile.status)
        // Sync the manager's on-demand state with whatever the user
        // last persisted. No-op when the manager already matches; cheap
        // even when not, and it covers the case where the user edits
        // settings while the app was killed.
        await applyAutoConnectFromStore()
    }

    // The host app process gets memory warnings from iOS too — not just
    // the NE — and used to ignore them entirely. Wire MemoryMonitor here
    // so we can drop the largest reclaimable host-side buffer (logs)
    // before jetsam fires. ConnectionsStore / ProxiesStore live as
    // @StateObject of their views and disappear when the user navigates
    // away, so they don't need a hook here.
    private func startMemoryPressureWatch() {
        guard memoryObserverToken == nil else { return }
        MemoryMonitor.shared.start()
        memoryObserverToken = MemoryMonitor.shared.observe { [weak self] pressure in
            Task { @MainActor [weak self] in
                self?.handleMemoryPressure(pressure)
            }
        }
    }

    private func handleMemoryPressure(_ pressure: MemoryMonitor.Pressure) {
        switch pressure {
        case .normal:
            return
        case .warning, .critical:
            commandClient.clearLogs()
        }
    }

    private func observeActiveContent() {
        guard activeContentObserver == nil else { return }
        activeContentObserver = NotificationCenter.default.addObserver(
            forName: ProfileStore.activeContentDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.reloadIfConnected()
            }
        }
    }

    private func observeRuntimeSettings() {
        guard settingsObserver == nil else { return }
        settingsObserver = NotificationCenter.default.addObserver(
            forName: AppConfiguration.runtimeSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.reloadIfConnected()
            }
        }
    }

    /// Fast path for log-level toggles. Sends a "setLogLevel:N" provider
    /// message that lands at `log.SetLevel` in the extension's mihomo,
    /// skipping the heavyweight `hub.ApplyConfig` reload that the
    /// settings-changed observer above triggers. Falls back silently
    /// when disconnected — the next `start()` reads the new level from
    /// settings.json that RuntimeSettings just persisted.
    private func observeRuntimeLogLevel() {
        guard logLevelObserver == nil else { return }
        logLevelObserver = NotificationCenter.default.addObserver(
            forName: AppConfiguration.runtimeLogLevelDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let level = note.userInfo?["level"] as? Int else { return }
            Task { @MainActor in
                await self?.applyLogLevelIfConnected(level)
            }
        }
    }

    private func applyLogLevelIfConnected(_ level: Int) async {
        guard profile.isConnected else { return }
        do {
            try await profile.setLogLevel(level)
        } catch {
            reloadError = error.localizedDescription
        }
    }

    private func observeHostSettings() {
        guard hostSettingsObserver == nil else { return }
        hostSettingsObserver = NotificationCenter.default.addObserver(
            forName: AppConfiguration.hostSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.applyAutoConnectFromStore()
            }
        }
    }

    /// Reads the current `AutoConnectConfig` from the store and pushes
    /// it onto the NETunnelProviderManager via `ExtensionProfile`.
    /// Errors surface through `autoConnectError` so the UI can show an
    /// alert; we never throw out of an observer callback.
    private func applyAutoConnectFromStore() async {
        let config = HostSettingsStore.shared.autoConnect
        do {
            try await profile.applyAutoConnect(config)
        } catch {
            autoConnectError = error.localizedDescription
        }
    }

    /// Fires `ExtensionProfile.reload()` when the tunnel is up so that
    /// switching profiles, editing the active YAML, or toggling a
    /// runtime setting hot-applies without requiring the user to
    /// disconnect and reconnect by hand. No-ops while disconnected —
    /// the next `start()` already reads everything fresh from disk.
    private func reloadIfConnected() async {
        guard profile.isConnected else { return }
        do {
            try await profile.reload()
        } catch {
            reloadError = error.localizedDescription
        }
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
