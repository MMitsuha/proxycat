import Foundation
import Testing
@testable import Library

@Suite struct MihomoControllerTests {
    @Test func percentEncodeSegmentEscapesSlash() {
        #expect(MihomoController.percentEncodeSegment("JP/Tokyo") == "JP%2FTokyo")
        #expect(MihomoController.percentEncodeSegment("a/b/c") == "a%2Fb%2Fc")
    }

    @Test func percentEncodeSegmentLeavesUnreservedAlone() {
        #expect(MihomoController.percentEncodeSegment("Direct") == "Direct")
        #expect(MihomoController.percentEncodeSegment("US-West.1") == "US-West.1")
    }

    @Test func percentEncodeSegmentEscapesQueryAndFragment() {
        #expect(MihomoController.percentEncodeSegment("a?b") == "a%3Fb")
        #expect(MihomoController.percentEncodeSegment("a#b") == "a%23b")
        #expect(MihomoController.percentEncodeSegment("a b") == "a%20b")
    }

    /// A slash inside a proxy group name is encoded as `%2F` and survives
    /// path assembly as one segment, so chi's `{name}` route matches it
    /// and `url.PathUnescape` round-trips it back to `JP/Tokyo` server-side.
    @Test func makePathPreservesEscapedSlashInPath() {
        let segment = MihomoController.percentEncodeSegment("JP/Tokyo")
        let path = MihomoController.makePath("proxies/\(segment)")
        #expect(path == "/proxies/JP%2FTokyo")
    }

    @Test func makePathAppendsQueryItems() {
        let segment = MihomoController.percentEncodeSegment("JP/Tokyo")
        let path = MihomoController.makePath(
            "group/\(segment)/delay",
            queryItems: [
                URLQueryItem(name: "url", value: "https://www.gstatic.com/generate_204"),
                URLQueryItem(name: "timeout", value: "5000"),
            ]
        )
        #expect(path.hasPrefix("/group/JP%2FTokyo/delay?"))
        #expect(path.contains("timeout=5000"))
        #expect(path.contains("url=https"))
    }

    @Test func makePathOmitsQueryWhenEmpty() {
        let path = MihomoController.makePath("proxies")
        #expect(path == "/proxies")
    }

    @Test func makePathEncodesConnectionId() {
        let id = "abc/def"  // synthetic — real mihomo IDs are UUIDs
        let path = MihomoController.makePath(
            "connections/\(MihomoController.percentEncodeSegment(id))"
        )
        #expect(path == "/connections/abc%2Fdef")
    }
}
