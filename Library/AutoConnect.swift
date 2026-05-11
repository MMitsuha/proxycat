import Foundation

/// What to do when an on-demand rule matches.
public enum AutoConnectAction: Int, Codable, CaseIterable, Sendable {
    case ignore = 0
    case connect = 1
    case disconnect = 2
}

/// A single Wi-Fi SSID rule. The action applies when the device joins
/// the named SSID; matching is case-sensitive (iOS does not normalize).
public struct SSIDRule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var ssid: String
    public var action: AutoConnectAction

    public init(id: UUID = UUID(), ssid: String, action: AutoConnectAction) {
        self.id = id
        self.ssid = ssid
        self.action = action
    }
}

/// User-facing configuration for the Auto Connect feature.
///
/// Translates to a flat `NEOnDemandRule[]` evaluated top-to-bottom by
/// iOS. Order: each SSID rule (Wi-Fi only), then a cellular rule, then
/// a final fallback rule with `interfaceTypeMatch = .any`. First match
/// wins, so SSID rules always override the fallback.
public struct AutoConnectConfig: Codable, Equatable, Sendable {
    /// Master switch. When false the feature is fully off and
    /// `NETunnelProviderManager.isOnDemandEnabled` is set to false.
    public var enabled: Bool
    public var ssidRules: [SSIDRule]
    public var cellular: AutoConnectAction
    /// Action used when no SSID rule and the cellular rule do not match —
    /// covers Wi-Fi networks the user has not named, plus interface
    /// types that aren't Wi-Fi or cellular.
    public var fallback: AutoConnectAction

    public init(
        enabled: Bool,
        ssidRules: [SSIDRule],
        cellular: AutoConnectAction,
        fallback: AutoConnectAction
    ) {
        self.enabled = enabled
        self.ssidRules = ssidRules
        self.cellular = cellular
        self.fallback = fallback
    }

    public static let defaults = AutoConnectConfig(
        enabled: false,
        ssidRules: [],
        cellular: .ignore,
        fallback: .ignore
    )
}

/// How many tunnel sessions the host app keeps in `FilePath.logsDirectory`.
/// Mihomo and ProxyCat Swift logs are retained separately, and files
/// currently being written to are always preserved.
public enum LogRetention: Int, Codable, CaseIterable, Sendable {
    case keepAll = 0
    case last10 = 10
    case last50 = 50
    case last100 = 100
}

/// Umbrella container for everything persisted in `host_settings.json`.
/// New host-only features become new fields on this struct, not new
/// files. The Go core never reads this file — it's host (iOS) only.
public struct HostSettings: Codable, Equatable, Sendable {
    public var autoConnect: AutoConnectConfig
    public var logRetention: LogRetention

    public init(autoConnect: AutoConnectConfig, logRetention: LogRetention = .keepAll) {
        self.autoConnect = autoConnect
        self.logRetention = logRetention
    }

    public static let defaults = HostSettings(autoConnect: .defaults)

    // Backwards-compatible decode for host_settings.json files written
    // before logRetention existed. Without this, an absent key would
    // throw and HostSettingsStore.load would fall back to defaults,
    // wiping the user's autoConnect config on first launch with the
    // new build.
    private enum CodingKeys: String, CodingKey {
        case autoConnect
        case logRetention
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoConnect = try container.decode(AutoConnectConfig.self, forKey: .autoConnect)
        logRetention = try container.decodeIfPresent(LogRetention.self, forKey: .logRetention) ?? .keepAll
    }
}
