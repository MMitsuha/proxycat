import Foundation

public final class ProxyCatLogPersistence: @unchecked Sendable {
    public static let shared = ProxyCatLogPersistence()

    private let lock = NSLock()
    private var current: PersistentLogFile?
    private var markerURL: URL?

    private init() {}

    @discardableResult
    public func start(directory: URL = FilePath.logsDirectory) throws -> String {
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
            prefix: AppConfiguration.proxyCatLogFilePrefix,
            sessionName: "proxycat"
        )
        let marker = directory.appendingPathComponent(AppConfiguration.activeProxyCatLogMarkerFileName)

        lock.lock()
        if let current {
            let path = current.url.path
            if let markerURL {
                Self.writeActiveMarker(markerURL, path: path)
            }
            lock.unlock()
            file.close(sessionName: "proxycat")
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
        file.close(sessionName: "proxycat")
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
