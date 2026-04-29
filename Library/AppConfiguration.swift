import Foundation

public enum AppConfiguration {
    public static let appGroupID = "group.io.proxycat"
    public static let appBundleID = "io.proxycat.Pcat"
    public static let extensionBundleID = "io.proxycat.Pcat.PcatExtension"

    /// Key used in NEPacketTunnelProvider's startTunnel options dictionary to
    /// pass the chosen profile YAML to the extension.
    public static let configContentKey = "configContent"

    /// Key used to ask the extension to override (for the current run only)
    /// the YAML's external-controller secret. Optional.
    public static let controllerSecretKey = "controllerSecret"

    /// Key used both in the startTunnel options dictionary and in
    /// UserDefaults to persist the user's "Disable Web Controller"
    /// preference. When true, the extension passes the toggle to
    /// `Libmihomo.Start` so mihomo's REST API and bundled UI never
    /// bind. Read with `@AppStorage`; the host writes the same value
    /// through to the extension at connect time.
    public static let disableExternalControllerKey = "disableExternalController"

    /// Filename of the Unix-domain command socket placed in the App
    /// Group container. The Network Extension's gRPC command server
    /// listens here; the host app's CommandClient dials it.
    public static let commandSocketName = "command.sock"
}
