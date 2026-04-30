import Foundation

public enum AppConfiguration {
    public static let appGroupID = "group.io.proxycat"
    public static let appBundleID = "io.proxycat.Pcat"
    public static let extensionBundleID = "io.proxycat.Pcat.PcatExtension"

    /// Filename of the Unix-domain command socket placed in the App
    /// Group container. The Network Extension's gRPC command server
    /// listens here; the host app's CommandClient dials it.
    public static let commandSocketName = "command.sock"

    /// Filename of the shared runtime-settings JSON. Written by the host
    /// app whenever the user toggles a preference; read directly by the
    /// Go core on every Start / Reload / settings-change so the host and
    /// extension stay in lock-step without shuttling values through IPC.
    public static let settingsFileName = "settings.json"

    /// Filename of the host-only settings JSON. Written by the host app
    /// for features the iOS side owns alone (e.g. on-demand rules
    /// configured on `NETunnelProviderManager`). The Go core never
    /// reads this file.
    public static let hostSettingsFileName = "host_settings.json"

    /// Posted by RuntimeSettings when the user changes a runtime
    /// preference *other than* log level (or when log level changes
    /// alongside another field). Subscribers (ExtensionEnvironment)
    /// react by asking the running tunnel to re-read settings.json
    /// and hot-apply via the heavyweight reload path.
    public static let runtimeSettingsDidChange = Notification.Name("io.proxycat.RuntimeSettings.didChange")

    /// Posted by RuntimeSettings when only the log level changed.
    /// Subscribers route this to a lightweight IPC that calls
    /// `log.SetLevel` directly in the extension, bypassing the full
    /// `hub.ApplyConfig` reload (which would re-read the YAML profile,
    /// rebuild proxies/listeners/rules/DNS, and briefly suspend
    /// traffic for a one-line filter change).
    public static let runtimeLogLevelDidChange = Notification.Name("io.proxycat.RuntimeSettings.logLevelDidChange")

    /// Posted by HostSettingsStore whenever the user changes a
    /// host-only preference. Subscribers (ExtensionEnvironment) react by
    /// re-applying the relevant configuration to the
    /// NETunnelProviderManager (e.g. on-demand rules).
    public static let hostSettingsDidChange = Notification.Name("io.proxycat.HostSettings.didChange")
}
