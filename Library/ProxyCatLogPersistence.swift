import Darwin
import Foundation
import os

public final class ProxyCatLogger: @unchecked Sendable {
    private let logger: Logger
    private let category: String

    public init(subsystem: String, category: String) {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.category = category
    }

    public func debug(_ message: String) {
        logger.debug("\(message, privacy: .public)")
        ProxyCatLogPersistence.shared.append(level: "DEBUG", category: category, message: message)
    }

    public func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        ProxyCatLogPersistence.shared.append(level: "INFO", category: category, message: message)
    }

    public func warning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        ProxyCatLogPersistence.shared.append(level: "WARN", category: category, message: message)
    }

    public func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        ProxyCatLogPersistence.shared.append(level: "ERROR", category: category, message: message)
    }
}

public enum ProxyCatLogRole: Sendable {
    case hostApp
    case packetTunnel

    var prefix: String {
        switch self {
        case .hostApp:
            return AppConfiguration.proxyCatHostLogFilePrefix
        case .packetTunnel:
            return AppConfiguration.proxyCatExtensionLogFilePrefix
        }
    }

    var sessionName: String {
        switch self {
        case .hostApp:
            return "proxycat-host"
        case .packetTunnel:
            return "proxycat-extension"
        }
    }

    var markerFileName: String {
        switch self {
        case .hostApp:
            return AppConfiguration.activeProxyCatHostLogMarkerFileName
        case .packetTunnel:
            return AppConfiguration.activeProxyCatExtensionLogMarkerFileName
        }
    }
}

public final class ProxyCatLogPersistence: @unchecked Sendable {
    public static let shared = ProxyCatLogPersistence()

    private let lock = NSLock()
    private var current: PersistentLogFile?
    private var markerURL: URL?

    private init() {}

    @discardableResult
    public func start(
        directory: URL = FilePath.logsDirectory,
        role: ProxyCatLogRole = .packetTunnel
    ) throws -> String {
        lock.lock()
        if let current {
            let path = current.url.path
            if let markerURL {
                Self.writeActiveMarker(markerURL, path: path)
            }
            lock.unlock()
            return path
        }
        lock.unlock()

        let file = try PersistentLogFile(
            directory: directory,
            prefix: role.prefix,
            sessionName: role.sessionName
        )
        let marker = directory.appendingPathComponent(role.markerFileName)

        lock.lock()
        if let current {
            let path = current.url.path
            if let markerURL {
                Self.writeActiveMarker(markerURL, path: path)
            }
            lock.unlock()
            file.close()
            try? FileManager.default.removeItem(at: file.url)
            return path
        }

        current = file
        markerURL = marker
        Self.writeActiveMarker(marker, path: file.url.path)
        lock.unlock()

        return file.url.path
    }

    public func append(level: String, category: String, message: String) {
        lock.lock()
        let file = current
        lock.unlock()
        file?.append(level: level, category: category, message: message)
    }

    public func flush() {
        lock.lock()
        let file = current
        lock.unlock()
        file?.flush()
    }

    public func stop() {
        lock.lock()
        let file = current
        let marker = markerURL
        current = nil
        markerURL = nil
        lock.unlock()

        guard let file else { return }
        if let marker {
            Self.removeActiveMarker(marker, path: file.url.path)
        }
        file.close()
    }

    private static func writeActiveMarker(_ markerURL: URL, path: String) {
        let data = Data((path + "\n").utf8)
        try? data.write(to: markerURL, options: .atomic)
    }

    private static func removeActiveMarker(_ markerURL: URL, path: String) {
        guard let data = try? Data(contentsOf: markerURL),
              String(data: data, encoding: .utf8) == path + "\n"
        else { return }
        try? FileManager.default.removeItem(at: markerURL)
    }
}

final class PersistentLogFile: @unchecked Sendable {
    let url: URL

    private let lock = NSLock()
    private let sessionName: String
    private var handle: FileHandle?

    init(
        directory: URL,
        prefix: String,
        sessionName: String,
        openedAt: Date = Date()
    ) throws {
        self.sessionName = sessionName
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let opened = try Self.openNewFile(directory: directory, prefix: prefix, at: openedAt)
        self.url = opened.url
        self.handle = opened.handle
        appendRaw("=== \(sessionName) session started \(Self.rfc3339(openedAt)) ===\n")
    }

    func append(level: String, category: String, message: String, at date: Date = Date()) {
        appendRaw("\(Self.lineTimestamp(date)) [\(level)] [\(category)] \(message)\n")
    }

    func close(at date: Date = Date()) {
        lock.lock()
        guard let handle else {
            lock.unlock()
            return
        }
        self.handle = nil
        write("=== \(sessionName) session ended \(Self.rfc3339(date)) ===\n", to: handle)
        handle.synchronizeFile()
        handle.closeFile()
        lock.unlock()
    }

    func close(sessionName _: String, at date: Date = Date()) {
        close(at: date)
    }

    func flush() {
        lock.lock()
        handle?.synchronizeFile()
        lock.unlock()
    }

    deinit {
        close()
    }

    private func appendRaw(_ line: String) {
        lock.lock()
        if let handle {
            write(line, to: handle)
        }
        lock.unlock()
    }

    private func write(_ string: String, to handle: FileHandle) {
        handle.write(Data(string.utf8))
    }

    private struct OpenedFile {
        let url: URL
        let handle: FileHandle
    }

    private static func openNewFile(directory: URL, prefix: String, at date: Date) throws -> OpenedFile {
        let base = prefix + fileTimestamp(date)
        for index in 0 ..< 100 {
            let suffix = index == 0 ? "" : "-\(index)"
            let url = directory.appendingPathComponent(base + suffix + ".log")
            do {
                return OpenedFile(url: url, handle: try openExclusive(url))
            } catch let error as POSIXError where error.code == .EEXIST {
                continue
            }
        }
        throw NSError(
            domain: "io.proxycat.ProxyCatLogPersistence",
            code: Int(EEXIST),
            userInfo: [NSLocalizedDescriptionKey: "could not create log file in \(directory.path)"]
        )
    }

    private static func openExclusive(_ url: URL) throws -> FileHandle {
        let fd = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    private static func fileTimestamp(_ date: Date) -> String {
        formatted(date, pattern: "yyyyMMdd-HHmmss")
    }

    private static func lineTimestamp(_ date: Date) -> String {
        formatted(date, pattern: "yyyy-MM-dd'T'HH:mm:ss.SSS")
    }

    private static func rfc3339(_ date: Date) -> String {
        formatted(date, pattern: "yyyy-MM-dd'T'HH:mm:ssZZZZZ")
    }

    private static func formatted(_ date: Date, pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
