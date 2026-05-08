import Foundation
import NetworkExtension

/// Coordinators that ExtensionEnvironment composes. Each one owns a
/// single cross-cutting concern (VPN lifecycle, settings reloads, auto
/// connect rules, traffic accounting) and exposes a tiny `start` API
/// plus an optional error callback. Splitting them out shrank the
/// previous 277-line ExtensionEnvironment to a thin wirer that holds
/// the four concerns and forwards their errors to the UI.
///
/// Each coordinator owns its own observation Task(s); deinit
/// cancels them so cleanup is automatic on dealloc — no manually
/// tracked observer tokens to forget.

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

// MARK: - Settings change

/// Observes the three notifications that should trigger a tunnel reload
/// (or, in the log-level case, the cheaper fast-path RPC): active
/// profile content changed, runtime settings changed, log level
/// changed. Errors from the reload bubble up via `onError`.
///
/// Dispatches to the extension's mihomo via the gRPC `CommandClient`
/// rather than `NETunnelProviderSession.sendProviderMessage` — one
/// channel for both streaming events and unary commands. The extension
/// has no opinion of its own; runtime_settings.json is the source of
/// truth, and the gRPC RPC is just a nudge to re-read it.
@MainActor
public final class SettingsChangeCoordinator {
    public var onError: ((String) -> Void)?

    private let commandClient: CommandClient
    private var tasks: [Task<Void, Never>] = []

    public init(commandClient: CommandClient) {
        self.commandClient = commandClient
    }

    public func start() {
        for task in tasks { task.cancel() }
        tasks.removeAll()

        let center = NotificationCenter.default

        tasks.append(Task { @MainActor [weak self] in
            for await _ in center.notifications(named: ProfileStore.activeContentDidChange) {
                await self?.reloadIfConnected()
            }
        })

        tasks.append(Task { @MainActor [weak self] in
            for await _ in center.notifications(named: AppConfiguration.runtimeSettingsDidChange) {
                await self?.reloadIfConnected()
            }
        })

        // Fast path: a log-level change skips hub.ApplyConfig entirely
        // and lands at log.SetLevel inside the extension. Falls back
        // silently when disconnected — the next start() reads the new
        // level from runtime_settings.json.
        tasks.append(Task { @MainActor [weak self] in
            for await note in center.notifications(named: AppConfiguration.runtimeLogLevelDidChange) {
                guard let level = note.userInfo?["level"] as? Int else { continue }
                await self?.applyLogLevelIfConnected(level)
            }
        })
    }

    deinit {
        for task in tasks { task.cancel() }
    }

    private func reloadIfConnected() async {
        guard commandClient.isConnected else { return }
        do {
            try await commandClient.reload()
        } catch {
            onError?(error.localizedDescription)
        }
    }

    private func applyLogLevelIfConnected(_ level: Int) async {
        guard commandClient.isConnected else { return }
        do {
            try await commandClient.setLogLevel(level)
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
    private var observationTask: Task<Void, Never>?

    public init(profile: ExtensionProfile, store: HostSettingsStore) {
        self.profile = profile
        self.store = store
    }

    public func start() {
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AppConfiguration.hostSettingsDidChange) {
                await self?.applyFromStore()
            }
        }
    }

    public func applyFromStore() async {
        let config = store.autoConnect
        do {
            try await profile.applyAutoConnect(config)
        } catch {
            onError?(error.localizedDescription)
        }
    }

    deinit {
        observationTask?.cancel()
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
    private var observationTask: Task<Void, Never>?

    public init(commandClient: CommandClient, usageStore: DailyUsageStore) {
        self.commandClient = commandClient
        self.usageStore = usageStore
    }

    public func start() {
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var last: TrafficSnapshot?
            // dropFirst skips the initial .zero replay (otherwise the
            // very first frame would look like a counter reset). Manual
            // dedupe replicates the previous removeDuplicates() arm.
            for await snapshot in Observed.values({ self.commandClient.traffic }).dropFirst() {
                if snapshot == last { continue }
                last = snapshot
                self.usageStore.record(snapshot: snapshot)
            }
        }
    }

    deinit {
        observationTask?.cancel()
    }
}
