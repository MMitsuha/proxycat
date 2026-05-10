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
