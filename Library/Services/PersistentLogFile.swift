import Darwin
import Foundation

final class PersistentLogFile: @unchecked Sendable {
    let url: URL

    private let lock = NSLock()
    private var handle: FileHandle?

    init(
        directory: URL,
        prefix: String,
        sessionName: String,
        openedAt: Date = Date()
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let opened = try Self.openNewFile(directory: directory, prefix: prefix, at: openedAt)
        self.url = opened.url
        self.handle = opened.handle
        appendRaw("=== \(sessionName) session started \(Self.rfc3339(openedAt)) ===\n")
    }

    func append(level: String, category: String, message: String, at date: Date = Date()) {
        appendRaw("\(Self.lineTimestamp(date)) [\(level)] [\(category)] \(message)\n")
    }

    func close(sessionName: String, at date: Date = Date()) {
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

    deinit {
        close(sessionName: "proxycat")
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
        fileTimestampFormatter.string(from: date)
    }

    private static func lineTimestamp(_ date: Date) -> String {
        lineTimestampFormatter.string(from: date)
    }

    private static func rfc3339(_ date: Date) -> String {
        rfc3339Formatter.string(from: date)
    }

    // DateFormatter is documented as thread-safe for formatting on
    // Apple platforms; these are read-only after initialization. Sharing
    // them avoids allocating a formatter for every appended log line —
    // the proxy can emit hundreds of lines per second while streaming.
    private static let fileTimestampFormatter = makeFormatter("yyyyMMdd-HHmmss")
    private static let lineTimestampFormatter = makeFormatter("yyyy-MM-dd'T'HH:mm:ss.SSS")
    private static let rfc3339Formatter = makeFormatter("yyyy-MM-dd'T'HH:mm:ssZZZZZ")

    private static func makeFormatter(_ pattern: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter
    }
}
