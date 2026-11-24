import Foundation

public enum AppConfiguration {
    public static let appGroupID = "group.io.proxycat"
    public static let appBundleID = "io.proxycat.Pcat"
    public static let extensionBundleID = "io.proxycat.Pcat.PcatExtension"
    public static let iCloudContainerID = "iCloud.io.proxycat.Pcat"

    /// Filename of the Unix-domain command socket placed in the App
    /// Group container. The Network Extension's gRPC command server
    /// listens here; the host app's CommandClient dials it.
    public static let commandSocketName = "command.sock"

    /// Filename of the Unix-domain socket where mihomo's REST controller
    /// listens (in addition to its HTTP loopback for the in-app web UI).
    /// The extension-side `ControllerRequest` RPC uses this private
    /// socket to talk to /proxies, /connections, /group/.../delay etc. —
    /// keeping the host's native UI off the loopback listener the user
    /// can toggle off.
    public static let controllerSocketName = "controller.sock"

    /// Filename of the shared runtime-settings JSON. Written by the host
    /// app whenever the user toggles a preference or switches the active
    /// profile; read directly by the Go core on every Start / Reload so
    /// the host and extension stay in lock-step. Holds the active
    /// profile UUID alongside the runtime preference fields — one file
    /// is the cross-process source of truth for everything the Go core
    /// needs at lifecycle events.
    public static let runtimeSettingsFileName = "runtime_settings.json"

    /// Filename of the host-only settings JSON. Written by the host app
    /// for features the iOS side owns alone (e.g. on-demand rules
    /// configured on `NETunnelProviderManager`). The Go core never
    /// reads this file.
    public static let hostSettingsFileName = "host_settings.json"

    /// Filename of the local iCloud-sync metadata file. This is not
    /// backed up to iCloud; it records whether sync is enabled on this
    /// device and the checksum last reconciled with iCloud.
    public static let iCloudSyncStateFileName = "icloud_sync_state.json"

    /// Filename of the versioned iCloud snapshot. Stored under the app's
    /// iCloud Documents container and contains only user-authored
    /// profiles plus host/runtime settings. Logs, caches, usage history,
    /// MITM keys, and downloaded assets are intentionally excluded.
    public static let iCloudBackupFileName = "profile-settings-backup.json"

    /// Filename of the rolling daily-traffic log written by
    /// `DailyUsageStore`. Sits in the App Group root next to the other
    /// host-side JSONs; the Go core never touches it.
    public static let dailyUsageFileName = "daily_usage.json"

    /// Hidden marker inside `Logs/` containing the absolute path of the
    /// session log currently being written by the Network Extension.
    /// The host app reads this file when pruning or deleting saved logs;
    /// it cannot use `LibmihomoBridge.currentLogFilePath()` because that
    /// would query the host process' separate Go runtime.
    public static let activeLogMarkerFileName = ".active-log-path"

    /// Prefix for Swift-side per-session logs written by the Network
    /// Extension. Mihomo's Go-side log files keep using `mihomo-`.
    public static let proxyCatLogFilePrefix = "proxycat-"

    /// Hidden marker containing the active Swift-side session log path.
    /// Kept separate from `.active-log-path` so the Go persistence layer
    /// can keep its existing one-path marker format.
    public static let activeProxyCatLogMarkerFileName = ".active-proxycat-log-path"

    /// Filename of the profile catalog index. Lives inside
    /// `Profiles/` alongside the per-profile YAMLs and maps each
    /// profile UUID to its display name and on-disk filename. Written
    /// by `ProfileStore`; read by the Go core (libmihomo/binding.go)
    /// to resolve the active profile UUID from `runtime_settings.json`
    /// to a YAML path.
    public static let profileIndexFileName = "index.json"

    /// Posted by RuntimeSettings when the user changes a runtime
    /// preference *other than* log level (or when log level changes
    /// alongside another field). Subscribers (ExtensionEnvironment)
    /// react by asking the running tunnel to re-read
    /// runtime_settings.json and hot-apply via the heavyweight reload
    /// path (gRPC Reload RPC).
    public static let runtimeSettingsDidChange = Notification.Name("io.proxycat.RuntimeSettings.didChange")

    /// Posted by RuntimeSettings when only the log level changed.
    /// Currently only feeds iCloud sync: log level is a host-side
    /// display filter, so there is no IPC consumer — the running
    /// extension never needs to be told. Kept distinct from
    /// `runtimeSettingsDidChange` so the change does not falsely
    /// trigger the heavyweight tunnel Reload path.
    public static let runtimeLogLevelDidChange = Notification.Name("io.proxycat.RuntimeSettings.logLevelDidChange")

    /// Posted by HostSettingsStore whenever the user changes a
    /// host-only preference. Subscribers (ExtensionEnvironment) react by
    /// re-applying the relevant configuration to the
    /// NETunnelProviderManager (e.g. on-demand rules).
    public static let hostSettingsDidChange = Notification.Name("io.proxycat.HostSettings.didChange")
}
