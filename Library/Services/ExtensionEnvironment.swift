import Foundation
import NetworkExtension
import Observation

/// Single @Observable object injected via `.environment(_:)` so views
/// can reach the VPN profile and the streaming command client without
/// prop-drilling.
///
/// Acts as a thin orchestrator over four coordinators (see
/// `Coordinators/`): VPN lifecycle, settings reloads,
/// auto connect, traffic accounting. Each coordinator owns its own
/// observations; this type only wires their error callbacks back into
/// observed UI surfaces and exposes the underlying profile + command
/// client for views.
@MainActor @Observable
public final class ExtensionEnvironment {
    public let profile: ExtensionProfile
    public let commandClient: CommandClient
    public let webConfig = WebConfigServer()

    /// Persisted across log view appearances so the user's search term
    /// survives navigation. Mirrors sing-box-for-apple's logSearchText.
    public var logSearchText: String = ""

    /// Surfaces the most recent reload error to the UI so taps on a
    /// profile while the tunnel is up don't fail silently.
    public var reloadError: String?
    /// Surfaces the most recent on-demand-rule save failure so the
    /// Auto Connect sub view can show an alert.
    public var autoConnectError: String?

    @ObservationIgnored private let lifecycle: VPNLifecycleCoordinator
    @ObservationIgnored private let settings: SettingsChangeCoordinator
    @ObservationIgnored private let autoConnect: AutoConnectCoordinator
    @ObservationIgnored private let traffic: TrafficCoordinator

    @ObservationIgnored private var memoryObserverToken: UUID?
    @ObservationIgnored private var webConfigTask: Task<Void, Never>?

    public convenience init() {
        self.init(
            profile: ExtensionProfile(),
            commandClient: CommandClient()
        )
    }

    public init(profile: ExtensionProfile, commandClient: CommandClient) {
        Self.configureMihomoPaths()
        self.profile = profile
        self.commandClient = commandClient
        self.lifecycle = VPNLifecycleCoordinator(profile: profile, commandClient: commandClient)
        self.settings = SettingsChangeCoordinator(commandClient: commandClient)
        self.autoConnect = AutoConnectCoordinator(profile: profile, store: HostSettingsStore.shared)
        self.traffic = TrafficCoordinator(commandClient: commandClient, usageStore: DailyUsageStore.shared)
    }

    deinit {
        webConfigTask?.cancel()
        if let token = memoryObserverToken {
            MemoryMonitor.shared.remove(token)
        }
    }

    // The host app process has its own Go runtime, so the extension's
    // path setters don't propagate. We re-apply the same paths here so
    // host-side `validate()` finds the bundled GeoIP/GeoSite files in
    // the working directory, and so any future host-side calls into the
    // bridge see the same shared state the extension does.
    private static func configureMihomoPaths() {
        LibmihomoBridge.setHomeDir(FilePath.workingDirectory.path)
        LibmihomoBridge.setRuntimeSettingsPath(FilePath.runtimeSettingsFilePath)
        LibmihomoBridge.setProfilesDir(FilePath.profilesDirectory.path)
        LibmihomoBridge.setProfileIndexPath(FilePath.profileIndexFilePath)
    }

    public func bootstrap() async {
        // Seed compile-time bundled geo databases and the external UI on
        // a background task. The first launch after an update can copy
        // tens of megabytes, so it must not delay profile loading or the
        // first frame. Await it at the end to keep host-side validate()
        // consistent with what the extension will see.
        let assetInstall = Task.detached(priority: .utility) {
            BundledAssets.installIfNeeded()
        }

        do {
            try await profile.load()
        } catch {
            // Profile load failure is non-fatal; the user can retry from UI.
        }

        settings.onError = { [weak self] message in
            self?.reloadError = message
        }
        autoConnect.onError = { [weak self] message in
            self?.autoConnectError = message
        }

        lifecycle.start()
        settings.start()
        autoConnect.start()
        traffic.start()
        startMemoryPressureWatch()

        // Sync the manager's on-demand state with whatever the user
        // last persisted. Covers the case where the user edits settings
        // while the app was killed.
        await autoConnect.applyFromStore()
        _ = await assetInstall.value

        // Wait for the geo databases above so the bundled default YAML
        // (which contains GEOIP rules) validates successfully.
        await ProfileStore.shared.seedDefaultProfileIfNeeded()

        // Keep the LAN web editor in sync with the host-only preference.
        webConfigTask?.cancel()
        webConfigTask = Task { @MainActor [weak self] in
            for await settings in Observed.values({ HostSettingsStore.shared.webEditor }) {
                self?.webConfig.apply(settings)
            }
        }
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
        memoryObserverToken = MemoryMonitor.shared.observe { [weak self] snapshot in
            Task { @MainActor [weak self] in
                self?.handleMemoryPressure(snapshot.pressure)
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
}
