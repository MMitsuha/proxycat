import Foundation
import Testing
@testable import Library

@Suite struct ProfileStoreTests {
    @Test func profileCodableRoundTrip() throws {
        let original = Profile(
            name: "My VPN",
            fileName: "my.yaml",
            remoteURL: URL(string: "https://example.com/sub.yaml"),
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)
        #expect(decoded == original)
    }

    @Test func profileWithoutOptionalFields() throws {
        let original = Profile(name: "Local", fileName: "local.yaml")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)
        #expect(decoded == original)
        #expect(decoded.remoteURL == nil)
        #expect(decoded.lastUpdated == nil)
    }

    @Test func profileIDIsStableAcrossEncoding() throws {
        // The `id` field is what binds the `activeProfileID` field of
        // runtime_settings.json to an entry in index.json. Codable must
        // round-trip it intact; otherwise the user's active selection
        // would silently reset on every relaunch.
        let id = UUID()
        let p = Profile(id: id, name: "x", fileName: "x.yaml")
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Profile.self, from: data)
        #expect(back.id == id)
    }

    @Test func activeProfileRepairKeepsValidStoredSelection() {
        let first = Profile(id: UUID(), name: "first", fileName: "first.yaml")
        let second = Profile(id: UUID(), name: "second", fileName: "second.yaml")

        let repaired = ProfileStore.repairedActiveProfileID(
            profiles: [first, second],
            storedID: second.id
        )

        #expect(repaired == second.id)
    }

    @Test func activeProfileRepairFallsBackWhenStoredSelectionIsStale() {
        let first = Profile(id: UUID(), name: "first", fileName: "first.yaml")
        let second = Profile(id: UUID(), name: "second", fileName: "second.yaml")

        let repaired = ProfileStore.repairedActiveProfileID(
            profiles: [first, second],
            storedID: UUID()
        )

        #expect(repaired == first.id)
    }

    @Test func activeProfileRepairClearsSelectionWhenCatalogIsEmpty() {
        let repaired = ProfileStore.repairedActiveProfileID(
            profiles: [],
            storedID: UUID()
        )

        #expect(repaired == nil)
    }
}

@Suite struct ProfileStoreDirectoryRecoveryTests {
    private let fm = FileManager.default

    private func makeRoot() throws -> URL {
        let root = fm.temporaryDirectory
            .appendingPathComponent("proxycat-recovery-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeCatalog(in directory: URL) throws {
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("[]".utf8).write(
            to: directory.appendingPathComponent(AppConfiguration.profileIndexFileName)
        )
        try Data("mixed-port: 7890\n".utf8).write(
            to: directory.appendingPathComponent("profile.yaml")
        )
    }

    private func hasCatalog(_ directory: URL) -> Bool {
        fm.fileExists(
            atPath: directory.appendingPathComponent(AppConfiguration.profileIndexFileName).path
        ) && fm.fileExists(atPath: directory.appendingPathComponent("profile.yaml").path)
    }

    @Test func promotesPreviousCatalogWhenLiveDirectoryIsEmpty() throws {
        // The app recreates an empty Profiles/ directory on launch, so
        // existence alone can't distinguish a crash from a fresh install.
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let previous = root.appendingPathComponent("Profiles.previous-\(UUID().uuidString)")
        try makeCatalog(in: previous)
        let live = root.appendingPathComponent("Profiles")
        try fm.createDirectory(at: live, withIntermediateDirectories: true)

        ProfileStoreDirectoryRecovery.recover(root: root, fileManager: fm)

        #expect(hasCatalog(live))
        #expect(!fm.fileExists(atPath: previous.path))
    }

    @Test func keepsPopulatedCatalogAndRemovesStaleBackup() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let live = root.appendingPathComponent("Profiles")
        try makeCatalog(in: live)
        try Data("mixed-port: 1111\n".utf8).write(
            to: live.appendingPathComponent("profile.yaml")
        )
        let previous = root.appendingPathComponent("Profiles.previous-\(UUID().uuidString)")
        try makeCatalog(in: previous)

        ProfileStoreDirectoryRecovery.recover(root: root, fileManager: fm)

        let yaml = try String(
            contentsOf: live.appendingPathComponent("profile.yaml"),
            encoding: .utf8
        )
        #expect(yaml == "mixed-port: 1111\n")
        #expect(!fm.fileExists(atPath: previous.path))
    }

    @Test func discardsIncompleteRestoreTempWhenLiveCatalogExists() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let live = root.appendingPathComponent("Profiles")
        try makeCatalog(in: live)
        let temporary = root.appendingPathComponent("Profiles.restore-\(UUID().uuidString)")
        try makeCatalog(in: temporary)

        ProfileStoreDirectoryRecovery.recover(root: root, fileManager: fm)

        #expect(hasCatalog(live))
        #expect(!fm.fileExists(atPath: temporary.path))
    }

    @Test func promotesRestoreTempOnlyWhenNoPreviousExists() throws {
        let root = try makeRoot()
        defer { try? fm.removeItem(at: root) }
        let temporary = root.appendingPathComponent("Profiles.restore-\(UUID().uuidString)")
        try makeCatalog(in: temporary)

        ProfileStoreDirectoryRecovery.recover(root: root, fileManager: fm)

        #expect(hasCatalog(root.appendingPathComponent("Profiles")))
        #expect(!fm.fileExists(atPath: temporary.path))
    }
}
