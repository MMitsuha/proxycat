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

    /// Posted by RuntimeSettings whenever the user changes a runtime
    /// preference. Subscribers (ExtensionEnvironment) react by asking
    /// the running tunnel to re-read settings.json and hot-apply.
    public static let runtimeSettingsDidChange = Notification.Name("io.proxycat.RuntimeSettings.didChange")
}
