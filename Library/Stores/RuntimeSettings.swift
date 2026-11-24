import Foundation
import Observation

/// Single source of truth for runtime preferences shared between the
/// host app and the Network Extension. Persists to
/// `runtime_settings.json` in the App Group container; the Go core
/// reads the same file directly on every Start / Reload, so toggling a
/// value here propagates without any option-dictionary plumbing.
///
/// Holds three fields:
///   * `activeProfileID` — UUID of the currently selected profile.
///     Mutated through `ProfileStore.setActive`, which also posts
///     `activeContentDidChange` so the host UI can react. Setting the
///     property here only persists; ProfileStore owns the user-facing
///     "switched profile" notification.
///   * `disableExternalController` — toggling posts
///     `runtimeSettingsDidChange`, routed to the heavyweight reload
///     path (gRPC Reload RPC) that re-reads runtime_settings.json and
///     rebuilds the config.
///   * `logLevel` — host-side UI display filter for the Logs tab.
///     Persisted so it survives launches and so iCloud sync can carry
///     the user's choice between devices. mihomo's observable emits
///     every event regardless, and the host filters locally; the Go
///     core ignores this field on parse. Toggling posts
///     `runtimeLogLevelDidChange` so iCloud sync can debounce-upload
///     without falsely triggering a tunnel Reload.
@MainActor @Observable
public final class RuntimeSettings {
    public static let shared = RuntimeSettings()

    public var activeProfileID: UUID? {
        didSet {
            guard loaded, !isReplacing, activeProfileID != oldValue else { return }
            _ = persist()
            // Asymmetric vs the other properties: ProfileStore.setActive
            // is the user-facing entry point and posts
            // activeContentDidChange itself, so we don't double-notify
            // here. Direct writes (e.g. ProfileStore.delete clearing the
            // selection) post the notification at the call site too.
        }
    }

    public var disableExternalController: Bool {
        didSet {
            guard loaded, !isReplacing, disableExternalController != oldValue else { return }
            // Don't broadcast on persist failure: subscribers (the
            // settings reload coordinator) would call `Reload`, the Go
            // core would re-read the on-disk file with the OLD value,
            // and the toggle would silently revert.
            guard persist() else { return }
            NotificationCenter.default.post(
                name: AppConfiguration.runtimeSettingsDidChange,
                object: nil
            )
        }
    }

    public var logLevel: Int {
        didSet {
            guard loaded, !isReplacing, logLevel != oldValue else { return }
            // logLevel is a host-side display filter; the extension's
            // mihomo always emits every event over the gRPC log stream
            // and the Logs tab filters locally. There is no IPC nudge
            // — the notification only feeds iCloud sync so the choice
            // round-trips to other devices.
            _ = persist()
            NotificationCenter.default.post(
                name: AppConfiguration.runtimeLogLevelDidChange,
                object: nil,
                userInfo: ["level": logLevel]
            )
        }
    }

    public var snapshot: Snapshot {
        Snapshot(
            activeProfileID: activeProfileID,
            disableExternalController: disableExternalController,
            logLevel: logLevel
        )
    }

    @ObservationIgnored private var loaded = false
    /// Set while `replace(with:)` assigns every field. Suppresses the
    /// per-property didSet work so an iCloud restore writes the file once
    /// and posts one notification per affected category instead of one
    /// per field.
    @ObservationIgnored private var isReplacing = false

    private init() {
        let stored = JSONFileStore.load(
            Snapshot.self,
            at: FilePath.runtimeSettingsFilePath,
            default: .defaults
        )
        self.activeProfileID = stored.activeProfileID
        self.disableExternalController = stored.disableExternalController
        self.logLevel = stored.logLevel
        self.loaded = true
    }

    @discardableResult
    private func persist() -> Bool {
        let snapshot = Snapshot(
            activeProfileID: activeProfileID,
            disableExternalController: disableExternalController,
            logLevel: logLevel
        )
        return JSONFileStore.saveOrLog(
            snapshot,
            to: FilePath.runtimeSettingsFilePath,
            category: "RuntimeSettings"
        )
    }

    /// Applies a whole snapshot as one transaction. The caller
    /// (`ICloudBackupStore.apply`) has already replaced the profile
    /// catalog and posted `activeContentDidChange`, so this only owns the
    /// runtime preference fields: persist once, then notify the
    /// consumers that actually care.
    public func replace(with snapshot: Snapshot) {
        let activeChanged = activeProfileID != snapshot.activeProfileID
        let controllerChanged = disableExternalController != snapshot.disableExternalController
        let logLevelChanged = logLevel != snapshot.logLevel
        guard activeChanged || controllerChanged || logLevelChanged else { return }

        isReplacing = true
        activeProfileID = snapshot.activeProfileID
        disableExternalController = snapshot.disableExternalController
        logLevel = snapshot.logLevel
        isReplacing = false

        guard persist() else { return }
        if controllerChanged {
            NotificationCenter.default.post(
                name: AppConfiguration.runtimeSettingsDidChange,
                object: nil
            )
        }
        if logLevelChanged {
            NotificationCenter.default.post(
                name: AppConfiguration.runtimeLogLevelDidChange,
                object: nil,
                userInfo: ["level": logLevel]
            )
        }
    }

    public struct Snapshot: Codable, Equatable, Sendable {
        public var activeProfileID: UUID?
        public var disableExternalController: Bool
        public var logLevel: Int

        public static let defaults = Snapshot(
            activeProfileID: nil,
            disableExternalController: false,
            logLevel: 2
        )
    }
}
