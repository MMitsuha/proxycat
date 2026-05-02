import XCTest
@testable import Library

final class ProfileStoreTests: XCTestCase {
    func testProfileCodableRoundTrip() throws {
        let original = Profile(
            name: "My VPN",
            fileName: "my.yaml",
            remoteURL: URL(string: "https://example.com/sub.yaml"),
            lastUpdated: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testProfileWithoutOptionalFields() throws {
        let original = Profile(name: "Local", fileName: "local.yaml")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)
        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.remoteURL)
        XCTAssertNil(decoded.lastUpdated)
    }

    func testProfileIDIsStableAcrossEncoding() throws {
        // The `id` field is what binds the active-profile pointer file to
        // an entry in index.json. Codable must round-trip it intact;
        // otherwise the user's active selection would silently reset on
        // every relaunch.
        let id = UUID()
        let p = Profile(id: id, name: "x", fileName: "x.yaml")
        let data = try JSONEncoder().encode(p)
        let back = try JSONDecoder().decode(Profile.self, from: data)
        XCTAssertEqual(back.id, id)
    }
}
