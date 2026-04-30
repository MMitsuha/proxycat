import Foundation
import os

/// Atomic JSON load/save for the App Group preference files
/// (`settings.json`, `host_settings.json`). Centralizes the
/// "decode-or-defaults" + "encode-and-write-atomic" pattern that
/// `RuntimeSettings` and `HostSettingsStore` both need so the two
/// stores stop reimplementing the same I/O.
public enum JSONFileStore {
    private static let logger = Logger(subsystem: "io.proxycat.Library", category: "JSONFileStore")

    /// Decodes `T` from `path` or returns `fallback` if the file is
    /// missing, unreadable, or fails to decode. Never throws — preference
    /// files must not block app launch.
    public static func load<T: Decodable>(_ type: T.Type, at path: String, default fallback: T) -> T {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return fallback
        }
        return (try? JSONDecoder().decode(T.self, from: data)) ?? fallback
    }

    /// Atomically writes `value` as JSON to `path`. Throws on encode or
    /// write failure so the caller can decide whether to broadcast a
    /// change notification — broadcasting after a failed save would
    /// leave subscribers acting on in-memory state that disk doesn't
    /// agree with.
    public static func save<T: Encodable>(_ value: T, to path: String) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Convenience: save and log on failure. Returns `true` when the
    /// caller should broadcast the change, `false` when persistence
    /// failed (so subscribers don't get nudged into a state the disk
    /// doesn't hold).
    @discardableResult
    public static func saveOrLog<T: Encodable>(
        _ value: T,
        to path: String,
        category: String
    ) -> Bool {
        do {
            try save(value, to: path)
            return true
        } catch {
            logger.error("[\(category, privacy: .public)] save failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
