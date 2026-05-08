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

    /// The full composition path: a slash inside a proxy group name is
    /// encoded as `%2F` and survives URL assembly as one segment, so chi's
    /// `{name}` route matches it and `url.PathUnescape` round-trips it
    /// back to `JP/Tokyo` server-side.
    @Test func makeURLPreservesEscapedSlashInPath() {
        let controller = MihomoController(baseURL: URL(string: "http://127.0.0.1:9090")!)
        let segment = MihomoController.percentEncodeSegment("JP/Tokyo")
        let url = controller.makeURL(path: "proxies/\(segment)")
        #expect(url.absoluteString == "http://127.0.0.1:9090/proxies/JP%2FTokyo")
    }

    @Test func makeURLAppendsQueryItems() {
        let controller = MihomoController(baseURL: URL(string: "http://127.0.0.1:9090")!)
        let segment = MihomoController.percentEncodeSegment("JP/Tokyo")
        let url = controller.makeURL(
            path: "group/\(segment)/delay",
            queryItems: [
                URLQueryItem(name: "url", value: "https://www.gstatic.com/generate_204"),
                URLQueryItem(name: "timeout", value: "5000"),
            ]
        )
        #expect(url.path == "/group/JP/Tokyo/delay")  // .path decodes %2F
        #expect(url.absoluteString.contains("/group/JP%2FTokyo/delay"),
                "expected escaped slash in path, got \(url.absoluteString)")
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        #expect(comps.queryItems?.first { $0.name == "timeout" }?.value == "5000")
    }

    @Test func makeURLHandlesBaseWithTrailingSlash() {
        let controller = MihomoController(baseURL: URL(string: "http://127.0.0.1:9090/")!)
        let url = controller.makeURL(path: "proxies")
        #expect(url.absoluteString == "http://127.0.0.1:9090/proxies")
    }

    @Test func staticMakeURLEncodesConnectionId() {
        let base = URL(string: "http://127.0.0.1:9090")!
        let id = "abc/def"  // synthetic — real mihomo IDs are UUIDs
        let url = MihomoController.makeURL(
            baseURL: base,
            path: "connections/\(MihomoController.percentEncodeSegment(id))"
        )
        #expect(url.absoluteString == "http://127.0.0.1:9090/connections/abc%2Fdef")
    }
}
