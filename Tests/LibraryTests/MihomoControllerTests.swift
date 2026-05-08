import XCTest
@testable import Library

final class MihomoControllerTests: XCTestCase {
    func testPercentEncodeSegmentEscapesSlash() {
        XCTAssertEqual(MihomoController.percentEncodeSegment("JP/Tokyo"), "JP%2FTokyo")
        XCTAssertEqual(MihomoController.percentEncodeSegment("a/b/c"), "a%2Fb%2Fc")
    }

    func testPercentEncodeSegmentLeavesUnreservedAlone() {
        XCTAssertEqual(MihomoController.percentEncodeSegment("Direct"), "Direct")
        XCTAssertEqual(MihomoController.percentEncodeSegment("US-West.1"), "US-West.1")
    }

    func testPercentEncodeSegmentEscapesQueryAndFragment() {
        XCTAssertEqual(MihomoController.percentEncodeSegment("a?b"), "a%3Fb")
        XCTAssertEqual(MihomoController.percentEncodeSegment("a#b"), "a%23b")
        XCTAssertEqual(MihomoController.percentEncodeSegment("a b"), "a%20b")
    }

    /// The full composition path: a slash inside a proxy group name is
    /// encoded as `%2F` and survives URL assembly as one segment, so chi's
    /// `{name}` route matches it and `url.PathUnescape` round-trips it
    /// back to `JP/Tokyo` server-side.
    func testMakeURLPreservesEscapedSlashInPath() {
        let controller = MihomoController(baseURL: URL(string: "http://127.0.0.1:9090")!)
        let segment = MihomoController.percentEncodeSegment("JP/Tokyo")
        let url = controller.makeURL(path: "proxies/\(segment)")
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:9090/proxies/JP%2FTokyo")
    }

    func testMakeURLAppendsQueryItems() {
        let controller = MihomoController(baseURL: URL(string: "http://127.0.0.1:9090")!)
        let segment = MihomoController.percentEncodeSegment("JP/Tokyo")
        let url = controller.makeURL(
            path: "group/\(segment)/delay",
            queryItems: [
                URLQueryItem(name: "url", value: "https://www.gstatic.com/generate_204"),
                URLQueryItem(name: "timeout", value: "5000"),
            ]
        )
        XCTAssertEqual(url.path, "/group/JP/Tokyo/delay")  // .path decodes %2F
        XCTAssertTrue(url.absoluteString.contains("/group/JP%2FTokyo/delay"),
                      "expected escaped slash in path, got \(url.absoluteString)")
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        XCTAssertEqual(comps.queryItems?.first { $0.name == "timeout" }?.value, "5000")
    }

    func testMakeURLHandlesBaseWithTrailingSlash() {
        let controller = MihomoController(baseURL: URL(string: "http://127.0.0.1:9090/")!)
        let url = controller.makeURL(path: "proxies")
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:9090/proxies")
    }

    func testStaticMakeURLEncodesConnectionId() {
        let base = URL(string: "http://127.0.0.1:9090")!
        let id = "abc/def"  // synthetic — real mihomo IDs are UUIDs
        let url = MihomoController.makeURL(
            baseURL: base,
            path: "connections/\(MihomoController.percentEncodeSegment(id))"
        )
        XCTAssertEqual(url.absoluteString, "http://127.0.0.1:9090/connections/abc%2Fdef")
    }
}
