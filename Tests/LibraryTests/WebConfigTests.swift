import Foundation
import Testing
@testable import Library

@Suite struct WebEditorSettingsTests {
    @Test func defaultsAreDisabledWithValidPort() {
        let settings = WebEditorSettings.defaults
        #expect(!settings.isEnabled)
        #expect(settings.port == 8_787)
        #expect(settings.hasValidPort)
    }

    @Test func portRangeRejectsPrivilegedAndInvalidPorts() {
        #expect(!WebEditorSettings(port: 80).hasValidPort)
        #expect(!WebEditorSettings(port: 1_023).hasValidPort)
        #expect(WebEditorSettings(port: 1_024).hasValidPort)
        #expect(WebEditorSettings(port: 65_535).hasValidPort)
        #expect(!WebEditorSettings(port: 65_536).hasValidPort)
    }

    @Test func hostSettingsRoundTripsWebEditor() throws {
        let settings = HostSettings(
            autoConnect: .defaults,
            logRetention: .last10,
            webEditor: WebEditorSettings(isEnabled: true, port: 9_090)
        )
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(HostSettings.self, from: data)
        #expect(decoded == settings)
        #expect(decoded.webEditor.isEnabled)
        #expect(decoded.webEditor.port == 9_090)
    }

    @Test func hostSettingsDecodesPreWebEditorJSON() throws {
        let legacy = """
        {
          "autoConnect": {
            "enabled": true,
            "ssidRules": [],
            "cellular": 1,
            "fallback": 0
          },
          "logRetention": 50
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(HostSettings.self, from: legacy)
        #expect(decoded.logRetention == .last50)
        #expect(decoded.webEditor == .defaults)
    }
}

@Suite struct WebConfigHTTPResponseTests {
    @Test func jsonResponseIsSerializedWithContentLength() throws {
        let response = WebConfigHTTPResponse.json(["ok": true], status: 200)
        let text = try #require(String(data: response.serialized, encoding: .utf8))
        #expect(text.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(text.contains("Content-Type: application/json; charset=utf-8"))
        #expect(text.contains("Content-Length: "))
        #expect(text.contains("Connection: close"))
        #expect(text.contains("{\"ok\":true}"))
    }

    @Test func errorResponseUsesRequestedStatus() throws {
        let response = WebConfigHTTPResponse.jsonError("Unauthorized", status: 401)
        let text = try #require(String(data: response.serialized, encoding: .utf8))
        #expect(text.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        #expect(text.contains("{\"error\":\"Unauthorized\"}"))
    }
}
