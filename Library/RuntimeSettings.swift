import Foundation
import Observation

/// Single source of truth for runtime preferences shared between the
/// host app and the Network Extension. Persists to `settings.json` in
/// the App Group container; the Go core reads the same file directly
/// on every Start / Reload, so toggling a value here propagates without
/// any option-dictionary plumbing.
///
/// Mutating any property:
///   * Always persists the full snapshot.
///   * Log-level change → posts `runtimeLogLevelDidChange`, routed to
///     a lightweight IPC that calls `log.SetLevel` directly in the
///     extension's mihomo (no `hub.ApplyConfig`).
///   * `disableExternalController` change → posts
///     `runtimeSettingsDidChange`, routed to the heavyweight reload
///     path that re-reads settings.json and rebuilds the config.
@MainActor @Observable
public final class RuntimeSettings {
    public static let shared = RuntimeSettings()

    public var disableExternalController: Bool {
        didSet {
            guard loaded, disableExternalController != oldValue else { return }
            persist()
            NotificationCenter.default.post(
                name: AppConfiguration.runtimeSettingsDidChange,
                object: nil
            )
        }
    }

    public var logLevel: Int {
        didSet {
            guard loaded, logLevel != oldValue else { return }
            persist()
            LibmihomoBridge.setLogLevel(logLevel)
            NotificationCenter.default.post(
                name: AppConfiguration.runtimeLogLevelDidChange,
                object: nil,
                userInfo: ["level": logLevel]
            )
        }
    }

    @ObservationIgnored private var loaded = false

    private init() {
        let stored = JSONFileStore.load(
            Snapshot.self,
            at: FilePath.settingsFilePath,
            default: .defaults
        )
        self.disableExternalController = stored.disableExternalController
        self.logLevel = stored.logLevel
        self.loaded = true
    }

    private func persist() {
        let snapshot = Snapshot(
            disableExternalController: disableExternalController,
            logLevel: logLevel
        )
        JSONFileStore.saveOrLog(
            snapshot,
            to: FilePath.settingsFilePath,
            category: "RuntimeSettings"
        )
    }

    public struct Snapshot: Codable, Equatable, Sendable {
        public var disableExternalController: Bool
        public var logLevel: Int

        public static let defaults = Snapshot(disableExternalController: false, logLevel: 2)
    }
}
