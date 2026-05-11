import Testing
@testable import Library

@Suite struct MitmProfileConfigTests {
    @Test func parsesExistingMitmBlock() {
        let yaml = """
        mode: rule

        mitm:
          enable: true
          domain:
            - +.example.com
            - 'domain.com'
          ports: [80, 443, 8443]
          encrypted-sni-policy: reject
          rules:
            - url: '^https?://ads\\.example\\.com/.*'
              action: reject

        proxies: []
        """

        let config = MitmProfileConfigYAML.config(from: yaml)

        #expect(config.isEnabled)
        #expect(config.domains == ["+.example.com", "domain.com"])
        #expect(config.ports == [80, 443, 8443])
        #expect(config.encryptedSNIPolicy == .reject)
        #expect(config.rules == [
            MitmRewriteRule(
                url: "^https?://ads\\.example\\.com/.*",
                action: .reject
            ),
        ])
    }

    @Test func replacingExistingMitmBlockPreservesOtherProfileContent() throws {
        let yaml = """
        mode: rule
        log-level: info
        mitm:
          enable: false
          ports:
            - 443
        proxies:
          - { name: DIRECT, type: direct }
        """
        let config = MitmProfileConfig(
            isEnabled: true,
            domains: ["+.example.com"],
            ports: [443, 8443],
            encryptedSNIPolicy: .skip,
            rules: [
                MitmRewriteRule(
                    url: "^https?://example\\.com/.*",
                    action: .reject200
                ),
            ]
        )

        let updated = try MitmProfileConfigYAML.replacingConfig(in: yaml, with: config)

        #expect(updated.contains("mode: rule"))
        #expect(updated.contains("log-level: info"))
        #expect(updated.contains("proxies:"))
        #expect(updated.contains("  enable: true"))
        #expect(updated.contains("    - '+.example.com'"))
        #expect(updated.contains("    - 8443"))
        #expect(updated.contains("      action: 'reject-200'"))
    }

    @Test func appendsMitmBlockWhenMissing() throws {
        let yaml = """
        mode: rule
        proxies: []
        """
        let config = MitmProfileConfig(isEnabled: false, ports: [443], encryptedSNIPolicy: .skip)

        let updated = try MitmProfileConfigYAML.replacingConfig(in: yaml, with: config)

        #expect(updated.contains("\n\nmitm:\n"))
        #expect(updated.hasSuffix("  encrypted-sni-policy: skip\n"))
    }

    @Test func portTextValidationRejectsOutOfRangeValues() {
        do {
            _ = try MitmProfileConfigYAML.parsePortsText("443, 70000")
            Issue.record("Expected invalid port to throw")
        } catch let error as MitmProfileConfigError {
            #expect(error == .invalidPort("70000"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func enabledConfigRequiresAtLeastOnePort() {
        let config = MitmProfileConfig(isEnabled: true, ports: [])

        do {
            _ = try MitmProfileConfigYAML.replacingConfig(in: "mode: rule\n", with: config)
            Issue.record("Expected missing port to throw")
        } catch let error as MitmProfileConfigError {
            #expect(error == .missingEnabledPort)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func rendersRulesFromStructuredValues() throws {
        let config = MitmProfileConfig(
            isEnabled: true,
            ports: [80, 443],
            rules: [
                MitmRewriteRule(
                    url: "^https?://api\\.example\\.com/v1/(.*)",
                    action: .redirect302,
                    new: "https://api.example.com/v2/$1"
                ),
                MitmRewriteRule(
                    url: "^https?://example\\.com/score",
                    action: .responseBody,
                    old: "\"score\":\\d+",
                    new: "\"score\":999"
                ),
            ]
        )

        let updated = try MitmProfileConfigYAML.replacingConfig(in: "mode: rule\n", with: config)

        #expect(updated.contains("      action: '302'"))
        #expect(updated.contains("      new: 'https://api.example.com/v2/$1'"))
        #expect(updated.contains("      action: 'response-body'"))
        #expect(updated.contains("      old: '\"score\":\\d+'"))
        #expect(updated.contains("      new: '\"score\":999'"))
    }

    @Test func rewriteActionWithNewValueRequiresReplacement() {
        let config = MitmProfileConfig(
            rules: [
                MitmRewriteRule(url: "^https?://example\\.com/.*", action: .redirect302),
            ]
        )

        do {
            _ = try MitmProfileConfigYAML.replacingConfig(in: "mode: rule\n", with: config)
            Issue.record("Expected missing replacement to throw")
        } catch let error as MitmProfileConfigError {
            #expect(error == .missingRuleNewValue("302"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
