import Combine
import Foundation
import NetworkExtension

/// Single object injected as @EnvironmentObject so views can reach the VPN
/// profile and the streaming command client without prop-drilling.
///
/// Acts as a thin orchestrator over four coordinators (see
/// `ExtensionCoordinators.swift`): VPN lifecycle, settings reloads,
/// auto connect, traffic accounting. Each coordinator owns its own
/// observations; this type only wires their error callbacks back into
/// `@Published` UI surfaces and exposes the underlying profile +
/// command client for views.
@MainActor
public final class ExtensionEnvironment: ObservableObject {
    public let profile: ExtensionProfile
    public let commandClient: CommandClient

    /// Persisted across log view appearances so the user's search term
    /// survives navigation. Mirrors sing-box-for-apple's logSearchText.
    @Published public var logSearchText: String = ""

    /// Surfaces the most recent reload error to the UI so taps on a
    /// profile while the tunnel is up don't fail silently.
    @Published public var reloadError: String?
    /// Surfaces the most recent on-demand-rule save failure so the
    /// Auto Connect sub view can show an alert.
    @Published public var autoConnectError: String?

    private let lifecycle: VPNLifecycleCoordinator
    private let settings: SettingsChangeCoordinator
    private let autoConnect: AutoConnectCoordinator
    private let traffic: TrafficCoordinator

    private var memoryObserverToken: UUID?

    public convenience init() {
        self.init(
            profile: ExtensionProfile(),
            commandClient: CommandClient()
        )
    }

    public init(profile: ExtensionProfile, commandClient: CommandClient) {
        Self.bootstrapMihomoPaths()
        self.profile = profile
        self.commandClient = commandClient
        self.lifecycle = VPNLifecycleCoordinator(profile: profile, commandClient: commandClient)
        self.settings = SettingsChangeCoordinator(profile: profile)
        self.autoConnect = AutoConnectCoordinator(profile: profile, store: HostSettingsStore.shared)
        self.traffic = TrafficCoordinator(commandClient: commandClient, usageStore: DailyUsageStore.shared)
    }

    deinit {
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
}
