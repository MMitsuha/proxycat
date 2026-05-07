import Combine
import Foundation

/// Single source of truth for host-only preferences (currently the
/// Auto Connect feature; future iOS-side features land here too).
/// Persists to `host_settings.json` in the App Group container.
///
/// Mirrors `RuntimeSettings`: load on init, dropFirst() guards against
/// re-writing what we just loaded, atomic file writes, and a single
/// notification (`hostSettingsDidChange`) posted on every persisted
/// change. Subscribers — currently `ExtensionEnvironment` — react by
/// re-applying the relevant configuration to NETunnelProviderManager.
@MainActor
public final class HostSettingsStore: ObservableObject {
    public static let shared = HostSettingsStore()

    @Published public var autoConnect: AutoConnectConfig
    @Published public var logRetention: LogRetention

    private var bag = Set<AnyCancellable>()

    private init() {
        let stored = JSONFileStore.load(
            HostSettings.self,
            at: FilePath.hostSettingsFilePath,
            default: .defaults
        )
        self.autoConnect = stored.autoConnect
        self.logRetention = stored.logRetention

        // Persist whenever any field changes. Build the snapshot from
        // the publishers' emitted values rather than `self.*` — @Published
        // emits in willSet, so reading `self.<other>` here would capture
        // the previous value if both fields were set in the same tick.
        // dropFirst skips the replay of values we just loaded.
        Publishers.CombineLatest($autoConnect, $logRetention)
            .dropFirst()
            .removeDuplicates(by: ==)
            .sink { [weak self] config, policy in
                self?.persistAndBroadcast(snapshot: HostSettings(
                    autoConnect: config,
                    logRetention: policy
                ))
            }
            .store(in: &bag)

        // Apply retention immediately so the user sees old files
        // disappear without waiting for the next view reload.
        $logRetention
            .dropFirst()
            .removeDuplicates()
            .sink { policy in
                FilePath.pruneSavedLogs(
                    policy: policy,
                    activePath: LibmihomoBridge.currentLogFilePath()
                )
            }
            .store(in: &bag)
    }

    private func persistAndBroadcast(snapshot: HostSettings) {
        // Don't broadcast on failure: subscribers would re-apply from
        // in-memory state while the persisted file still holds the old
        // value, silently reverting on the next cold launch.
        guard JSONFileStore.saveOrLog(
            snapshot,
            to: FilePath.hostSettingsFilePath,
            category: "HostSettingsStore"
        ) else { return }
        NotificationCenter.default.post(name: AppConfiguration.hostSettingsDidChange, object: self)
    }
}
