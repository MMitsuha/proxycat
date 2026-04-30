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

    private var bag = Set<AnyCancellable>()

    private init() {
        let stored = JSONFileStore.load(
            HostSettings.self,
            at: FilePath.hostSettingsFilePath,
            default: .defaults
        )
        self.autoConnect = stored.autoConnect

        // dropFirst skips the publisher's "current value" replay so we
        // don't immediately re-write what we just loaded; subsequent
        // changes from a SwiftUI binding flow through persistAndBroadcast.
        //
        // Persist from the value the publisher emits, not from
        // self.autoConnect: @Published emits in willSet, so reading
        // self.* here returns the *previous* value.
        $autoConnect
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] config in
                self?.persistAndBroadcast(snapshot: HostSettings(autoConnect: config))
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
