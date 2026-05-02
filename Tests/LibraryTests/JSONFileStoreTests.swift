import XCTest
@testable import Library

final class JSONFileStoreTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("io.proxycat.test.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        tempDir = dir
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    private func path(_ name: String) -> String {
        tempDir.appendingPathComponent(name).path
    }

    struct Sample: Codable, Equatable {
        var x: Int
        var s: String
    }

    func testLoadDefaultsWhenMissing() {
        let p = path("missing.json")
        let result = JSONFileStore.load(Sample.self, at: p, default: Sample(x: 7, s: "fallback"))
        XCTAssertEqual(result, Sample(x: 7, s: "fallback"))
    }

    func testRoundTrip() throws {
        let p = path("ok.json")
        let value = Sample(x: 42, s: "hello")
        try JSONFileStore.save(value, to: p)
        let loaded = JSONFileStore.load(Sample.self, at: p, default: Sample(x: 0, s: ""))
        XCTAssertEqual(loaded, value)
    }

    func testLoadFallsBackOnCorruptJSON() throws {
        let p = path("garbage.json")
        try Data("not-json".utf8).write(to: URL(fileURLWithPath: p))
        let loaded = JSONFileStore.load(Sample.self, at: p, default: Sample(x: 1, s: "fb"))
        XCTAssertEqual(loaded, Sample(x: 1, s: "fb"))
    }

    func testSaveOrLogReturnsTrueOnSuccess() throws {
        let p = path("ok2.json")
        let ok = JSONFileStore.saveOrLog(Sample(x: 1, s: "y"), to: p, category: "test")
        XCTAssertTrue(ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: p))
    }

    func testSaveOrLogReturnsFalseOnUnwritablePath() {
        // No such directory — write must fail, and the function must
        // return false rather than crash, so callers don't broadcast a
        // change that's not actually persisted.
        let p = "/dev/null/definitely-not-writable/x.json"
        let ok = JSONFileStore.saveOrLog(Sample(x: 1, s: "y"), to: p, category: "test")
        XCTAssertFalse(ok)
    }
}
