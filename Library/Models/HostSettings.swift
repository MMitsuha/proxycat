import Foundation

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
