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
