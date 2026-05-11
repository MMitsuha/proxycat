import Foundation
import Testing
@testable import Library

@Suite final class ProxyCatLogPersistenceTests {
    private let tempDir: URL

    init() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("io.proxycat.log-test.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.tempDir = dir
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @Test func writesProxyCatExtensionPrefixedUTF8SessionLog() throws {
        let date = Date(timeIntervalSince1970: 1_778_484_600)
        let file = try PersistentLogFile(
            directory: tempDir,
            prefix: AppConfiguration.proxyCatExtensionLogFilePrefix,
            sessionName: "proxycat-extension",
            openedAt: date
        )

        file.append(level: "INFO", category: "PTP", message: "startTunnel", at: date)
        file.close(sessionName: "proxycat-extension", at: date)

        #expect(file.url.lastPathComponent.hasPrefix("proxycat-extension-"))
        #expect(file.url.pathExtension == "log")

        let text = try String(contentsOf: file.url, encoding: .utf8)
        #expect(text.contains("=== proxycat-extension session started "))
        #expect(text.contains("[INFO] [PTP] startTunnel"))
        #expect(text.contains("=== proxycat-extension session ended "))
    }

    @Test func sameSecondCollisionGetsNumericSuffix() throws {
        let date = Date(timeIntervalSince1970: 1_778_484_600)
        let first = try PersistentLogFile(
            directory: tempDir,
            prefix: AppConfiguration.proxyCatHostLogFilePrefix,
            sessionName: "proxycat-host",
            openedAt: date
        )
        let second = try PersistentLogFile(
            directory: tempDir,
            prefix: AppConfiguration.proxyCatHostLogFilePrefix,
            sessionName: "proxycat-host",
            openedAt: date
        )

        first.close(sessionName: "proxycat-host", at: date)
        second.close(sessionName: "proxycat-host", at: date)

        #expect(first.url.lastPathComponent.hasPrefix("proxycat-host-"))
        #expect(second.url.lastPathComponent.hasPrefix("proxycat-host-"))
        #expect(second.url.lastPathComponent.hasSuffix("-1.log"))
    }

    @Test func hostAndExtensionRolesUseSeparateFilesAndMarkers() {
        #expect(ProxyCatLogRole.hostApp.prefix == AppConfiguration.proxyCatHostLogFilePrefix)
        #expect(ProxyCatLogRole.packetTunnel.prefix == AppConfiguration.proxyCatExtensionLogFilePrefix)
        #expect(ProxyCatLogRole.hostApp.markerFileName == AppConfiguration.activeProxyCatHostLogMarkerFileName)
        #expect(ProxyCatLogRole.packetTunnel.markerFileName == AppConfiguration.activeProxyCatExtensionLogMarkerFileName)
    }
}
