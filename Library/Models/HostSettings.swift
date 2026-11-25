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

/// Host-only settings for the LAN web editor. The access token is
/// generated per server session and never persisted.
public struct WebEditorSettings: Codable, Equatable, Sendable {
    public static let portRange = 1_024 ... 65_535

    public var isEnabled: Bool
    public var port: Int

    public init(isEnabled: Bool = false, port: Int = 8_787) {
        self.isEnabled = isEnabled
        self.port = port
    }

    public static let defaults = WebEditorSettings()

    public var hasValidPort: Bool {
        Self.portRange.contains(port)
    }
}

/// Umbrella container for everything persisted in `host_settings.json`.
/// New host-only features become new fields on this struct, not new
/// files. The Go core never reads this file — it's host (iOS) only.
public struct HostSettings: Codable, Equatable, Sendable {
    public var autoConnect: AutoConnectConfig
    public var logRetention: LogRetention
    public var webEditor: WebEditorSettings

    public init(
        autoConnect: AutoConnectConfig,
        logRetention: LogRetention = .keepAll,
        webEditor: WebEditorSettings = .defaults
    ) {
        self.autoConnect = autoConnect
        self.logRetention = logRetention
        self.webEditor = webEditor
    }

    public static let defaults = HostSettings(autoConnect: .defaults)

    // Backwards-compatible decode for host_settings.json files written
    // before newer fields existed. Without this, an absent key would
    // throw and HostSettingsStore.load would fall back to defaults,
    // wiping the user's autoConnect config on first launch with the
    // new build.
    private enum CodingKeys: String, CodingKey {
        case autoConnect
        case logRetention
        case webEditor
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        autoConnect = try container.decode(AutoConnectConfig.self, forKey: .autoConnect)
        logRetention = try container.decodeIfPresent(LogRetention.self, forKey: .logRetention) ?? .keepAll
        webEditor = try container.decodeIfPresent(WebEditorSettings.self, forKey: .webEditor) ?? .defaults
    }
}
