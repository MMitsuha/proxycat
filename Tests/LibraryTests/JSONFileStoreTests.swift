import Foundation
import Testing
@testable import Library

@Suite final class JSONFileStoreTests {
    private let tempDir: URL

    init() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("io.proxycat.test.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.tempDir = dir
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func path(_ name: String) -> String {
        tempDir.appendingPathComponent(name).path
    }

    struct Sample: Codable, Equatable {
        var x: Int
        var s: String
    }

    @Test func loadDefaultsWhenMissing() {
        let p = path("missing.json")
        let result = JSONFileStore.load(Sample.self, at: p, default: Sample(x: 7, s: "fallback"))
        #expect(result == Sample(x: 7, s: "fallback"))
    }

    @Test func roundTrip() throws {
        let p = path("ok.json")
        let value = Sample(x: 42, s: "hello")
        try JSONFileStore.save(value, to: p)
        let loaded = JSONFileStore.load(Sample.self, at: p, default: Sample(x: 0, s: ""))
        #expect(loaded == value)
    }

    @Test func loadFallsBackOnCorruptJSON() throws {
        let p = path("garbage.json")
        try Data("not-json".utf8).write(to: URL(fileURLWithPath: p))
        let loaded = JSONFileStore.load(Sample.self, at: p, default: Sample(x: 1, s: "fb"))
        #expect(loaded == Sample(x: 1, s: "fb"))
    }

    @Test func saveOrLogReturnsTrueOnSuccess() throws {
        let p = path("ok2.json")
        let ok = JSONFileStore.saveOrLog(Sample(x: 1, s: "y"), to: p, category: "test")
        #expect(ok)
        #expect(FileManager.default.fileExists(atPath: p))
    }

    @Test func saveOrLogReturnsFalseOnUnwritablePath() {
        // No such directory — write must fail, and the function must
        // return false rather than crash, so callers don't broadcast a
        // change that's not actually persisted.
        let p = "/dev/null/definitely-not-writable/x.json"
        let ok = JSONFileStore.saveOrLog(Sample(x: 1, s: "y"), to: p, category: "test")
        #expect(!ok)
    }
}
