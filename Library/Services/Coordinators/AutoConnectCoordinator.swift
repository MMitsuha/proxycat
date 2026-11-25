import Foundation

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
    /// Last configuration successfully pushed to the manager. Host
    /// settings also change for unrelated fields (log retention, web
    /// editor), and those must not rewrite NEVPN preferences.
    private var lastAppliedConfig: AutoConnectConfig?

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
        guard config != lastAppliedConfig else { return }
        // Nothing to push until the manager loaded; leaving the cache
        // unset makes the next settings change retry.
        guard profile.manager != nil else { return }
        do {
            try await profile.applyAutoConnect(config)
            lastAppliedConfig = config
        } catch {
            onError?(error.localizedDescription)
        }
    }

    deinit {
        observationTask?.cancel()
    }
}
