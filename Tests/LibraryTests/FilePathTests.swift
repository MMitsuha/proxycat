import Foundation
import Testing
@testable import Library

@Suite struct FilePathMarkerTests {
    private let logsDirectory = URL(fileURLWithPath: "/tmp/proxycat-current/Logs", isDirectory: true)

    @Test func prefersStoredPathWhenItStillExists() {
        let stored = "/tmp/proxycat-old/Logs/mihomo-20261124-201500.log"
        let resolved = FilePath.resolvedActiveLogPath(
            storedPath: stored,
            logsDirectory: logsDirectory,
            fileExists: { $0 == stored }
        )
        #expect(resolved == stored)
    }

    @Test func resolvesStaleContainerPathByFilename() {
        let stored = "/tmp/proxycat-old/Logs/mihomo-20261124-201500.log"
        let expected = logsDirectory.appendingPathComponent("mihomo-20261124-201500.log").path
        let resolved = FilePath.resolvedActiveLogPath(
            storedPath: stored,
            logsDirectory: logsDirectory,
            fileExists: { $0 == expected }
        )
        #expect(resolved == expected)
    }

    @Test func returnsNilWhenNeitherPathExists() {
        let resolved = FilePath.resolvedActiveLogPath(
            storedPath: "/tmp/proxycat-old/Logs/mihomo-gone.log",
            logsDirectory: logsDirectory,
            fileExists: { _ in false }
        )
        #expect(resolved == nil)
    }

    @Test func rejectsEmptyStoredPath() {
        let resolved = FilePath.resolvedActiveLogPath(
            storedPath: "",
            logsDirectory: logsDirectory,
            fileExists: { _ in true }
        )
        #expect(resolved == nil)
    }
}
