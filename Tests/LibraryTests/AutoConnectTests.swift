import Foundation
import Testing
@testable import Library

@Suite struct AutoConnectTests {
    @Test func defaultsAreOff() {
        let c = AutoConnectConfig.defaults
        #expect(!c.enabled)
        #expect(c.ssidRules.isEmpty)
        #expect(c.cellular == .ignore)
        #expect(c.fallback == .ignore)
    }

    @Test func settingsCodableRoundTrip() throws {
        let original = HostSettings(
            autoConnect: AutoConnectConfig(
                enabled: true,
                ssidRules: [
                    SSIDRule(ssid: "Home", action: .connect),
                    SSIDRule(ssid: "Office", action: .disconnect),
                ],
                cellular: .connect,
                fallback: .ignore
            )
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HostSettings.self, from: data)
        #expect(decoded == original)
    }

    @Test func actionRawValuesMatchPersistedSchema() {
        // Persisted JSON keys depend on raw Int values — bumping these
        // would silently invalidate every user's stored host_settings.json.
        #expect(AutoConnectAction.ignore.rawValue == 0)
        #expect(AutoConnectAction.connect.rawValue == 1)
        #expect(AutoConnectAction.disconnect.rawValue == 2)
    }

    @Test func ssidRuleHasUniqueID() {
        let a = SSIDRule(ssid: "Home", action: .connect)
        let b = SSIDRule(ssid: "Home", action: .connect)
        #expect(a.id != b.id, "Each SSIDRule must mint its own UUID so List/ForEach can distinguish duplicate-name rules")
    }

    @Test func hostSettingsDecodesPreLogRetentionJSON() throws {
        // Old host_settings.json files predate logRetention. Decoding
        // must succeed and default the new field to .keepAll, instead
        // of throwing and forcing HostSettingsStore to fall back to
        // .defaults — which would wipe the user's autoConnect config.
        let legacy = """
        {
          "autoConnect": {
            "enabled": true,
            "ssidRules": [],
            "cellular": 1,
            "fallback": 0
          }
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(HostSettings.self, from: legacy)
        #expect(decoded.autoConnect.enabled)
        #expect(decoded.autoConnect.cellular == .connect)
        #expect(decoded.logRetention == .keepAll)
    }

    @Test func logRetentionRawValuesMatchPersistedSchema() {
        // Persisted as Int — bumping these silently invalidates every
        // user's stored selection.
        #expect(LogRetention.keepAll.rawValue == 0)
        #expect(LogRetention.last10.rawValue == 10)
        #expect(LogRetention.last50.rawValue == 50)
        #expect(LogRetention.last100.rawValue == 100)
    }
}
