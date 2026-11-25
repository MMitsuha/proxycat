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

    @Test func parsePortAcceptsWhitespaceAndRejectsInvalidText() {
        #expect(WebEditorSettings.parsePort("8787") == 8_787)
        #expect(WebEditorSettings.parsePort(" 1024 \n") == 1_024)
        #expect(WebEditorSettings.parsePort("") == nil)
        #expect(WebEditorSettings.parsePort("   ") == nil)
        #expect(WebEditorSettings.parsePort("8080abc") == nil)
        #expect(WebEditorSettings.parsePort("1023") == nil)
        #expect(WebEditorSettings.parsePort("65536") == nil)
    }

    @Test func backupCopyDropsWebEditorButKeepsOtherSettings() {
        let settings = HostSettings(
            autoConnect: .defaults,
            logRetention: .last50,
            webEditor: WebEditorSettings(isEnabled: true, port: 9_000)
        )
        let backup = settings.backupCopy
        #expect(backup.webEditor == .defaults)
        #expect(backup.logRetention == .last50)
        #expect(settings.webEditor.isEnabled)
        #expect(settings.webEditor.port == 9_000)
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

    @Test func noContentResponseOmitsContentLength() throws {
        let response = WebConfigHTTPResponse.empty(status: 204)
        let text = try #require(String(data: response.serialized, encoding: .utf8))
        #expect(text.hasPrefix("HTTP/1.1 204 No Content\r\n"))
        #expect(!text.contains("Content-Length"))
    }

    @Test func htmlResponseCannotBeFramed() throws {
        let response = WebConfigHTTPResponse.html("<html></html>")
        let text = try #require(String(data: response.serialized, encoding: .utf8))
        #expect(text.contains("frame-ancestors 'none'"))
        #expect(text.contains("X-Frame-Options: DENY"))
    }

    @Test func timeoutResponseUses408() throws {
        let response = WebConfigHTTPResponse.jsonError("Request timed out", status: 408)
        let text = try #require(String(data: response.serialized, encoding: .utf8))
        #expect(text.hasPrefix("HTTP/1.1 408 Request Timeout\r\n"))
    }
}

@Suite struct LocalNetworkAddressRankTests {
    @Test func ranksLANInterfacesAndRejectsVirtualOnes() {
        #expect(LocalNetworkAddress.interfaceRank(for: "en0") == 4)
        #expect(LocalNetworkAddress.interfaceRank(for: "en1") == 3)
        #expect(LocalNetworkAddress.interfaceRank(for: "bridge100") == 2)
        #expect(LocalNetworkAddress.interfaceRank(for: "ap1") == 1)
        #expect(LocalNetworkAddress.interfaceRank(for: "utun3") == nil)
        #expect(LocalNetworkAddress.interfaceRank(for: "ipsec0") == nil)
        #expect(LocalNetworkAddress.interfaceRank(for: "pdp_ip0") == nil)
        #expect(LocalNetworkAddress.interfaceRank(for: "awdl0") == nil)
    }
}

@MainActor
@Suite struct WebConfigURLTests {
    @Test func baseURLDoesNotExposeToken() throws {
        let urls = WebConfigServer.makeURLs(
            host: "192.0.2.10",
            port: 8_787,
            token: "secret-token"
        )
        let base = try #require(urls.base)
        #expect(base.absoluteString == "http://192.0.2.10:8787/")
        #expect(base.query == nil)
        #expect(!base.absoluteString.contains("secret-token"))
    }

    @Test func accessURLIncludesTokenAndLocalURLUsesLoopback() throws {
        let urls = WebConfigServer.makeURLs(
            host: "192.0.2.10",
            port: 9_000,
            token: "secret-token"
        )
        let access = try #require(urls.access)
        let local = try #require(urls.local)
        let accessComponents = try #require(URLComponents(url: access, resolvingAgainstBaseURL: false))
        let localComponents = try #require(URLComponents(url: local, resolvingAgainstBaseURL: false))

        #expect(accessComponents.queryItems == [URLQueryItem(name: "token", value: "secret-token")])
        #expect(accessComponents.host == "192.0.2.10")
        #expect(accessComponents.port == 9_000)
        #expect(localComponents.host == "127.0.0.1")
        #expect(localComponents.port == 9_000)
        #expect(localComponents.queryItems == [URLQueryItem(name: "token", value: "secret-token")])
    }
}

@MainActor
@Suite struct WebConfigRouterTests {
    private let router = WebConfigRouter()

    private func request(_ method: String, _ path: String) -> WebConfigHTTPRequest {
        WebConfigHTTPRequest(
            method: method,
            path: path,
            query: [:],
            headers: [:],
            body: Data()
        )
    }

    @Test func apiRequiresToken() async {
        let response = await router.respond(to: request("GET", "/api/profiles"), token: nil)
        #expect(response.status == 401)
    }

    @Test func unknownPathRequiresToken() async {
        let response = await router.respond(to: request("GET", "/not-a-route"), token: nil)
        #expect(response.status == 401)
    }

    @Test func faviconIsPublic() async {
        let response = await router.respond(to: request("GET", "/favicon.ico"), token: nil)
        #expect(response.status == 204)
    }

    @Test func rootDoesNotRequireToken() async {
        // With bundled assets available this is 200; in a source-only test
        // harness it is 500. Either way it must not be the API 401.
        let response = await router.respond(to: request("GET", "/"), token: nil)
        #expect(response.status != 401)
    }

    @Test func staticAssetsArePublic() async {
        let css = await router.respond(to: request("GET", "/app.css"), token: nil)
        let js = await router.respond(to: request("GET", "/app.js"), token: nil)
        #expect(css.status != 401)
        #expect(js.status != 401)
    }

    @Test func validationErrorsAreClientErrorsAndStorageErrorsAreServerErrors() {
        #expect(WebConfigRouter.status(for: ProfileValidationError(message: "bad yaml")) == 400)
        #expect(WebConfigRouter.status(for: CocoaError(.fileWriteNoPermission)) == 500)
        #expect(WebConfigRouter.status(for: ProfileError.profileDeleted) == 404)
    }
}
