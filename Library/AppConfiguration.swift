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
}
