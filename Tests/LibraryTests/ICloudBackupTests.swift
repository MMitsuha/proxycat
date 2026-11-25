import Foundation
import Testing
@testable import Library

@Suite struct ICloudBackupTests {
    @Test func snapshotRoundTripsProfileAndSettings() throws {
        let id = UUID()
        let profile = Profile(
            id: id,
            name: "中文配置",
            fileName: "\(id.uuidString).yaml",
            remoteURL: URL(string: "https://example.com/sub.yaml"),
            lastUpdated: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let runtime = RuntimeSettings.Snapshot(
            activeProfileID: id,
            disableExternalController: true,
            logLevel: 0
        )
        let host = HostSettings(
            autoConnect: AutoConnectConfig(
                enabled: true,
                ssidRules: [SSIDRule(ssid: "Home", action: .connect)],
                cellular: .disconnect,
                fallback: .ignore
            ),
            logRetention: .last50
        )

        let snapshot = try ICloudBackupSnapshot.make(
            profiles: [profile],
            contentsByID: [id: "mixed-port: 7890\n# 中文日志\n"],
            runtimeSettings: runtime,
            hostSettings: host,
            sourceDeviceID: UUID(),
            appVersion: "1.2.3",
            createdAt: Date(timeIntervalSince1970: 1_800_000_100)
        )

        let data = try ICloudBackupSnapshot.fileEncoder.encode(snapshot)
        let decoded = try ICloudBackupSnapshot.decoder.decode(ICloudBackupSnapshot.self, from: data)

        #expect(decoded == snapshot)
        #expect(decoded.content.profiles.first?.yaml.contains("中文日志") == true)
        #expect(decoded.content.runtimeSettings == runtime)
        #expect(decoded.content.hostSettings == host)
    }

    @Test func defaultWebEditorIsOmittedFromEncodedHostSettings() throws {
        let data = try ICloudBackupSnapshot.canonicalEncoder.encode(HostSettings.defaults)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        // Older builds hashed this exact shape; emitting an extra
        // "webEditor" key would change every backup checksum.
        #expect(object["webEditor"] == nil)
        #expect(object["autoConnect"] != nil)
        #expect(object["logRetention"] != nil)
    }

    @Test func enabledWebEditorIsPersistedInHostSettings() throws {
        let settings = HostSettings(
            autoConnect: .defaults,
            webEditor: WebEditorSettings(isEnabled: true, port: 9_000)
        )
        let data = try ICloudBackupSnapshot.canonicalEncoder.encode(settings)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let webEditor = try #require(object["webEditor"] as? [String: Any])
        #expect(webEditor["isEnabled"] as? Bool == true)
        #expect(webEditor["port"] as? Int == 9_000)
    }

    @Test func checksumTracksContentOnly() throws {
        let id = UUID()
        let profile = Profile(id: id, name: "Local", fileName: "\(id.uuidString).yaml")
        let content = ICloudBackupContent(
            runtimeSettings: RuntimeSettings.Snapshot.defaults,
            hostSettings: .defaults,
            profiles: [ICloudBackupProfile(profile: profile, yaml: "mixed-port: 7890\n")]
        )
        let sameContent = ICloudBackupContent(
            runtimeSettings: RuntimeSettings.Snapshot.defaults,
            hostSettings: .defaults,
            profiles: [ICloudBackupProfile(profile: profile, yaml: "mixed-port: 7890\n")]
        )
        let changedContent = ICloudBackupContent(
            runtimeSettings: RuntimeSettings.Snapshot.defaults,
            hostSettings: .defaults,
            profiles: [ICloudBackupProfile(profile: profile, yaml: "mixed-port: 7891\n")]
        )

        #expect(try ICloudBackupSnapshot.checksum(for: content) == ICloudBackupSnapshot.checksum(for: sameContent))
        #expect(try ICloudBackupSnapshot.checksum(for: content) != ICloudBackupSnapshot.checksum(for: changedContent))
    }

    @Test func restoreValidationRejectsUnsafeProfileFileName() throws {
        let id = UUID()
        let profile = Profile(id: id, name: "Bad", fileName: "../bad.yaml")

        do {
            _ = try ProfileStore.validatedRestoreProfiles([profile], contentsByID: [id: "mixed-port: 7890\n"])
            Issue.record("Expected path traversal file name to be rejected")
        } catch let error as ProfileRestoreError {
            #expect(error == .invalidFileName("../bad.yaml"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func restoreValidationRejectsDuplicateProfileFileNames() throws {
        let fileName = "same.yaml"
        let first = Profile(id: UUID(), name: "First", fileName: fileName)
        let second = Profile(id: UUID(), name: "Second", fileName: fileName)

        do {
            _ = try ProfileStore.validatedRestoreProfiles(
                [first, second],
                contentsByID: [
                    first.id: "mixed-port: 7890\n",
                    second.id: "mixed-port: 7891\n",
                ]
            )
            Issue.record("Expected duplicate file names to be rejected")
        } catch let error as ProfileRestoreError {
            #expect(error == .duplicateFileName(fileName))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
