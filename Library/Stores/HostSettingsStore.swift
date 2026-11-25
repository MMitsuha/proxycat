import Foundation
import Observation

/// Single source of truth for host-only preferences (currently the
/// Auto Connect feature and log retention). Persists to
/// `host_settings.json` in the App Group container.
///
/// Mirrors `RuntimeSettings`: load on init, `loaded` flag guards
/// against re-writing what we just loaded, atomic file writes, and a
/// single notification (`hostSettingsDidChange`) posted on every
/// persisted change. Subscribers — currently `ExtensionEnvironment` —
/// react by re-applying the relevant configuration to
/// NETunnelProviderManager.
@MainActor @Observable
public final class HostSettingsStore {
    public static let shared = HostSettingsStore()

    public var autoConnect: AutoConnectConfig {
        didSet {
            guard !isReplacing else { return }
            persistAndBroadcast()
        }
    }
    public var logRetention: LogRetention {
        didSet {
            guard !isReplacing else { return }
            persistAndBroadcast()
            StorageMaintenance.pruneSavedLogs(policy: logRetention)
        }
    }
    public var webEditor: WebEditorSettings {
        didSet {
            guard !isReplacing else { return }
            persistAndBroadcast()
        }
    }

    public var snapshot: HostSettings {
        HostSettings(
            autoConnect: autoConnect,
            logRetention: logRetention,
            webEditor: webEditor
        )
    }

    /// `didSet` doesn't fire during the constructor's stored-property
    /// init, so this gate is technically redundant for `init`; it's
    /// here as a defense-in-depth guard for any future code path that
    /// might mutate these properties before load is complete.
    @ObservationIgnored private var loaded = false
    /// Suppresses per-property persistence/notifications while
    /// `replace(with:)` applies an iCloud snapshot as one transaction.
    @ObservationIgnored private var isReplacing = false

    private init() {
        let stored = JSONFileStore.load(
            HostSettings.self,
            at: FilePath.hostSettingsFilePath,
            default: .defaults
        )
        self.autoConnect = stored.autoConnect
        self.logRetention = stored.logRetention
        self.webEditor = stored.webEditor
        self.loaded = true
    }

    private func persistAndBroadcast() {
        guard loaded else { return }
        let settings = snapshot
        // Don't broadcast on failure: subscribers would re-apply from
        // in-memory state while the persisted file still holds the old
        // value, silently reverting on the next cold launch.
        guard JSONFileStore.saveOrLog(
            settings,
            to: FilePath.hostSettingsFilePath,
            category: "HostSettingsStore"
        ) else { return }
        NotificationCenter.default.post(name: AppConfiguration.hostSettingsDidChange, object: self)
    }

    public func replace(with snapshot: HostSettings) {
        let autoConnectChanged = autoConnect != snapshot.autoConnect
        let retentionChanged = logRetention != snapshot.logRetention
        let webEditorChanged = webEditor != snapshot.webEditor
        guard autoConnectChanged || retentionChanged || webEditorChanged else { return }

        isReplacing = true
        autoConnect = snapshot.autoConnect
        logRetention = snapshot.logRetention
        webEditor = snapshot.webEditor
        isReplacing = false

        persistAndBroadcast()
        if retentionChanged {
            StorageMaintenance.pruneSavedLogs(policy: logRetention)
        }
    }
}
