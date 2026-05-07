import XCTest
@testable import Library

final class AutoConnectTests: XCTestCase {
    func testDefaultsAreOff() {
        let c = AutoConnectConfig.defaults
        XCTAssertFalse(c.enabled)
        XCTAssertTrue(c.ssidRules.isEmpty)
        XCTAssertEqual(c.cellular, .ignore)
        XCTAssertEqual(c.fallback, .ignore)
    }

    func testSettingsCodableRoundTrip() throws {
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
        XCTAssertEqual(decoded, original)
    }

    func testActionRawValuesMatchPersistedSchema() {
        // Persisted JSON keys depend on raw Int values — bumping these
        // would silently invalidate every user's stored host_settings.json.
        XCTAssertEqual(AutoConnectAction.ignore.rawValue, 0)
        XCTAssertEqual(AutoConnectAction.connect.rawValue, 1)
        XCTAssertEqual(AutoConnectAction.disconnect.rawValue, 2)
    }

    func testSSIDRuleHasUniqueID() {
        let a = SSIDRule(ssid: "Home", action: .connect)
        let b = SSIDRule(ssid: "Home", action: .connect)
        XCTAssertNotEqual(a.id, b.id, "Each SSIDRule must mint its own UUID so List/ForEach can distinguish duplicate-name rules")
    }

    func testHostSettingsDecodesPreLogRetentionJSON() throws {
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
        XCTAssertTrue(decoded.autoConnect.enabled)
        XCTAssertEqual(decoded.autoConnect.cellular, .connect)
        XCTAssertEqual(decoded.logRetention, .keepAll)
    }

    func testLogRetentionRawValuesMatchPersistedSchema() {
        // Persisted as Int — bumping these silently invalidates every
        // user's stored selection.
        XCTAssertEqual(LogRetention.keepAll.rawValue, 0)
        XCTAssertEqual(LogRetention.last10.rawValue, 10)
        XCTAssertEqual(LogRetention.last50.rawValue, 50)
        XCTAssertEqual(LogRetention.last100.rawValue, 100)
    }
}
