import Combine
import Foundation
import NetworkExtension

/// Coordinators that ExtensionEnvironment composes. Each one owns a
/// single cross-cutting concern (VPN lifecycle, settings reloads, auto
/// connect rules, traffic accounting) and exposes a tiny `start` API
/// plus an optional error callback. Splitting them out shrank the
/// previous 277-line ExtensionEnvironment to a thin wirer that holds
/// the four concerns and forwards their errors to the UI.
///
/// Each coordinator manages its own ObservationBag so cleanup is
/// automatic on dealloc — there are no manually-tracked observer
/// tokens to forget.

// MARK: - VPN lifecycle

/// Mirrors NEVPNStatus to the gRPC `CommandClient`'s connect/disconnect.
/// The command client must come up while the VPN is `.connecting` so log
/// + traffic streams are available the moment the tunnel finishes
/// negotiating, and tear down cleanly when the user disconnects.
@MainActor
public final class VPNLifecycleCoordinator {
    private let profile: ExtensionProfile
    private let commandClient: CommandClient
    private let bag = ObservationBag()

    public init(profile: ExtensionProfile, commandClient: CommandClient) {
        self.profile = profile
        self.commandClient = commandClient
    }

    public func start() {
        let cancellable = profile.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.apply(status)
            }
        bag.store(cancellable)
        // Honor the current state immediately for cold launches that
        // resume an already-connected VPN session.
        apply(profile.status)
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

// MARK: - Settings change

/// Observes the three notifications that should trigger a tunnel reload
/// (or, in the log-level case, the cheaper fast-path message): active
/// profile content changed, runtime settings changed, log level
/// changed. Errors from the reload bubble up via `onError`.
@MainActor
public final class SettingsChangeCoordinator {
    public var onError: ((String) -> Void)?

    private let profile: ExtensionProfile
    private let bag = ObservationBag()

    public init(profile: ExtensionProfile) {
        self.profile = profile
    }

    public func start() {
        let center = NotificationCenter.default

        bag.add(center.addObserver(
            forName: ProfileStore.activeContentDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.reloadIfConnected() }
        })

        bag.add(center.addObserver(
            forName: AppConfiguration.runtimeSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.reloadIfConnected() }
        })

        // Fast path: a log-level change skips hub.ApplyConfig entirely
        // and lands at log.SetLevel inside the extension. Falls back
        // silently when disconnected — the next start() reads the new
        // level from settings.json.
        bag.add(center.addObserver(
            forName: AppConfiguration.runtimeLogLevelDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let level = note.userInfo?["level"] as? Int else { return }
            Task { @MainActor in await self?.applyLogLevelIfConnected(level) }
        })
    }

    private func reloadIfConnected() async {
        guard profile.isConnected else { return }
        do {
            try await profile.reload()
        } catch {
            onError?(error.localizedDescription)
        }
    }

    private func applyLogLevelIfConnected(_ level: Int) async {
        guard profile.isConnected else { return }
        do {
            try await profile.setLogLevel(level)
        } catch {
            onError?(error.localizedDescription)
        }
    }
}

// MARK: - Auto Connect

/// Pushes the host-side `AutoConnectConfig` onto the
/// NETunnelProviderManager whenever it changes (so the on-demand rules
/// the user just edited take effect without a manual disconnect /
/// reconnect). Also re-syncs once on bootstrap to cover edits made
/// while the host app was killed.
@MainActor
public final class AutoConnectCoordinator {
    public var onError: ((String) -> Void)?

    private let profile: ExtensionProfile
    private let store: HostSettingsStore
    private let bag = ObservationBag()

    public init(profile: ExtensionProfile, store: HostSettingsStore) {
        self.profile = profile
        self.store = store
    }

    public func start() {
        bag.add(NotificationCenter.default.addObserver(
            forName: AppConfiguration.hostSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.applyFromStore() }
        })
    }

    public func applyFromStore() async {
        let config = store.autoConnect
        do {
            try await profile.applyAutoConnect(config)
        } catch {
            onError?(error.localizedDescription)
        }
    }
}

// MARK: - Traffic

/// Forwards every Status frame the command client publishes into the
/// daily-usage aggregator. Drops the initial replayed `.zero` (which
/// would otherwise look like an extension counter reset) and dedupes
/// identical idle ticks.
@MainActor
public final class TrafficCoordinator {
    private let commandClient: CommandClient
    private let usageStore: DailyUsageStore
    private let bag = ObservationBag()

    public init(commandClient: CommandClient, usageStore: DailyUsageStore) {
        self.commandClient = commandClient
        self.usageStore = usageStore
    }

    public func start() {
        let cancellable = commandClient.$traffic
            .dropFirst()
            .removeDuplicates()
            .sink { [usageStore] snapshot in
                Task { @MainActor in usageStore.record(snapshot: snapshot) }
            }
        bag.store(cancellable)
    }
}
