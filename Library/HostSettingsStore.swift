import Combine
import Foundation
import os

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

    private static let logger = Logger(subsystem: "io.proxycat.Library", category: "HostSettingsStore")
    private var bag = Set<AnyCancellable>()

    private init() {
        let stored = Self.loadFromDisk()
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

    private static func loadFromDisk() -> HostSettings {
        let path = FilePath.hostSettingsFilePath
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return .defaults
        }
        return (try? JSONDecoder().decode(HostSettings.self, from: data)) ?? .defaults
    }

    private func persistAndBroadcast(snapshot: HostSettings) {
        do {
            let data = try JSONEncoder().encode(snapshot)
            // Atomic write: a partial file would make us fall back to
            // defaults on the next launch, which is worse than a stale
            // file.
            try data.write(to: URL(fileURLWithPath: FilePath.hostSettingsFilePath), options: .atomic)
        } catch {
            Self.logger.error("could not persist host settings: \(error.localizedDescription, privacy: .public)")
        }
        NotificationCenter.default.post(name: AppConfiguration.hostSettingsDidChange, object: self)
    }
}
